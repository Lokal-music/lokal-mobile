package com.mossapps.flick.widgets

import android.appwidget.AppWidgetManager
import android.os.Bundle

/**
 * Android launcher cells have different dimensions on each OEM. Use the
 * *minimum* reported available bounds (not MAX_WIDTH alone, which can be the
 * landscape width) to choose a safe remote layout on resize and rotation.
 */
internal object WidgetSize {
    fun width(manager: AppWidgetManager, id: Int): Int {
        val options: Bundle = manager.getAppWidgetOptions(id)
        return options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
            .takeIf { it > 0 }
            ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 240)
    }

    fun height(manager: AppWidgetManager, id: Int): Int {
        val options: Bundle = manager.getAppWidgetOptions(id)
        return options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
            .takeIf { it > 0 }
            ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 130)
    }

    fun isWide(manager: AppWidgetManager, id: Int): Boolean = width(manager, id) >= 280
    fun isTall(manager: AppWidgetManager, id: Int): Boolean = height(manager, id) >= 160

    fun time(ms: Long): String {
        val seconds = (ms / 1000L).coerceAtLeast(0L)
        return "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
    }
}
