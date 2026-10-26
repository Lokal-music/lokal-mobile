package com.mossapps.flick

import android.Manifest
import android.app.NotificationChannel
import com.mossapps.flick.widgets.WidgetPrefs
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Silent library status, independent of playback's notification and controls. */
object LokalLibrarySyncNotification {
    private const val CHANNEL = "lokal_library_sync"
    private const val ID = 1042

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, "lokal/library_sync_notification").setMethodCallHandler { call, result ->
            if (call.method != "update") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val libraryJob = call.argument<String>("kind") == "library_job"
            val channel = if (libraryJob) "lokal_library_jobs" else CHANNEL
            val notificationId = if (libraryJob) 1043 else ID
            val manager = NotificationManagerCompat.from(context)
            if (!manager.areNotificationsEnabled() || (Build.VERSION.SDK_INT >= 33 &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)) {
                result.success(false)
                return@setMethodCallHandler
            }
            val channels = context.getSystemService(NotificationManager::class.java)
            if (channels == null) {
                result.success(false)
                return@setMethodCallHandler
            }
            channels.createNotificationChannel(NotificationChannel(
                channel, WidgetPrefs.localizedText(context, if (libraryJob)
                    R.string.native_library_jobs_channel else R.string.native_library_sync_channel),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = WidgetPrefs.localizedText(context, if (libraryJob)
                    R.string.native_library_jobs_description else R.string.native_library_sync_description)
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            })
            val busy = call.argument<Boolean>("busy") == true
            val processed = (call.argument<Number>("processed")?.toLong() ?: 0L).coerceAtLeast(0L)
            val total = call.argument<Number>("total")?.toLong()
            val message = call.argument<String>("message").orEmpty()
            val open = PendingIntent.getActivity(context, notificationId,
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(call.argument<String>("title") ?:
                    WidgetPrefs.localizedText(context, R.string.native_library_sync_channel))
                .setContentText(message)
                .setStyle(NotificationCompat.BigTextStyle().bigText(message))
                .setSubText(call.argument<String>("deviceName"))
                .setContentIntent(open)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setShowWhen(false)
                .setOngoing(busy)
                .setAutoCancel(!busy)
                // Retire stale progress if Android kills the process; this
                // notification does not claim to keep sync running itself.
                .setTimeoutAfter(if (busy) 120_000L else 20_000L)
            if (busy) {
                if (total != null && total > 0) {
                    builder.setProgress(1000, ((processed.coerceAtMost(total).toDouble() / total) * 1000).toInt(), false)
                } else {
                    builder.setProgress(0, 0, true)
                }
            }
            try {
                manager.notify(notificationId, builder.build())
                result.success(true)
            } catch (_: SecurityException) {
                result.success(false)
            }
        }
    }
}
