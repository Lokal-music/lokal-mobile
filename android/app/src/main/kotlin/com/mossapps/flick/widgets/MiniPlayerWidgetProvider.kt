package com.mossapps.flick.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.os.Build
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import com.mossapps.flick.R

/** One-row transport widget: no text bitmaps, bounded art and reliable taps. */
class MiniPlayerWidgetProvider : AppWidgetProvider() {
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
        val artist = prefs.getString(WidgetPrefs.KEY_ARTIST, "").orEmpty()
        val title = if (hasSong) {
            prefs.getString(WidgetPrefs.KEY_TITLE, "").orEmpty()
                .ifBlank { context.getString(R.string.widget_nothing_playing) }
        } else context.getString(R.string.widget_nothing_playing)
        val position = readMs(prefs, WidgetPrefs.KEY_POSITION_MS)
        val duration = readMs(prefs, WidgetPrefs.KEY_DURATION_MS)
        val accent = WidgetPrefs.getAccentColor(context)
        val width = WidgetSize.width(manager, id)
        val scale = WidgetPrefs.getMiniTextScale(context)
        val views = RemoteViews(context.packageName, R.layout.widget_mini_player)
        views.setInt(R.id.widget_root, "setBackgroundResource",
            WidgetPrefs.getBackgroundDrawableRes(context))
        val timeVisible = hasSong && duration > 0 && WidgetSize.height(manager, id) >= 68
        views.setViewVisibility(R.id.widget_time, if (timeVisible) View.VISIBLE else View.GONE)
        if (timeVisible) views.setTextViewText(R.id.widget_time,
            WidgetSize.time(position) + " / " + WidgetSize.time(duration))
        views.setTextViewText(R.id.widget_title, title)
        views.setTextViewTextSize(R.id.widget_title, TypedValue.COMPLEX_UNIT_SP,
            WidgetPrefs.scaledSp(13, width, 360f, scale).toFloat())
        views.setContentDescription(R.id.widget_title, title)
        views.setOnClickPendingIntent(R.id.widget_title, WidgetIntents.openApp(context, 11))
        if (hasSong && WidgetPrefs.getShowArtist(context) && artist.isNotBlank()) {
            views.setTextViewText(R.id.widget_artist, artist)
            views.setTextViewTextSize(R.id.widget_artist, TypedValue.COMPLEX_UNIT_SP,
                WidgetPrefs.scaledSp(11, width, 360f, scale).toFloat())
            views.setTextColor(R.id.widget_artist, accent)
            views.setViewVisibility(R.id.widget_artist, View.VISIBLE)
            views.setOnClickPendingIntent(R.id.widget_artist, WidgetIntents.openApp(context, 12))
        } else {
            views.setViewVisibility(R.id.widget_artist, View.GONE)
        }

        if (WidgetPrefs.getShowAlbumArt(context)) {
            val art = if (hasSong) WidgetArtLoader.load(
                prefs.getString(WidgetPrefs.KEY_ALBUM_ART, ""), 256
            ) else null
            if (art == null) views.setImageViewResource(R.id.widget_art_bg,
                R.drawable.widget_default_art)
            else views.setImageViewBitmap(R.id.widget_art_bg, art)
            views.setViewVisibility(R.id.widget_art_bg, View.VISIBLE)
            views.setViewVisibility(R.id.widget_scrim, View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_art_bg, View.GONE)
            views.setViewVisibility(R.id.widget_scrim, View.GONE)
        }
        views.setOnClickPendingIntent(R.id.widget_art_bg, WidgetIntents.openApp(context, 10))

        val visible = if (hasSong) View.VISIBLE else View.GONE
        views.setViewVisibility(R.id.widget_prev,
            if (width >= 245) visible else View.GONE)
        views.setViewVisibility(R.id.widget_play_pause, visible)
        views.setViewVisibility(R.id.widget_next,
            if (width >= 245) visible else View.GONE)
        if (hasSong) {
            views.setImageViewResource(R.id.widget_play_pause,
                if (playing) R.drawable.widget_ic_lucide_pause
                else R.drawable.widget_ic_lucide_play)
            views.setOnClickPendingIntent(R.id.widget_prev, WidgetIntents.playerPrevious(context))
            views.setOnClickPendingIntent(R.id.widget_play_pause, WidgetIntents.playerPlayPause(context))
            views.setOnClickPendingIntent(R.id.widget_next, WidgetIntents.playerNext(context))
        }

        if (hasSong && duration > 0) {
            views.setViewVisibility(R.id.widget_progress, View.VISIBLE)
            val progress = ((position.coerceAtLeast(0) * 1000.0) / duration)
                .toInt().coerceIn(0, 1000)
            views.setProgressBar(R.id.widget_progress, 1000, progress, false)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                views.setColorStateList(R.id.widget_progress, "setProgressTintList",
                    ColorStateList.valueOf(accent))
                views.setColorStateList(R.id.widget_progress, "setProgressBackgroundTintList",
                    ColorStateList.valueOf(0x33FFFFFF))
            }
        } else {
            views.setViewVisibility(R.id.widget_progress, View.GONE)
        }
        return views
    }

    private fun readMs(prefs: SharedPreferences, key: String): Long =
        try {
            prefs.getLong(key, 0L)
        } catch (_: ClassCastException) {
            try { prefs.getInt(key, 0).toLong() } catch (_: ClassCastException) { 0L }
        }
}
