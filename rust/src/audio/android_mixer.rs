//! Android 14+ AudioMixerAttributes BIT_PERFECT USB backend.
//!
//! Unlike libusb direct, Android retains ownership of the USB DAC. JNI opens
//! a rate-matched AudioTrack whose route and mixer preference are verified.
//! We never substitute this output for the custom isochronous USB driver.
//! The current Rust float renderer preserves at most 24 significant PCM bits;
//! 32-bit integer transport here therefore pads 24-bit samples, not 32-bit audio.

#![cfg(target_os = "android")]

use crate::audio::commands::AudioEvent;
use crate::audio::engine::{audio_callback, AudioCallbackData};
use crossbeam_channel::Sender;
use jni::{jni_sig, jni_str, objects::{JClass, JObject, JValue}, refs::Global, strings::JNIString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const CLASS: &str = "com/mossapps/flick/AndroidUsbMixer";
static CLASS_REF: OnceLock<Global<JClass<'static>>> = OnceLock::new();

fn mixer_class<'env>(env: &mut jni::Env<'env>) -> Result<JClass<'env>, jni::errors::Error> {
    if let Some(cached) = CLASS_REF.get() {
        return env.new_local_ref(cached);
    }

    // Attached Rust threads do not inherit Flutter's application classloader.
    let ctx = ndk_context::android_context();
    let context = unsafe { JObject::from_raw(env, ctx.context() as jni::sys::jobject) };
    let loader = env.call_method(
        &context, jni_str!("getClassLoader"), jni_sig!("()Ljava/lang/ClassLoader;"), &[],
    )?.l()?;
    let class_name = env.new_string(CLASS.replace('/', "."))?;
    let loaded = env.call_method(
        &loader, jni_str!("loadClass"), jni_sig!("(Ljava/lang/String;)Ljava/lang/Class;"),
        &[JValue::Object(&class_name)],
    )?.l()?;
    let class = unsafe { JClass::from_raw(env, loaded.into_raw()) };
    let global = env.new_global_ref(&class)?;
    let _ = CLASS_REF.set(global);
    Ok(class)
}

