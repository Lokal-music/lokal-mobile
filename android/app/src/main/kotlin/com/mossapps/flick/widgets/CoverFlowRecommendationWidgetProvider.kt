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
        val layout = if (WidgetSize.isWide(manager, id) && WidgetSize.isTall(manager, id))
            R.layout.widget_recommended_flow else R.layout.widget_recommended_flow_small
        val views = RemoteViews(context.packageName, layout)
        val data = try {
            JSONArray(prefs.getString(WidgetPrefs.KEY_RECOMMENDATIONS, "[]").orEmpty())
        } catch (_: Exception) { JSONArray() }
        val count = data.length().coerceAtMost(8)
        val indexKey = WidgetPrefs.recommendationCursor(id)
        val position = if (count > 0) prefs.getInt(indexKey, 0).mod(count) else 0
        if (count > 0) {
            val item = data.optJSONObject(position)
            val title = item?.optString("title").orEmpty()
            val artist = item?.optString("artist").orEmpty()
            views.setTextViewText(R.id.rec_title, title.ifBlank { "Recommended for you" })
            views.setTextViewText(R.id.rec_artist,
                artist.ifBlank { "From your listening" } + "  •  " + (position + 1) + "/" + count)
        } else {
            views.setTextViewText(R.id.rec_title, "Discover your next song")
            views.setTextViewText(R.id.rec_artist, "Play music in Lokal to discover similar tracks")
        }

        fun art(viewId: Int, position: Int) {
            val path = if (count == 0) "" else
                data.optJSONObject(position.mod(count))?.optString("artwork").orEmpty()
            val image = WidgetArtLoader.load(path, 184)
            if (image != null) views.setImageViewBitmap(viewId, image)
            else views.setImageViewResource(viewId, R.drawable.widget_default_art)
        }
        art(R.id.rec_center, position)
        art(R.id.rec_left, position - 1)
        art(R.id.rec_right, position + 1)
        views.setOnClickPendingIntent(R.id.rec_prev,
            WidgetIntents.recommendationBrowse(context, id, -1))
        views.setOnClickPendingIntent(R.id.rec_next,
            WidgetIntents.recommendationBrowse(context, id, 1))
        views.setOnClickPendingIntent(R.id.rec_left,
            WidgetIntents.recommendationBrowse(context, id, -1))
        views.setOnClickPendingIntent(R.id.rec_right,
            WidgetIntents.recommendationBrowse(context, id, 1))
        views.setOnClickPendingIntent(R.id.rec_center,
            WidgetIntents.recommendationPlay(context, id))
        views.setOnClickPendingIntent(R.id.rec_play,
            WidgetIntents.recommendationPlay(context, id))
        views.setOnClickPendingIntent(R.id.rec_heading, WidgetIntents.openApp(context, 700))
        return views
    }
}
