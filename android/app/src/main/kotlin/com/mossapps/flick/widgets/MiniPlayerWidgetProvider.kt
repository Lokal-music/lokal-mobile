package com.mossapps.flick.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import com.mossapps.flick.R

/**
 * The single Now Playing widget. Layout is selected from the CURRENT launcher
 * dimensions on every resize, rather than exposing three duplicate widgets.
 * Each layout shares view ids so playback and artwork stay in sync.
 */
class MiniPlayerWidgetProvider : AppWidgetProvider() {
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
        val width = WidgetSize.width(manager, id)
        val height = WidgetSize.height(manager, id)
        val layout = when {
            width >= 280 && height >= 145 -> R.layout.widget_now_playing_expanded
            height >= 135 -> R.layout.widget_now_playing_portrait
            else -> R.layout.widget_mini_player
        }
        val horizontal = layout == R.layout.widget_mini_player
        val views = RemoteViews(context.packageName, layout)
        val hasSong = prefs.getBoolean(WidgetPrefs.KEY_HAS_SONG, false)
        val playing = prefs.getBoolean(WidgetPrefs.KEY_IS_PLAYING, false)
        val title = if (hasSong) prefs.getString(WidgetPrefs.KEY_TITLE, "").orEmpty()
            .ifBlank { context.getString(R.string.widget_nothing_playing) }
            else context.getString(R.string.widget_nothing_playing)
        val artist = prefs.getString(WidgetPrefs.KEY_ARTIST, "").orEmpty()
        val position = readMs(prefs, WidgetPrefs.KEY_POSITION_MS)
        val duration = readMs(prefs, WidgetPrefs.KEY_DURATION_MS)
        val accent = WidgetPrefs.getAccentColor(context)

        views.setInt(R.id.widget_root, "setBackgroundResource",
            WidgetPrefs.getBackgroundDrawableRes(context))
        views.setTextViewText(R.id.widget_title, title)
        views.setTextViewTextSize(R.id.widget_title, TypedValue.COMPLEX_UNIT_SP,
            WidgetPrefs.scaledSp(14, width, if (horizontal) 340f else 240f,
                WidgetPrefs.getMiniTextScale(context)).toFloat())
        views.setContentDescription(R.id.widget_title, title)
        views.setOnClickPendingIntent(R.id.widget_title, WidgetIntents.openApp(context, 11))

        val showArtist = hasSong && WidgetPrefs.getShowArtist(context) && artist.isNotBlank()
        views.setViewVisibility(R.id.widget_artist, if (showArtist) View.VISIBLE else View.GONE)
        if (showArtist) {
            views.setTextViewText(R.id.widget_artist, artist)
            views.setTextViewTextSize(R.id.widget_artist, TypedValue.COMPLEX_UNIT_SP,
                WidgetPrefs.scaledSp(11, width, if (horizontal) 340f else 240f,
                    WidgetPrefs.getMiniTextScale(context)).toFloat())
            views.setTextColor(R.id.widget_artist, accent)
            views.setOnClickPendingIntent(R.id.widget_artist, WidgetIntents.openApp(context, 12))
        }

        // Artwork is mandatory at EVERY size. Never hide it for small widget
        // widths and never apply the obsolete show/hide artwork toggle.
        val artworkPath = prefs.getString(WidgetPrefs.KEY_ALBUM_ART, "").orEmpty()
        val previousPath = prefs.getString(WidgetPrefs.KEY_LAST_ALBUM_ART, "").orEmpty()
        val art = if (hasSong) WidgetArtLoader.load(context, artworkPath, 288) else null
        val lastArt = if (art == null) WidgetArtLoader.load(context, previousPath, 288) else null
        views.setViewVisibility(R.id.widget_art_bg, View.VISIBLE)
        if (art != null) views.setImageViewBitmap(R.id.widget_art_bg, art)
        else if (lastArt != null) views.setImageViewBitmap(R.id.widget_art_bg, lastArt)
        else views.setImageViewResource(R.id.widget_art_bg, R.drawable.widget_art_placeholder)
        // Honor explicit background opacity; at the default opacity, use a
        // dark shade derived from the cover like Apple Music's music surfaces.
        if (WidgetPrefs.getBgOpacityAlpha(context) == 0xC0) {
            views.setInt(R.id.widget_root, "setBackgroundResource",
                WidgetArtworkPalette.background(art ?: lastArt))
        }
        views.setOnClickPendingIntent(R.id.widget_art_bg, WidgetIntents.openApp(context, 10))
        views.setViewVisibility(R.id.widget_scrim, View.GONE)

        // Portrait and expanded widgets have room for transport controls;
        // only the thin bar needs to collapse them for narrow launchers.
        val controls = hasSong
        val hasSkip = when (layout) {
            R.layout.widget_mini_player -> width >= 245
            R.layout.widget_now_playing_portrait -> width >= 136
            else -> true
        }
        views.setViewVisibility(R.id.widget_prev, if (controls && hasSkip) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.widget_next, if (controls && hasSkip) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.widget_play_pause, if (controls) View.VISIBLE else View.GONE)
        if (hasSong) {
            views.setImageViewResource(R.id.widget_play_pause,
                if (playing) R.drawable.widget_ic_lucide_pause
                else R.drawable.widget_ic_lucide_play)
            views.setOnClickPendingIntent(R.id.widget_prev, WidgetIntents.playerPrevious(context))
            views.setOnClickPendingIntent(R.id.widget_play_pause, WidgetIntents.playerPlayPause(context))
            views.setOnClickPendingIntent(R.id.widget_next, WidgetIntents.playerNext(context))
        }

        val showProgress = hasSong && duration > 0L &&
            (layout != R.layout.widget_now_playing_portrait || height >= 160) && height >= 64
        views.setViewVisibility(R.id.widget_progress,
            if (showProgress) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.widget_time,
            if (showProgress && width >= 280 && height >= 145) View.VISIBLE else View.GONE)
        if (showProgress) {
            val progress = (position.coerceIn(0L, duration).toDouble() / duration * 1000)
                .toInt().coerceIn(0, 1000)
            views.setProgressBar(R.id.widget_progress, 1000, progress, false)
            views.setTextViewText(R.id.widget_time,
                WidgetSize.time(position) + " / " + WidgetSize.time(duration))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                views.setColorStateList(R.id.widget_progress, "setProgressTintList",
                    ColorStateList.valueOf(accent))
                views.setColorStateList(R.id.widget_progress, "setProgressBackgroundTintList",
                    ColorStateList.valueOf(0x33FFFFFF))
            }
        }
        return views
    }

    private fun readMs(prefs: SharedPreferences, key: String): Long =
        try { prefs.getLong(key, 0L) } catch (_: ClassCastException) {
            try { prefs.getInt(key, 0).toLong() } catch (_: ClassCastException) { 0L }
        }
}
