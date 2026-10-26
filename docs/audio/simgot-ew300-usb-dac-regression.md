# SIMGOT EW300 DSP / LE XIAN USB DAC regression checklist

Reproducer: Android USB Audio Class device **VID 0x31b2 / PID 0x0011**.
The USB Audio page can list the DAC while direct Rust USB registration is missing, or while the audio backend has fallen back to Android-managed `just_audio / ExoPlayer`. Flick also reportedly crashes on enabling bit-perfect with this DAC.

## Failure mechanisms addressed by this patch

1. `MainActivity.activateDirectUsb` previously returned success solely because its Kotlin connection cache still contained the device. A Rust-side fallback/clear can invalidate native registration without clearing the Kotlin cache. The new activation path checks `direct_usb.registered` in JNI diagnostics and re-registers on a retry when no native session is active.
2. `MainActivity.deactivateDirectUsb` previously **closed the USB fd after 4 s even when Rust still owned in-flight transfers**. It now retains the fd until native shutdown completes, including a deferred 30 s drain attempt. Failing to drain is logged and leaves the fd owned rather than causing an unsafe close.
3. Rust now rejects starting a second direct USB stream while the previous stream still owns the session guard. Previously the engine force-released the guard after 1.5 s and started another stream against live URBs. The new guard uses compare-exchange and preserves the original stop signal; its exclusion behavior has a unit test.
4. Rust's transient isochronous feedback request previously freed its callback data even if `libusb_cancel_transfer` had not produced a callback, and also returned through `?` on event-pump errors with the transfer outstanding. It now drains cancellation and retains memory if completion cannot be proven.

5. `LIBUSB_TRANSFER_NO_DEVICE` is reported as loss of the *USB host handle*, not proof the physical DAC was unplugged.

## Hardware acceptance criteria (still required before merge)

- Open USB DAC screen with EW300 DSP connected; grant app USB permission. Ensure the correct VID/PID appear.
- With playback engine set to Isochronous USB, enable bit-perfect and play local 16/44.1 PCM, then 24/48 PCM if supported.
- Verify `direct_usb.registered=true`, interface claimed, output signature `android-uac2:`, and stable USB transfers. **Android USB route + source sample-rate alone do not prove this.**
- Stop/start, seek, pause/resume, switch 44.1/48 kHz, unplug/reconnect, background/foreground, and recover after a forced direct-USB failure. No process crash, stalled UI, dangling audio focus or permanently stale registration.
- Confirm the DAC's actual rate and digital bit-perfect path independently; disable DSP for bit-perfect trials.
- Capture Android `logcat` including `UAC2`, Rust `[USB]` and any native tombstone if it still fails. Differentiate actual USB detach from `LIBUSB_TRANSFER_NO_DEVICE` returned by a failing userspace engine.

## Remaining compatibility work

This is a native lifecycle/registration safety correction, **not** an integration of Decent's alternative `usbdevfs` driver. If the SIMGOT still produces `LIBUSB_TRANSFER_NO_DEVICE` on a valid, claimed interface, direct streaming is not proven fixed; a real second USB host backend may be needed. Do not silently claim bit-perfect on Android-managed fallback.
