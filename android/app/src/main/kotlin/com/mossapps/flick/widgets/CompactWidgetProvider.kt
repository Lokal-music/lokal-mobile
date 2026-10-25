package com.mossapps.flick.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import android.util.TypedValue
import com.mossapps.flick.R

/** Small 2x2 Lokal player, rendered with native text rather than bitmaps. */
class CompactWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) {
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
        val showArtist = WidgetPrefs.getCompactShowArtist(context)
        val showArt = WidgetPrefs.getCompactShowAlbumArt(context)
        val title = if (hasSong) {
            prefs.getString(WidgetPrefs.KEY_TITLE, "").orEmpty()
                .ifBlank { context.getString(R.string.widget_nothing_playing) }
        } else context.getString(R.string.widget_nothing_playing)
        val artist = prefs.getString(WidgetPrefs.KEY_ARTIST, "").orEmpty()
        val width = WidgetSize.width(manager, id)
        val scale = WidgetPrefs.getCompactTextScale(context)
        val views = RemoteViews(context.packageName, R.layout.widget_compact)
        views.setInt(R.id.compact_root, "setBackgroundResource",
            WidgetPrefs.getCompactBackgroundDrawableRes(context))
        views.setTextViewText(R.id.compact_title, title)
        views.setTextViewTextSize(R.id.compact_title, TypedValue.COMPLEX_UNIT_SP,
            WidgetPrefs.scaledSp(15, width, 200f, scale).toFloat())
        views.setContentDescription(R.id.compact_title, title)
        views.setOnClickPendingIntent(R.id.compact_title, WidgetIntents.openApp(context, 50))

        if (hasSong && showArtist && artist.isNotBlank()) {
            views.setTextViewText(R.id.compact_artist, artist)
            views.setTextViewTextSize(R.id.compact_artist, TypedValue.COMPLEX_UNIT_SP,
                WidgetPrefs.scaledSp(12, width, 200f, scale).toFloat())
            views.setTextColor(R.id.compact_artist, WidgetPrefs.getCompactAccentColor(context))
            views.setViewVisibility(R.id.compact_artist, View.VISIBLE)
            views.setOnClickPendingIntent(R.id.compact_artist, WidgetIntents.openApp(context, 51))
        } else {
            views.setViewVisibility(R.id.compact_artist, View.GONE)
        }

        if (showArt) {
            val art = if (hasSong) WidgetArtLoader.load(
                prefs.getString(WidgetPrefs.KEY_ALBUM_ART, ""), 256
            ) else null
            if (art == null) views.setImageViewResource(
                R.id.compact_art_bg, R.drawable.widget_default_art
            ) else views.setImageViewBitmap(R.id.compact_art_bg, art)
            views.setViewVisibility(R.id.compact_art_bg, View.VISIBLE)
            views.setViewVisibility(R.id.compact_scrim, View.VISIBLE)
            views.setOnClickPendingIntent(R.id.compact_art_bg, WidgetIntents.openApp(context, 52))
        } else {
            views.setViewVisibility(R.id.compact_art_bg, View.GONE)
            views.setViewVisibility(R.id.compact_scrim, View.GONE)
        }

        views.setViewVisibility(R.id.compact_controls,
            if (hasSong && WidgetSize.height(manager, id) >= 104 && width >= 150) View.VISIBLE
            else View.GONE)
        if (hasSong) {
            views.setImageViewResource(R.id.compact_play_pause,
                if (playing) R.drawable.widget_ic_lucide_pause
                else R.drawable.widget_ic_lucide_play)
            views.setOnClickPendingIntent(R.id.compact_prev, WidgetIntents.playerPrevious(context))
            views.setOnClickPendingIntent(R.id.compact_play_pause, WidgetIntents.playerPlayPause(context))
            views.setOnClickPendingIntent(R.id.compact_next, WidgetIntents.playerNext(context))
        }
        return views
    }
}
