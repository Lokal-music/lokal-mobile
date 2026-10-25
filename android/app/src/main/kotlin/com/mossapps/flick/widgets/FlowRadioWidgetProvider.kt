package com.mossapps.flick.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.widget.RemoteViews
import com.mossapps.flick.R

/** A dedicated, resizable Flow and online Radio launcher with live metadata. */
class FlowRadioWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        WidgetUpdateDispatcher.submit(this, context, manager, ids) { id ->
            render(context.applicationContext, manager, id)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, appWidgetId: Int,
        newOptions: Bundle,
    ) = onUpdate(context, manager, intArrayOf(appWidgetId))

    private fun render(context: Context, manager: AppWidgetManager, id: Int): RemoteViews {
        val preferences = WidgetPrefs.get(context)
        val compact = !WidgetSize.isWide(manager, id) || !WidgetSize.isTall(manager, id)
        val layout = if (compact) R.layout.widget_flow_radio_small else R.layout.widget_flow_radio
        val views = RemoteViews(context.packageName, layout)
        val playing = preferences.getBoolean(WidgetPrefs.KEY_HAS_SONG, false)
        val title = preferences.getString(WidgetPrefs.KEY_TITLE, "").orEmpty()
        val artist = preferences.getString(WidgetPrefs.KEY_ARTIST, "").orEmpty()
        val state = preferences.getString(WidgetPrefs.KEY_FLOW_STATUS, "").orEmpty()
        views.setTextViewText(R.id.flow_title,
            if (playing && title.isNotBlank()) title else "Your personal soundtrack")
        views.setTextViewText(R.id.flow_status,
            state.ifBlank {
                if (playing) artist.ifBlank { "Playing now" }
                else "Flow learns from your library and listening history"
            })
        views.setTextColor(R.id.flow_heading, WidgetPrefs.getAccentColor(context))
        val artwork = if (playing) WidgetArtLoader.load(
            preferences.getString(WidgetPrefs.KEY_ALBUM_ART, ""), if (compact) 160 else 288
        ) else null
        if (artwork != null) views.setImageViewBitmap(R.id.flow_cover, artwork)
        else views.setImageViewResource(R.id.flow_cover, R.drawable.widget_default_art)
        views.setOnClickPendingIntent(R.id.flow_heading, WidgetIntents.openApp(context, 680))
        views.setOnClickPendingIntent(R.id.flow_title, WidgetIntents.openApp(context, 681))
        views.setOnClickPendingIntent(R.id.flow_action, WidgetIntents.flow(context, "play"))
        views.setOnClickPendingIntent(R.id.flow_shuffle, WidgetIntents.flow(context, "new"))
        views.setOnClickPendingIntent(R.id.flow_radio, WidgetIntents.flow(context, "radio"))
        return views
    }
}
