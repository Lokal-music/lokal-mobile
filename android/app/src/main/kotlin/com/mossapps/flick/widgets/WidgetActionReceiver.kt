package com.mossapps.flick.widgets

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.os.Handler
import android.os.Looper
import android.appwidget.AppWidgetManager
import org.json.JSONArray
import java.util.concurrent.atomic.AtomicBoolean
import com.mossapps.flick.MainActivity
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/** Commands survive the gap between launcher tap and Flutter initialization. */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val uri = intent.data?.toString() ?: return
        if (!uri.startsWith("flickwidget://")) return
        // Browsing does not need to start Flutter. Update just the selected
        // widget ID, so the launcher responds instantly even when Lokal is
        // not running. Playback still uses the durable Dart action inbox.
        val parsed = android.net.Uri.parse(uri)
        if (parsed.host == "recommend" && parsed.path == "/browse") {
            val id = parsed.getQueryParameter("id")?.toIntOrNull() ?: return
            val step = parsed.getQueryParameter("step")?.toIntOrNull()?.coerceIn(-1, 1) ?: return
            val prefs = WidgetPrefs.get(context)
            val count = try {
                JSONArray(prefs.getString(WidgetPrefs.KEY_RECOMMENDATIONS, "[]")).length().coerceAtMost(8)
            } catch (_: Exception) { 0 }
            if (count > 0) {
                val key = WidgetPrefs.recommendationCursor(id)
                val next = (prefs.getInt(key, count / 2) + step).mod(count)
                prefs.edit().putInt(key, next).apply()
                val mgr = AppWidgetManager.getInstance(context)
                CoverFlowRecommendationWidgetProvider()
                    .onUpdate(context, mgr, intArrayOf(id))
            }
            return
        }
        WidgetActionInbox.store(context, uri)
        // Keep this broadcast alive until MethodChannel reports whether a UI
        // handler consumed the command. Otherwise Android may kill a headless
        // process before the cold-start fallback can launch.
        val pending = goAsync()
        val completed = AtomicBoolean(false)
        val handler = Handler(Looper.getMainLooper())
        fun openPlayer() {
            val launch = Intent(context, MainActivity::class.java).apply {
                action = "com.mossapps.flick.WIDGET_LAUNCH"
                data = intent.data
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            try {
                context.startActivity(launch)
            } catch (e: Exception) {
                // Background launch restrictions can block this on Android 14+.
                // The command remains in the inbox until a UI handler attaches.
                Log.w("LokalWidget", "Cannot open player from widget yet", e)
            }
        }
        fun complete(launch: Boolean) {
            if (!completed.compareAndSet(false, true)) return
            try {
                if (launch) openPlayer()
            } finally {
                pending.finish()
            }
        }
        handler.postDelayed({ complete(true) }, 3000L)
        val engine = FlutterEngineCache.getInstance().get("main_engine")
        if (engine == null) {
            complete(true)
        } else {
            // A cached headless/Android Auto engine is NOT proof that the UI
            // widget handler has attached. If Dart reports notImplemented or
            // fails, launch the activity so the saved command is consumed.
            MethodChannel(engine.dartExecutor.binaryMessenger, "com.mossapps.flick/widget")
                .invokeMethod("dispatchPending", null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        complete(result != true)
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        complete(true)
                    }
                    override fun notImplemented() {
                        complete(true)
                    }
                })
        }
    }
}
