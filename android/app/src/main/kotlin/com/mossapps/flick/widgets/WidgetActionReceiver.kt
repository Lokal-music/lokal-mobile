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
        val engine = FlutterEngineCache.getInstance().get("main_engine")
        if (engine == null) {
            openPlayer()
        } else {
            // A cached headless/Android Auto engine is NOT proof that the UI
            // widget handler has attached. If Dart reports notImplemented or
            // fails, launch the activity so the saved command is consumed.
            MethodChannel(engine.dartExecutor.binaryMessenger, "com.mossapps.flick/widget")
                .invokeMethod("dispatchPending", null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (result != true) openPlayer()
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        openPlayer()
                    }
                    override fun notImplemented() {
                        openPlayer()
                    }
                })
        }
    }
}
