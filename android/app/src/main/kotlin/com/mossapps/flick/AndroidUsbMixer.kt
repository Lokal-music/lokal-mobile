package com.mossapps.flick

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.media.AudioTrack
import android.os.Build
import android.os.SystemClock
import android.util.Log
import java.nio.ByteBuffer
import androidx.annotation.RequiresApi

/**
 * Android 14+ USB bit-perfect mixer transport.
 *
 * This is intentionally separate from the libusb isochronous driver: Android owns
 * the USB interface, while AudioManager requests a non-mixing, unscaled PCM route.
 * JNI calls originate on the Rust output thread, not the Flutter UI thread.
 * Never claim bit-perfect if the format, mixer setting or routed device differs.
 */
object AndroidUsbMixer {
    private const val TAG = "LokalUsbMixer"
    private const val PREFS = "FlutterSharedPreferences"
    private const val ENGINE_KEY = "flutter.audio_engine_preference"
    private const val BIT_PERFECT_KEY = "flutter.uac2_bit_perfect_enabled"
    private const val SOURCE_BITS_KEY = "flutter.android_mixer_source_bits"

    @JvmStatic
    fun requested(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return false
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val sourceBits = prefs.getLong(SOURCE_BITS_KEY, 0L)
        return prefs.getString(ENGINE_KEY, null) == "androidMixerUsb" &&
            prefs.getBoolean(BIT_PERFECT_KEY, false) &&
            sourceBits in 1L..24L
    }

    @RequiresApi(34)
    private class Session(
        val manager: AudioManager,
        val device: AudioDeviceInfo,
        val attributes: AudioMixerAttributes,
        val track: AudioTrack,
        val bits: Int,
    ) {
        private var nextCheck = 0L

        fun valid(): Boolean =
            track.routedDevice?.id == device.id &&
                manager.getPreferredMixerAttributes(ATTRIBUTES, device) == attributes &&
                track.sampleRate == attributes.format.sampleRate &&
                track.channelCount == 2 &&
                track.audioFormat == attributes.format.encoding

        fun write(data: ByteBuffer): Int {
            val now = SystemClock.elapsedRealtime()
            if (now >= nextCheck) {
                if (!valid()) {
                    Log.w(TAG, "USB mixer route lost or attributes changed")
                    return -1
                }
                nextCheck = now + 250
            }
            return track.write(data, data.remaining(), AudioTrack.WRITE_NON_BLOCKING)
        }

        fun release() {
            runCatching { track.pause() }
            runCatching { track.flush() }
            runCatching { track.release() }
            // Do not clear another app's newer mixer preference.
            runCatching {
                if (manager.getPreferredMixerAttributes(ATTRIBUTES, device) == attributes) {
                    manager.clearPreferredMixerAttributes(ATTRIBUTES, device)
                }
            }
        }
    }

    private val sessions = mutableMapOf<Long, Session>()
    private var nextId = 1L

    private val ATTRIBUTES = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    /**
     * Open only at the source rate. Rust's float callback preserves at most 24
     * significant PCM bits, so use 24-bit packed or zero-padded 32-bit integer
     * transport; never advertise original 32-bit PCM sample exactness here.
     * Fail closed when Android/USB cannot provide one of those exact routes.
     */
    @JvmStatic
    @Synchronized
    fun open(context: Context, rate: Int, channels: Int): Long {
        if (!requested(context) || channels != 2 || rate !in 8_000..768_000) return 0
        if (Build.VERSION.SDK_INT < 34) return 0
        val manager = context.getSystemService(AudioManager::class.java) ?: return 0
        val candidates = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                it.type == AudioDeviceInfo.TYPE_USB_HEADSET
        }
        for (device in candidates) {
            val options = runCatching { manager.getSupportedMixerAttributes(device) }
                .getOrDefault(emptyList())
                .filter {
                    it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT &&
                        it.format.sampleRate == rate &&
                        it.format.channelMask == AudioFormat.CHANNEL_OUT_STEREO &&
                        it.format.encoding in setOf(
                            AudioFormat.ENCODING_PCM_24BIT_PACKED,
                            AudioFormat.ENCODING_PCM_32BIT,
                        )
                }
                .sortedBy { if (it.format.encoding == AudioFormat.ENCODING_PCM_24BIT_PACKED) 0 else 1 }

            for (option in options) {
                if (!manager.setPreferredMixerAttributes(ATTRIBUTES, device, option)) continue
                var track: AudioTrack? = null
                try {
                    val bits = if (option.format.encoding == AudioFormat.ENCODING_PCM_24BIT_PACKED) 24 else 32
                    val frameBytes = (bits / 8) * channels
                    val minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO, option.format.encoding)
                    require(minimum > 0) { "Invalid AudioTrack buffer requirement" }
                    track = AudioTrack.Builder()
                        .setAudioAttributes(ATTRIBUTES)
                        .setAudioFormat(option.format)
                        .setTransferMode(AudioTrack.MODE_STREAM)
                        .setBufferSizeInBytes(maxOf(minimum * 2, (rate / 5) * frameBytes))
                        .build()
                    require(track.state == AudioTrack.STATE_INITIALIZED) { "AudioTrack not initialized" }
                    require(track.setPreferredDevice(device)) { "USB routing rejected" }
                    require(track.sampleRate == rate && track.channelCount == channels &&
                        track.audioFormat == option.format.encoding) { "Android changed format" }
                    track.setVolume(1f)
                    track.play()
                    // Some HALs expose routedDevice only after the first frame.
                    // Prime with one silent frame rather than risking music on an unverified route.
                    val silence = ByteArray(frameBytes)
                    track.write(silence, 0, silence.size, AudioTrack.WRITE_BLOCKING)
                    val deadline = SystemClock.elapsedRealtime() + 250L
                    while (track.routedDevice == null && SystemClock.elapsedRealtime() < deadline) {
                        Thread.sleep(10)
                    }
                    val session = Session(manager, device, option, track, bits)
                    require(session.valid()) { "USB route or mixer attributes could not be verified" }
                    val id = nextId++
                    sessions[id] = session
                    Log.i(TAG, "Verified Android bit-perfect USB mixer: ${device.productName}, ${rate}Hz, ${bits}-bit transport")
                    return id
                } catch (e: Exception) {
                    Log.w(TAG, "Android USB bit-perfect mixer refused ${rate}Hz on ${device.productName}: ${e.message}")
                    runCatching { track?.release() }
                    runCatching {
                        if (manager.getPreferredMixerAttributes(ATTRIBUTES, device) == option) {
                            manager.clearPreferredMixerAttributes(ATTRIBUTES, device)
                        }
                    }
                }
            }
        }
        return 0
    }

    @JvmStatic
    @Synchronized
    fun bits(id: Long): Int = sessions[id]?.bits ?: 0

    @JvmStatic
    fun write(id: Long, data: ByteBuffer): Int {
        val session = synchronized(this) { sessions[id] } ?: return -1
        return try { session.write(data) } catch (e: Exception) {
            Log.w(TAG, "USB bit-perfect mixer write failed: ${e.message}")
            -1
        }
    }

    @JvmStatic
    @Synchronized
    fun close(id: Long) {
        sessions.remove(id)?.release()
    }
}
