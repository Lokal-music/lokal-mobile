package com.mossapps.flick

import org.junit.Assert.*
import org.junit.Test

class JavaCrashRecorderTest {
    @Test fun recordsCallStackWithoutExceptionMessageOrSourcePath() {
        val error = IllegalStateException("password=secret private://nas")
        error.stackTrace = arrayOf(
            StackTraceElement("AudioEngine", "prepare", "/private/user/music.flac", 64),
            StackTraceElement("MainActivity", "onCreate", "MainActivity.kt", 22)
        )
        val summary = JavaCrashRecorder.format(error)
        assertTrue(summary.contains("IllegalStateException"))
        assertTrue(summary.contains("AudioEngine.prepare:64"))
        assertTrue(summary.contains("MainActivity.onCreate:22"))
        assertFalse(summary.contains("secret"))
        assertFalse(summary.contains("/private"))
        assertFalse(summary.contains("music.flac"))
    }

    @Test fun stackOutputIsBounded() {
        val error = IllegalArgumentException("ignored")
        error.stackTrace = Array(1000) {
            StackTraceElement("A".repeat(200), "m".repeat(200), "user", it)
        }
        val summary = JavaCrashRecorder.format(error)
        assertTrue(summary.length <= 2600)
        assertFalse(summary.contains("#18 "))
    }
}
