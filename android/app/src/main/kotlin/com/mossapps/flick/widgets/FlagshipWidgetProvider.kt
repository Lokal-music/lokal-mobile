package com.mossapps.flick.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.os.Build
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import com.mossapps.flick.R

/**
 * Full-artwork widget. Native labels and one small image avoid the previous
 * 1024px artwork + text bitmap Binder payload that could crash on addition.
 */
class FlagshipWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        WidgetUpdateDispatcher.submit(this, context, manager, ids) { id ->
            render(context.applicationContext, manager, id)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        onUpdate(context, manager, intArrayOf(appWidgetId))
    }

    private fun render(context: Context, manager: AppWidgetManager, id: Int): RemoteViews {
        val prefs = WidgetPrefs.get(context)
        val hasSong = prefs.getBoolean(WidgetPrefs.KEY_HAS_SONG, false)
        val playing = prefs.getBoolean(WidgetPrefs.KEY_IS_PLAYING, false)
        val shuffle = prefs.getBoolean(WidgetPrefs.KEY_IS_SHUFFLE, false)
        val loop = prefs.getInt(WidgetPrefs.KEY_LOOP_MODE, 0)
        val accent = WidgetPrefs.getFlagshipAccentColor(context)
        val artist = prefs.getString(WidgetPrefs.KEY_ARTIST, "").orEmpty()
        val title = if (hasSong) {
            prefs.getString(WidgetPrefs.KEY_TITLE, "").orEmpty()
                .ifBlank { context.getString(R.string.widget_nothing_playing) }
        } else context.getString(R.string.widget_nothing_playing)
        val width = WidgetSize.width(manager, id)
        val scale = WidgetPrefs.getFlagshipTextScale(context)
        val views = RemoteViews(context.packageName, R.layout.widget_flagship_art)

        val art = if (hasSong) WidgetArtLoader.load(
            prefs.getString(WidgetPrefs.KEY_ALBUM_ART, ""), 288
        ) else null
        if (art == null) views.setImageViewResource(
            R.id.flagship_art, R.drawable.widget_default_art
        ) else views.setImageViewBitmap(R.id.flagship_art, art)
        views.setOnClickPendingIntent(R.id.flagship_art, WidgetIntents.openApp(context, 30))

        views.setTextViewText(R.id.flagship_title, title)
        views.setTextViewTextSize(R.id.flagship_title, TypedValue.COMPLEX_UNIT_SP,
            WidgetPrefs.scaledSp(15, width, 400f, scale).toFloat())
        views.setContentDescription(R.id.flagship_title, title)
        views.setOnClickPendingIntent(R.id.flagship_title, WidgetIntents.openApp(context, 31))

        if (hasSong && WidgetPrefs.getFlagshipShowArtist(context) && artist.isNotBlank()) {
            views.setTextViewText(R.id.flagship_artist, artist)
            views.setTextViewTextSize(R.id.flagship_artist, TypedValue.COMPLEX_UNIT_SP,
                WidgetPrefs.scaledSp(12, width, 400f, scale).toFloat())
            views.setTextColor(R.id.flagship_artist, accent)
            views.setViewVisibility(R.id.flagship_artist, View.VISIBLE)
            views.setOnClickPendingIntent(R.id.flagship_artist, WidgetIntents.openApp(context, 32))
        } else {
            views.setViewVisibility(R.id.flagship_artist, View.GONE)
        }

        for (control in intArrayOf(
            R.id.flagship_shuffle, R.id.flagship_prev, R.id.flagship_play_pause,
            R.id.flagship_next, R.id.flagship_repeat,
        )) views.setViewVisibility(control, if (hasSong) View.VISIBLE else View.GONE)

        // The flagship originally overflowed at small launcher cell sizes.
        // Preserve play/pause and metadata while hiding secondary controls.
        val constrained = width < 250 || WidgetSize.height(manager, id) < 172
        if (constrained) {
            views.setViewVisibility(R.id.flagship_shuffle, View.GONE)
            views.setViewVisibility(R.id.flagship_repeat, View.GONE)
        }
        if (hasSong) {
            views.setImageViewResource(R.id.flagship_play_pause,
                if (playing) R.drawable.widget_ic_lucide_pause
                else R.drawable.widget_ic_lucide_play)
            views.setImageViewResource(R.id.flagship_repeat,
                if (loop == 1) R.drawable.widget_ic_repeat1
                else R.drawable.widget_ic_lucide_repeat)
            views.setInt(R.id.flagship_shuffle, "setBackgroundResource",
                if (shuffle) R.drawable.widget_button_transport_active_bg
                else R.drawable.widget_button_transport_bg)
            views.setInt(R.id.flagship_repeat, "setBackgroundResource",
                if (loop != 0) R.drawable.widget_button_transport_active_bg
                else R.drawable.widget_button_transport_bg)
            // ImageView's RemoteViews-safe tint setter.
            views.setInt(R.id.flagship_shuffle, "setColorFilter",
                if (shuffle) accent else 0x88FFFFFF.toInt())
            views.setInt(R.id.flagship_repeat, "setColorFilter",
                if (loop != 0) accent else 0x88FFFFFF.toInt())
            views.setOnClickPendingIntent(R.id.flagship_prev, WidgetIntents.playerPrevious(context))
            views.setOnClickPendingIntent(R.id.flagship_play_pause, WidgetIntents.playerPlayPause(context))
            views.setOnClickPendingIntent(R.id.flagship_next, WidgetIntents.playerNext(context))
            views.setOnClickPendingIntent(R.id.flagship_shuffle, WidgetIntents.playerShuffle(context))
            views.setOnClickPendingIntent(R.id.flagship_repeat, WidgetIntents.playerRepeat(context))
        }
        return views
    }
}
