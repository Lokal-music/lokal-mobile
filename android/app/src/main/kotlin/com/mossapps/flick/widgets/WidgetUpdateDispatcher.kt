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
        val token = generations.getOrPut(provider.javaClass.name) { AtomicLong() }
        val requested = token.incrementAndGet()
        executor.execute {
            try {
                // Sliders, resize events and rapid tracks can enqueue many
                // broadcasts; draw only the newest state for each provider.
                if (requested != token.get()) return@execute
                for (id in ids) {
                    if (requested != token.get()) break
                    try {
                        manager.updateAppWidget(id, render(id))
                    } catch (e: Exception) {
                        Log.e(TAG, "Widget update failed for id=$id; using safe fallback", e)
                        try {
                            val fallback = RemoteViews(appContext.packageName, R.layout.widget_compact)
                            fallback.setTextViewText(
                                R.id.compact_title,
                                appContext.getString(R.string.widget_tap_to_open),
                            )
                            fallback.setOnClickPendingIntent(
                                R.id.compact_title, WidgetIntents.openApp(appContext, 60),
                            )
                            fallback.setViewVisibility(R.id.compact_artist, android.view.View.GONE)
                            fallback.setViewVisibility(R.id.compact_controls, android.view.View.GONE)
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
