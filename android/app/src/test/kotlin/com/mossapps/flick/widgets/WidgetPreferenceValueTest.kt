package com.mossapps.flick.widgets

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.junit.Assert.assertThrows
import org.junit.Assert.assertEquals
import org.junit.Test

class WidgetPreferenceValueTest {
    private val key = "lokal_widget_accent_argb"

    // Exercise the production SharedPreferences boundary with Android's strict
    // getInt semantics, and the same putLong payload produced by home_widget.
    private fun saved(value: Any?): SharedPreferences = Proxy.newProxyInstance(
        SharedPreferences::class.java.classLoader,
        arrayOf(SharedPreferences::class.java),
    ) { _, method, args ->
        when (method.name) {
            "getAll" -> if (value == null) emptyMap<String, Any>() else mapOf(key to value)
            "getInt" -> value?.let { it as Int } ?: args!![1]
            else -> error("Unexpected preference operation: ${method.name}")
        }
    } as SharedPreferences

    @Test
    fun persistedPluginColourReproducesOldCrashAndRecoversWithoutClearingData() {
        val preferences = saved(0xFFCFFF50L)
        assertThrows(ClassCastException::class.java) { preferences.getInt(key, -1) }
        assertEquals(0xFFCFFF50.toInt(), WidgetPreferenceValue.readInt(preferences, key, -1))
    }

    @Test
    fun unsignedDartThemeColoursSurviveLongStorage() {
        // The default white and app accent both cross StandardMessageCodec's
        // signed 32-bit boundary, causing home_widget to call putLong.
        for (argb in listOf(0xFFFFFFFFL, 0xFFCFFF50L, 0xFF112233L, 0x80000000L)) {
            assertEquals(argb.toInt(), WidgetPreferenceValue.readInt(saved(argb), key, 0))
        }
    }

    @Test
    fun signedAndroidColoursAndNewSignedDartWritesRemainIdentical() {
        for (argb in listOf(0xFFFFFFFF.toInt(), 0xFFCFFF50.toInt(), 0xFF112233.toInt())) {
            assertEquals(argb, WidgetPreferenceValue.readInt(saved(argb), key, 0))
            assertEquals(argb, WidgetPreferenceValue.readInt(saved(argb.toLong()), key, 0))
        }
    }

    @Test
    fun integerPreferencesSupportBothCodecWidths() {
        for (level in 0..4) {
            assertEquals(level, WidgetPreferenceValue.readInt(saved(level), key, 3))
            assertEquals(level, WidgetPreferenceValue.readInt(saved(level.toLong()), key, 3))
        }
        assertEquals(0, WidgetPreferenceValue.readInt(saved(0L), key, 3))
    }

    @Test
    fun absentOrIncompatibleValuesUseDefaultWithoutCrashingRendering() {
        for (invalid in listOf(null, "4294967295", true, 1.5, Long.MAX_VALUE, Long.MIN_VALUE)) {
            assertEquals(-1, WidgetPreferenceValue.readInt(saved(invalid), key, -1))
        }
    }
}
