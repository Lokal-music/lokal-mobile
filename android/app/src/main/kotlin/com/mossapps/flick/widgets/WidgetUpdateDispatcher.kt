package com.mossapps.flick.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.util.Log
import android.widget.RemoteViews
import com.mossapps.flick.R
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * All home widgets use one bounded, off-main-thread renderer. Widget addition
 * is a broadcast: decoding several large bitmaps synchronously in onUpdate()
 * can kill the host process or hit its broadcast timeout.
 *
 * Every widget id is isolated, and a failed update falls back to a small
 * working open-app widget rather than crashing Lokal or leaving a broken view.
 */
internal object WidgetUpdateDispatcher {
    private const val TAG = "LokalWidgets"
    private val executor = Executors.newSingleThreadExecutor()
    private val generations = ConcurrentHashMap<String, AtomicLong>()

    fun submit(
        provider: AppWidgetProvider,
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
        render: (Int) -> RemoteViews,
    ) {
        if (ids.isEmpty()) return
        val result = provider.goAsync()
        val appContext = context.applicationContext
        // A resize for widget A cannot invalidate a still-needed state push
        // for widget B of the same provider. Coalesce per (provider, ID).
        val requested = ids.associateWith { id ->
            val token = generations.getOrPut("${provider.javaClass.name}:$id") {
                AtomicLong()
            }
            token.incrementAndGet()
        }
        executor.execute {
            try {
                for (id in ids) {
                    val key = "${provider.javaClass.name}:$id"
                    if (requested[id] != generations[key]?.get()) continue
                    try {
                        manager.updateAppWidget(id, render(id))
                    } catch (e: Exception) {
                        Log.e(TAG, "Widget update failed for id=$id; using safe fallback", e)
                        try {
                            val fallback = RemoteViews(appContext.packageName, R.layout.widget_compact)
                            // Preserve the saved track metadata and useful
                            // transport commands even if a rich layout fails.
                            val prefs = WidgetPrefs.get(appContext)
                            val hasSong = prefs.getBoolean(WidgetPrefs.KEY_HAS_SONG, false)
                            fallback.setTextViewText(
                                R.id.compact_title,
                                if (hasSong) prefs.getString(WidgetPrefs.KEY_TITLE, "").orEmpty()
                                else appContext.getString(R.string.widget_nothing_playing),
                            )
                            fallback.setTextViewText(
                                R.id.compact_artist,
                                prefs.getString(WidgetPrefs.KEY_ARTIST, "").orEmpty(),
                            )
                            fallback.setViewVisibility(R.id.compact_artist,
                                if (hasSong) android.view.View.VISIBLE else android.view.View.GONE)
                            fallback.setViewVisibility(R.id.compact_controls,
                                if (hasSong) android.view.View.VISIBLE else android.view.View.GONE)
                            fallback.setImageViewResource(R.id.compact_play_pause,
                                if (prefs.getBoolean(WidgetPrefs.KEY_IS_PLAYING, false))
                                    R.drawable.widget_ic_lucide_pause else R.drawable.widget_ic_lucide_play)
                            fallback.setOnClickPendingIntent(
                                R.id.compact_title, WidgetIntents.openApp(appContext, 60))
                            fallback.setOnClickPendingIntent(
                                R.id.compact_prev, WidgetIntents.playerPrevious(appContext))
                            fallback.setOnClickPendingIntent(
                                R.id.compact_play_pause, WidgetIntents.playerPlayPause(appContext))
                            fallback.setOnClickPendingIntent(
                                R.id.compact_next, WidgetIntents.playerNext(appContext))
                            manager.updateAppWidget(id, fallback)
                        } catch (error: Exception) {
                            Log.e(TAG, "Widget fallback failed for id=$id", error)
                        }
                    }
                }
            } finally {
                result?.finish()
            }
        }
    }
}
