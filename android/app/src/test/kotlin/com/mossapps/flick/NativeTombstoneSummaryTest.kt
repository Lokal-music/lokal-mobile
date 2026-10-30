package com.mossapps.flick

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

/** Tiny protobuf fixtures built to match AOSP debuggerd/proto/tombstone.proto. */
class NativeTombstoneSummaryTest {
    private fun number(n: Long): ByteArray {
        val out = ByteArrayOutputStream()
        var value = n
        while (value >= 128) {
            out.write(((value.toInt() and 0x7f) or 0x80))
            value = value ushr 7
        }
        out.write(value.toInt())
        return out.toByteArray()
    }

    private fun scalar(field: Int, value: Long) =
        number((field * 8).toLong()) + number(value)

    private fun bytes(field: Int, value: ByteArray) =
        number((field * 8 + 2).toLong()) + number(value.size.toLong()) + value

    private fun string(field: Int, value: String) =
        bytes(field, value.toByteArray(Charsets.UTF_8))

    @Test fun decodesSignalAndCrashingThreadFrame() {
        val signal = scalar(1, 11) +
            string(2, "SIGSEGV") + string(4, "SEGV_MAPERR")
        val frame = scalar(1, 0x1234) +
            string(4, "decoder_step") +
            string(6, "/data/app/lib/x86_64/libdecoder.so")
        val thread = bytes(4, frame)
        val threadMap = scalar(1, 77) + bytes(2, thread)
        val tombstone = scalar(6, 77) +
            bytes(10, signal) +
            bytes(16, threadMap) +
            string(14, "/private/user/music/password=secret")

        val summary = NativeTombstoneSummary.decode(tombstone)!!
        assertTrue(summary.contains("SIGSEGV"))
        assertTrue(summary.contains("SEGV_MAPERR"))
        assertTrue(summary.contains("tid=77"))
        assertTrue(summary.contains("0x1234 libdecoder.so decoder_step"))
        assertFalse(summary.contains("/data/app"))
        assertFalse(summary.contains("/private/user"))
        assertFalse(summary.contains("password=secret"))
    }

    @Test fun emptyAndInvalidInputsAreHandledWithoutNativeCrash() {
        assertNull(NativeTombstoneSummary.decode(byteArrayOf()))
        assertNull(NativeTombstoneSummary.decode(byteArrayOf(0)))
    }

    @Test fun truncatedTailStillReturnsSignal() {
        val signal = string(2, "SIGABRT")
        val tombstone = bytes(10, signal) +
            byteArrayOf(0x92.toByte(), 0x01, 0x12, 0x7f)
        assertTrue(NativeTombstoneSummary.decode(tombstone)!!.contains("SIGABRT"))
    }
}
