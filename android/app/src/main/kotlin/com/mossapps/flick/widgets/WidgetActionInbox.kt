package com.mossapps.flick.widgets

import android.content.Context

/**
 * Widget taps can arrive before Flutter has installed its method handler.
 * Persist the newest command and consume it atomically after Dart is ready.
 * This avoids silently dropping taps during cold start or cached-engine setup.
 */
internal object WidgetActionInbox {
    private const val PREFS = "lokal_widget_pending_actions"
    private const val KEY_PENDING = "pending_uri"

    fun store(context: Context, uri: String) {
        if (!uri.startsWith("flickwidget://")) return
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_PENDING, uri)
            .commit()
    }

    fun take(context: Context): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val pending = prefs.getString(KEY_PENDING, null) ?: return null
        prefs.edit().remove(KEY_PENDING).commit()
        return pending
    }
}
