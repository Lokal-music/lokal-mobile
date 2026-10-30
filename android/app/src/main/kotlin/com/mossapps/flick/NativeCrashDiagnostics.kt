package com.mossapps.flick

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque

/**
 * Small, privacy-limited checkpoint ring retained by Android when our process
 * dies unexpectedly. The state is attached to ApplicationExitInfo, not sent
 * anywhere, and contains no user-supplied titles, URLs, paths or credentials.
 */
internal class NativeCrashBreadcrumbs(private val context: Context) {
    private val checkpoints = ArrayDeque<String>()
    private var lastPublished = ""

    fun record(stage: String): Boolean {
        if (!Regex("^[a-z0-9:_-]{1,64}$").matches(stage)) return false
        // Android allows at most 128 bytes in setProcessStateSummary. Bound the
        // actual encoded byte count, not merely the number of events.
        checkpoints.addLast("${android.os.SystemClock.elapsedRealtime() / 1000}:$stage")
        while (checkpoints.size > 1 &&
            checkpoints.joinToString("\n").toByteArray(StandardCharsets.UTF_8).size > 120
        ) {
            checkpoints.removeFirst()
        }
        val summary = checkpoints.joinToString("\n").takeLast(120)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && summary != lastPublished) {
            try {
                val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                manager?.setProcessStateSummary(summary.toByteArray(StandardCharsets.UTF_8))
                lastPublished = summary
            } catch (_: Exception) {
                // Android may throttle repeated updates. Never interrupt audio.
            }
        }
        return true
    }
}

/**
 * The native tombstone returned on Android 12+ is a protobuf, NOT text.
 * Decode only signal and frames from the crashing thread (per AOSP
 * debuggerd/proto/tombstone.proto); never export arbitrary memory dumps,
 * log buffers or app data that might contain passwords/URLs.
 */
internal object NativeTombstoneSummary {
    private data class Field(val id: Int, val value: Long = 0, val data: ByteArray? = null)

    private fun fields(bytes: ByteArray): List<Field> {
        val result = ArrayList<Field>()
        var p = 0
        fun variable(): Long {
            var result = 0L
            for (n in 0 until 10) {
                if (p >= bytes.size) throw IllegalArgumentException("Truncated tombstone")
                val v = bytes[p++].toInt() and 0xff
                result = result or ((v and 0x7f).toLong() shl (7 * n))
                if (v and 0x80 == 0) return result
            }
            throw IllegalArgumentException("Bad tombstone varint")
        }
        while (p < bytes.size && result.size < 4096) {
            try {
            val key = variable()
            val id = (key ushr 3).toInt()
            if (id == 0) throw IllegalArgumentException("Invalid tombstone field")
            when ((key and 7L).toInt()) {
                0 -> result.add(Field(id, variable()))
                1 -> {
                    if (bytes.size - p < 8) throw IllegalArgumentException("Truncated fixed64")
                    p += 8
                }
                2 -> {
                    val size = variable()
                    if (size < 0 || size > bytes.size - p) throw IllegalArgumentException("Truncated field")
                    result.add(Field(id, data = bytes.copyOfRange(p, p + size.toInt())))
                    p += size.toInt()
                }
                5 -> {
                    if (bytes.size - p < 4) throw IllegalArgumentException("Truncated fixed32")
                    p += 4
                }
                else -> throw IllegalArgumentException("Unknown tombstone wire type")
            }
            } catch (_: IllegalArgumentException) {
                // A bounded 256-KiB capture can end partway through a large
                // memory map. Earlier signal/crashed-thread fields are useful.
                break
            }
        }
        return result
    }

    private fun string(bytes: ByteArray?): String =
        bytes?.toString(StandardCharsets.UTF_8)?.take(180) ?: ""

    private fun safeSymbol(value: String): String =
        value.replace(Regex("[\\r\\n\\t]"), " ").take(120)

    fun decode(bytes: ByteArray): String? {
        if (bytes.isEmpty()) return null
        return try {
            val top = fields(bytes)
            if (top.isEmpty()) return null
            val crashedTid = top.firstOrNull { it.id == 6 }?.value
            val signal = top.firstOrNull { it.id == 10 }?.data?.let(::fields)
            val signalName = safeSymbol(string(signal?.firstOrNull { it.id == 2 }?.data))
            val signalCode = safeSymbol(string(signal?.firstOrNull { it.id == 4 }?.data))
            val number = signal?.firstOrNull { it.id == 1 }?.value
            val abortMessage = top.firstOrNull { it.id == 14 }?.data
            val out = StringBuilder("tombstone signal=${signalName.ifEmpty { number?.toString() ?: "unknown" }}")
            if (signalCode.isNotEmpty()) out.append(" code=$signalCode")
            if (crashedTid != null) out.append(" tid=$crashedTid")
            // Avoid printing raw abort_message, as it may include user paths.
            if (abortMessage != null) out.append(" abort_message_present=true")
            val matching = top.asSequence().filter { it.id == 16 && it.data != null }
                .mapNotNull { entry ->
                    val mapFields = fields(entry.data!!)
                    val id = mapFields.firstOrNull { it.id == 1 }?.value
                    val thread = mapFields.firstOrNull { it.id == 2 }?.data
                    if (crashedTid != null && id == crashedTid && thread != null)
                        thread else null
                }.firstOrNull()
            if (matching != null) {
                val frames = fields(matching).filter { it.id == 4 && it.data != null }.take(12)
                for ((index, raw) in frames.withIndex()) {
                    val frame = fields(raw.data!!)
                    val library = string(frame.firstOrNull { it.id == 6 }?.data)
                        .substringAfterLast('/').take(80)
                    val function = safeSymbol(string(frame.firstOrNull { it.id == 4 }?.data))
                    val relPc = frame.firstOrNull { it.id == 1 }?.value ?: 0L
                    out.append("\n#$index pc=0x${relPc.toString(16)} $library $function")
                }
            }
            out.toString().take(2300)
        } catch (_: Exception) {
            null
        }
    }
}
