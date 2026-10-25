package com.mossapps.flick.widgets

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.mossapps.flick.MainActivity
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/** Commands survive the gap between launcher tap and Flutter initialization. */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val uri = intent.data?.toString() ?: return
        if (!uri.startsWith("flickwidget://")) return
        WidgetActionInbox.store(context, uri)
        val engine = FlutterEngineCache.getInstance().get("main_engine")
        if (engine != null) {
            MethodChannel(engine.dartExecutor.binaryMessenger, "com.mossapps.flick/widget")
                .invokeMethod("dispatchPending", null)
        } else {
            val launch = Intent(context, MainActivity::class.java).apply {
                action = "com.mossapps.flick.WIDGET_LAUNCH"
                data = intent.data
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            try {
                context.startActivity(launch)
            } catch (e: Exception) {
                // Launch restrictions vary by Android version; the command is
                // safely retained and consumed when the user next opens Lokal.
                Log.w("LokalWidget", "Cannot open player from widget yet", e)
            }
        }
    }
}
