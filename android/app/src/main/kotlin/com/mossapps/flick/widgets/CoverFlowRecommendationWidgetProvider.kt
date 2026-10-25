package com.mossapps.flick.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import com.mossapps.flick.R
import org.json.JSONArray

/**
 * A launcher-safe Cover Flow inspired recommendation picker.
 *
 * Launcher RemoteViews cannot run Flutter 3D gestures or inertial animations.
 * Browse buttons update selection natively without restarting Flutter; Play
 * launches the ordinary provider-priority playback resolution through Dart.
 */
class CoverFlowRecommendationWidgetProvider : AppWidgetProvider() {
    override fun onEnabled(context: Context) {
        WidgetPrefs.get(context).edit().putBoolean(WidgetPrefs.KEY_RECOMMEND_ENABLED, true).apply()
    }

    override fun onDisabled(context: Context) {
        WidgetPrefs.get(context).edit().putBoolean(WidgetPrefs.KEY_RECOMMEND_ENABLED, false).apply()
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        WidgetUpdateDispatcher.submit(this, context, manager, ids) { id ->
            render(context.applicationContext, manager, id)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle,
    ) = onUpdate(context, manager, intArrayOf(appWidgetId))

    private fun render(context: Context, manager: AppWidgetManager, id: Int): RemoteViews {
        val prefs = WidgetPrefs.get(context)
        val layout = if (WidgetSize.width(manager, id) >= 280 && WidgetSize.height(manager, id) >= 280)
            R.layout.widget_recommended_flow else R.layout.widget_recommended_flow_small
        val views = RemoteViews(context.packageName, layout)
        val data = try {
            JSONArray(prefs.getString(WidgetPrefs.KEY_RECOMMENDATIONS, "[]").orEmpty())
        } catch (_: Exception) { JSONArray() }
        val count = data.length().coerceAtMost(8)
        val indexKey = WidgetPrefs.recommendationCursor(id)
        // Start in the middle like the in-app Cover Flow, preserving an
        // individual browsing cursor for every widget instance afterwards.
        val position = if (count > 0)
            prefs.getInt(indexKey, count / 2).mod(count) else 0
        val hasSelection = count > 0
        val item = if (hasSelection) data.optJSONObject(position) else null
        val title = item?.optString("title").orEmpty()
        val artist = item?.optString("artist").orEmpty()
        views.setTextViewText(R.id.rec_title,
            if (hasSelection) title.ifBlank { "Recommended track" }
            else "Your next favourite")
        views.setTextViewText(R.id.rec_artist,
            if (hasSelection) artist.ifBlank { "From your listening" }
            else "Play something in Lokal to build your picks")
        views.setTextViewText(R.id.rec_heading, "COVER FLOW")
        views.setViewVisibility(R.id.rec_art_strip,
            if (hasSelection) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.rec_prev,
            if (count > 1) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.rec_next,
            if (count > 1) View.VISIBLE else View.GONE)
        views.setTextViewText(R.id.rec_play, if (hasSelection) "Play pick" else "Open Lokal")

        fun art(viewId: Int, offset: Int) {
            val artPath = if (count > 0) data.optJSONObject((position + offset).mod(count))
                ?.optString("artwork").orEmpty() else ""
            val image = WidgetArtLoader.load(artPath, if (offset == 0) 240 else 168)
            // Avoid filling the launcher with three giant app-logo placeholders
            // while artwork is being asynchronously cached. Only real adjacent
            // covers are shown; the selected slot uses a neutral surface.
            views.setViewVisibility(viewId, if (offset == 0 || image != null)
                View.VISIBLE else View.INVISIBLE)
            if (image != null) views.setImageViewBitmap(viewId, image)
            else views.setImageViewResource(viewId, R.drawable.widget_art_placeholder)
        }
        if (hasSelection) {
            art(R.id.rec_center, 0)
            art(R.id.rec_left, -1)
            art(R.id.rec_right, 1)
        }
        views.setOnClickPendingIntent(R.id.rec_prev,
            WidgetIntents.recommendationBrowse(context, id, -1))
        views.setOnClickPendingIntent(R.id.rec_next,
            WidgetIntents.recommendationBrowse(context, id, 1))
        views.setOnClickPendingIntent(R.id.rec_left,
            WidgetIntents.recommendationBrowse(context, id, -1))
        views.setOnClickPendingIntent(R.id.rec_right,
            WidgetIntents.recommendationBrowse(context, id, 1))
        views.setOnClickPendingIntent(R.id.rec_center,
            if (hasSelection) WidgetIntents.recommendationPlay(context, id)
            else WidgetIntents.openApp(context, 701))
        views.setOnClickPendingIntent(R.id.rec_play,
            if (hasSelection) WidgetIntents.recommendationPlay(context, id)
            else WidgetIntents.openApp(context, 702))
        views.setOnClickPendingIntent(R.id.rec_heading, WidgetIntents.openApp(context, 700))
        return views
    }
}
