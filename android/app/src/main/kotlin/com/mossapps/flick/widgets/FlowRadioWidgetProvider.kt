package com.mossapps.flick.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.view.View
import org.json.JSONArray
import android.widget.RemoteViews
import com.mossapps.flick.R

/** A dedicated, resizable Flow and online Radio launcher with live metadata. */
class FlowRadioWidgetProvider : AppWidgetProvider() {
    override fun onEnabled(context: Context) {
        WidgetPrefs.get(context).edit().putBoolean(WidgetPrefs.KEY_FLOW_ENABLED, true).apply()
    }

    override fun onDisabled(context: Context) {
        WidgetPrefs.get(context).edit().putBoolean(WidgetPrefs.KEY_FLOW_ENABLED, false).apply()
    }

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
        val state = preferences.getString(WidgetPrefs.KEY_FLOW_STATUS, "").orEmpty()
        // Keep Flow's content distinct from Now Playing while always displaying
        // artwork. Prefer a fresh recommendation sleeve, otherwise use the
        // current/previous real cover until a new recommendation is available.
        var art = try {
            val recommendations = JSONArray(
                preferences.getString(WidgetPrefs.KEY_RECOMMENDATIONS, "[]").orEmpty())
            var found: android.graphics.Bitmap? = null
            for (i in 0 until minOf(recommendations.length(), 7)) {
                val path = recommendations.optJSONObject(i)?.optString("artwork").orEmpty()
                found = WidgetArtLoader.load(context, path, if (compact) 160 else 240)
                if (found != null) break
            }
            found
        } catch (_: Exception) { null }
        if (art == null) art = WidgetArtLoader.load(context,
            preferences.getString(WidgetPrefs.KEY_ALBUM_ART, ""), if (compact) 160 else 240)
        if (art == null) art = WidgetArtLoader.load(context,
            preferences.getString(WidgetPrefs.KEY_LAST_ALBUM_ART, ""), if (compact) 160 else 240)
        views.setViewVisibility(R.id.flow_cover, View.VISIBLE)
        if (art != null) views.setImageViewBitmap(R.id.flow_cover, art)
        else views.setImageViewResource(R.id.flow_cover, R.drawable.widget_art_placeholder)
        views.setInt(R.id.flow_root, "setBackgroundResource",
            WidgetArtworkPalette.background(art))
        views.setTextViewText(R.id.flow_title, "Your Flow")
        views.setTextViewText(R.id.flow_status,
            state.ifBlank { "Play a mix curated for you" })
        views.setTextColor(R.id.flow_heading, WidgetPrefs.getAccentColor(context))
        views.setOnClickPendingIntent(R.id.flow_heading, WidgetIntents.openApp(context, 680))
        views.setOnClickPendingIntent(R.id.flow_title, WidgetIntents.openApp(context, 681))
        views.setOnClickPendingIntent(R.id.flow_cover, WidgetIntents.openApp(context, 682))
        views.setOnClickPendingIntent(R.id.flow_action, WidgetIntents.flow(context, "play"))
        views.setOnClickPendingIntent(R.id.flow_shuffle, WidgetIntents.flow(context, "new"))
        views.setOnClickPendingIntent(R.id.flow_radio, WidgetIntents.flow(context, "radio"))
        return views
    }
}
