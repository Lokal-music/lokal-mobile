package com.mossapps.flick.widgets

import android.content.SharedPreferences

/** Numbers crossing home_widget's StandardMessageCodec can be Int OR Long.
 * In particular opaque Dart ARGB colours (0xFF......) exceed signed Int.MAX_VALUE,
 * so home_widget persists them with SharedPreferences.putLong. Preserve their
 * low 32 colour bits, including values saved before the signed Dart write fix.
 */
internal object WidgetPreferenceValue {
    // getInt/getLong enforce the exact stored JVM type and throw on a mismatch.
    fun readInt(prefs: SharedPreferences, key: String, default: Int): Int =
        int(prefs.all[key], default)

    fun int(value: Any?, default: Int): Int = when (value) {
        is Int -> value
        is Long -> if (value in Int.MIN_VALUE.toLong()..0xFFFFFFFFL) value.toInt() else default
        else -> default
    }
}