fn with_env<T>(f: impl FnOnce(&mut jni::Env<'_>) -> Result<T, jni::errors::Error>) -> Result<T, String> {
    let ctx = ndk_context::android_context();
    let vm = unsafe { jni::JavaVM::from_raw(ctx.vm().cast()) };
    vm.attach_current_thread(|env| {
        let result = f(env);
        if result.is_err() {
            let _ = env.exception_describe();
        }
        let _ = env.exception_clear();
        result
    }).map_err(|e| format!("Android USB mixer JNI: {}", e))
}

pub fn requested() -> bool {
    with_env(|env| {
        let class = mixer_class(env)?;
        let ctx = ndk_context::android_context();
        let context = unsafe { JObject::from_raw(env, ctx.context() as jni::sys::jobject) };
        env.call_static_method(
            &class, jni_str!("requested"),
            jni_sig!("(Landroid/content/Context;)Z"),
            &[JValue::Object(&context)],
        )?.z()
    }).unwrap_or(false)
}

struct MixerHandle {
    id: i64,
    bits: usize,
}

impl MixerHandle {
    fn open(rate: u32, channels: usize) -> Result<Self, String> {
        let id = with_env(|env| {
            let class = mixer_class(env)?;
            let ctx = ndk_context::android_context();
            let context = unsafe { JObject::from_raw(env, ctx.context() as jni::sys::jobject) };
            env.call_static_method(
                &class, jni_str!("open"),
                jni_sig!("(Landroid/content/Context;II)J"),
                &[JValue::Object(&context), JValue::Int(rate as i32), JValue::Int(channels as i32)],
            )?.j()
        })?;
        if id == 0 {
            return Err(format!("Android 14 USB mixer did not grant a verified exact-rate {}Hz route", rate));
        }
        let bits = with_env(|env| {
            let class = mixer_class(env)?;
            env.call_static_method(&class, jni_str!("bits"), jni_sig!("(J)I"), &[JValue::Long(id)])?.i()
        })? as usize;
        if !matches!(bits, 16 | 24 | 32) {
            let mut handle = Self { id, bits };
            handle.close();
            return Err(format!("Unsupported Android USB mixer PCM packing: {} bits", bits));
        }
        Ok(Self { id, bits })
    }

    fn write(&self, bytes: &[u8]) -> Result<usize, String> {
        let written = with_env(|env| {
            let class = mixer_class(env)?;
            // AudioTrack.write(ByteBuffer) copies synchronously; JNI holds no
            // reference after returning. Avoid allocating a Java byte[] for
            // every 10 ms PCM chunk.
            let payload = unsafe {
                env.new_direct_byte_buffer(bytes.as_ptr() as *mut u8, bytes.len())?
            };
            env.call_static_method(
                &class, jni_str!("write"), jni_sig!("(JLjava/nio/ByteBuffer;)I"),
                &[JValue::Long(self.id), JValue::Object(&payload)],
            )?.i()
        })?;
        if written < 0 {
            Err("USB DAC routing, preferred mixer attributes or AudioTrack was lost".into())
        } else {
            Ok(written as usize)
        }
    }

    fn close(&mut self) {
        if self.id == 0 { return; }
        let id = std::mem::replace(&mut self.id, 0);
        if let Err(error) = with_env(|env| {
            let class = mixer_class(env)?;
            env.call_static_method(&class, jni_str!("close"), jni_sig!("(J)V"), &[JValue::Long(id)])?;
            Ok(())
        }) {
            log::warn!("[USB-MIXER] Cleanup failed: {}", error);
        }
    }
}

impl Drop for MixerHandle {
    fn drop(&mut self) { self.close(); }
}

pub struct AndroidMixerBackend {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl AndroidMixerBackend {
    pub fn start(
        callback_data: Arc<AudioCallbackData>,
        event_tx: Sender<AudioEvent>,
        sample_rate: u32,
        channels: usize,
    ) -> Result<Self, String> {
        if channels != 2 { return Err("Android USB mixer requires stereo".into()); }
        let handle = MixerHandle::open(sample_rate, channels)?;
        let stop = Arc::new(AtomicBool::new(false));
        let stop_copy = Arc::clone(&stop);
        let thread = std::thread::Builder::new()
            .name("android-usb-mixer".to_string())
            .spawn(move || render(handle, callback_data, event_tx, sample_rate, channels, stop_copy))
            .map_err(|e| format!("Android USB mixer worker start failed: {}", e))?;
        Ok(Self { stop, thread: Some(thread) })
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.thread.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for AndroidMixerBackend {
    fn drop(&mut self) { self.stop(); }
}

fn render(
    handle: MixerHandle,
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    rate: u32,
    channels: usize,
    stop: Arc<AtomicBool>,
) {
    let frames = (rate / 100).max(1) as usize;
    let mut samples = vec![0.0f32; frames * channels];
    let mut bytes = vec![0u8; samples.len() * (handle.bits / 8)];
    while !stop.load(Ordering::Acquire) {
        // A DSP override (EQ, ReplayGain, pitch, 432 Hz tuning, crossfeed,
        // crossfade) invalidates the requested bit-perfect contract. Do not
        // silently keep the badge while sending processed samples.
        if !callback_data.is_passthrough() {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: "Audio engine output lost: Android USB mixer passthrough invalidated by DSP".into(),
            });
            return;
        }
        audio_callback(&mut samples, &callback_data, &event_tx);
        for (i, sample) in samples.iter().copied().enumerate() {
            let quantized = ((sample.clamp(-1.0, 1.0) * 8_388_608.0) as i32)
                .clamp(-8_388_608, 8_388_607);
            let offset = i * (handle.bits / 8);
            if handle.bits == 16 {
                let pcm16 = (sample.clamp(-1.0, 1.0) * 32_768.0) as i32;
                bytes[offset..offset + 2].copy_from_slice(
                    &(pcm16.clamp(-32_768, 32_767) as i16).to_le_bytes()
                );
            } else if handle.bits == 24 {
                let raw = quantized.to_le_bytes();
                bytes[offset..offset + 3].copy_from_slice(&raw[..3]);
            } else {
                bytes[offset..offset + 4].copy_from_slice(&(quantized << 8).to_le_bytes());
            }
        }

        let mut offset = 0;
        let mut last_progress = Instant::now();
        while offset < bytes.len() && !stop.load(Ordering::Acquire) {
            match handle.write(&bytes[offset..]) {
                Ok(0) => {
                    if last_progress.elapsed() > Duration::from_millis(500) {
                        let _ = event_tx.try_send(AudioEvent::Error {
                            message: "Audio engine output lost: Android USB mixer stopped accepting PCM".into(),
                        });
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(2));
                }
                Ok(written) if written <= bytes.len() - offset => {
                    offset += written;
                    last_progress = Instant::now();
                }
                Ok(_) | Err(_) => {
                    let _ = event_tx.try_send(AudioEvent::Error {
                        message: "Audio engine output lost: Android USB mixer route or format changed".into(),
                    });
                    return;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn twenty_four_bit_float_samples_survive_integer_packing() {
        for value in [-8_388_608, -1, 0, 1, 8_388_607] {
            let normalized = value as f32 / 8_388_608.0;
            let packed = (normalized * 8_388_608.0) as i32;
            assert_eq!(packed, value);
        }
    }
}
