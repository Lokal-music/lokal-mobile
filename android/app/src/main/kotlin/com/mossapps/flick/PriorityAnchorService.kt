package com.mossapps.flick

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log

class PriorityAnchorService(private val context: Context) {

    private var anchorTrack: AudioTrack? = null
    private var anchorThread: Thread? = null
    @Volatile private var running = false
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val TAG = "PriorityAnchor"
        private const val ANCHOR_SAMPLE_RATE = 48000
        private const val ANCHOR_CHANNELS = AudioFormat.CHANNEL_OUT_STEREO
        private const val ANCHOR_FORMAT = AudioFormat.ENCODING_PCM_16BIT

        // The anchor must pin the SAME route the music engine uses. A media
        // track pinned to a different device becomes the policy's active media
        // route, so streams reopened after track end follow the pinned device
        // (the built-in speaker) instead of the connected headphones.
        private val WIRED_TARGET_TYPES = listOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_LINE_ANALOG,
            AudioDeviceInfo.TYPE_LINE_DIGITAL,
            AudioDeviceInfo.TYPE_AUX_LINE,
        )
    }

    fun start() {
        if (anchorTrack != null) {
            Log.d(TAG, "Anchor already active")
            return
        }

        val bufferSize = AudioTrack.getMinBufferSize(
            ANCHOR_SAMPLE_RATE, ANCHOR_CHANNELS, ANCHOR_FORMAT
        )
        if (bufferSize <= 0) {
            Log.e(TAG, "Invalid buffer size: $bufferSize")
            return
        }

        try {
            anchorTrack = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(ANCHOR_SAMPLE_RATE)
                        .setEncoding(ANCHOR_FORMAT)
                        .setChannelMask(ANCHOR_CHANNELS)
                        .build()
                )
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create AudioTrack: ${e.message}")
            anchorTrack = null
            return
        }

        val track = anchorTrack ?: return

        val targetDevice = findAnchorTargetDevice()
        if (targetDevice != null) {
            track.preferredDevice = targetDevice
            Log.d(TAG, "Routed anchor to ${targetDevice.productName}")
        } else {
            Log.w(TAG, "No anchor target device found; anchor may use default route")
        }

        running = true

        try {
            track.play()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to play anchor track: ${e.message}")
            track.release()
            anchorTrack = null
            running = false
            return
        }

        val bufferDurationMs = bufferDurationMs(bufferSize)
        val silence = ByteArray(bufferSize)

        anchorThread = Thread({
            try {
                while (running) {
                    val written = try {
                        track.write(silence, 0, silence.size)
                    } catch (e: Exception) {
                        if (running) Log.e(TAG, "Anchor write exception: ${e.message}")
                        break
                    }
                    if (written <= 0) {
                        if (running) Log.e(TAG, "Anchor write failed: $written")
                        break
                    }
                    try {
                        Thread.sleep((bufferDurationMs - 5).coerceAtLeast(1L))
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            } finally {
                // A failed worker must never leave an orphaned AudioTrack
                // holding the Android audio route until process death.
                mainHandler.post {
                    if (anchorTrack === track && running) {
                        Log.w(TAG, "Anchor worker exited unexpectedly; releasing track")
                        stop()
                    }
                }
            }
        }, "PriorityAnchor").apply {
            priority = Thread.NORM_PRIORITY
            start()
        }

        Log.d(TAG, "Priority anchor started")
    }

    /// Re-resolve the anchor pin after a route change (headphone plug/unplug)
    /// so the anchor keeps following the music route on the live track instead
    /// of remaining pinned to a stale device.
    fun updateRouteDevice() {
        val track = anchorTrack ?: return
        if (!running) return
        val targetDevice = findAnchorTargetDevice()
        if (targetDevice != null) {
            track.preferredDevice = targetDevice
            Log.d(TAG, "Re-pinned anchor to ${targetDevice.productName}")
        }
    }

    fun stop() {
        running = false
        anchorThread?.interrupt()
        anchorThread = null
        val track = anchorTrack ?: return
        anchorTrack = null
        try {
            track.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Anchor stop failed: ${e.message}")
        }
        // Release independently even if stop failed (e.g. route already gone).
        try {
            track.release()
        } catch (e: Exception) {
            Log.w(TAG, "Anchor release failed: ${e.message}")
        }
        Log.d(TAG, "Priority anchor stopped")
    }

    private fun bufferDurationMs(bufferSizeBytes: Int): Long {
        val frames = bufferSizeBytes / 4
        return (frames * 1000L + ANCHOR_SAMPLE_RATE / 2) / ANCHOR_SAMPLE_RATE
    }

    @Suppress("DEPRECATION")
    private fun findAnchorTargetDevice(): AudioDeviceInfo? {
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val devices = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        // Never claim the earpiece: an active media track pinned there makes it
        // the active media route, so streams reopened after track end follow it
        // off the intended device. Wired outputs are preferred because a
        // connected 3.5mm jack is the music route; the built-in speaker is the
        // fallback when no headphone is connected.
        return devices.firstOrNull { it.type in WIRED_TARGET_TYPES }
            ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
    }
}
