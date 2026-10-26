package com.mossapps.flick

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.MediaDescriptionCompat
import android.support.v4.media.MediaMetadataCompat
import android.net.Uri
import android.os.Bundle
import androidx.media.MediaBrowserServiceCompat
import java.util.concurrent.atomic.AtomicBoolean
import androidx.media.VolumeProviderCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat as MediaNotificationCompat
import com.mossapps.flick.widgets.WidgetPrefs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class MusicNotificationService : MediaBrowserServiceCompat() {

    companion object {
        const val CHANNEL_ID = "flick_music_channel"
        const val NOTIFICATION_ID = 1001
        private const val CAR_ROOT_ID = "lokal/root"
        const val ACTION_PLAY_PAUSE = "com.mossapps.flick.PLAY_PAUSE"
        const val ACTION_NEXT = "com.mossapps.flick.NEXT"
        const val ACTION_PREVIOUS = "com.mossapps.flick.PREVIOUS"
        const val ACTION_STOP = "com.mossapps.flick.STOP"
        const val ACTION_SHUFFLE = "com.mossapps.flick.SHUFFLE"
        const val ACTION_FAVORITE = "com.mossapps.flick.FAVORITE"
        const val ACTION_DISCONNECT_CAST = "com.mossapps.flick.DISCONNECT_CAST"

        private const val PLAYER_CHANNEL = "com.mossapps.flick/player"
    }

    private lateinit var mediaSession: MediaSessionCompat
    private lateinit var notificationManager: NotificationManager
    private var methodChannel: MethodChannel? = null
    private var carEngineStarting = false
    private var carClientConnected = false
    private val pendingCarBrowses = mutableListOf<Pair<String, Result<List<MediaBrowserCompat.MediaItem>>>>()
    private external fun nativeInitRustAndroidContext(context: Context): Boolean

    private var isForegroundServiceStarted = false
    private var wakeLock: PowerManager.WakeLock? = null

    private var currentTitle: String = "Unknown"
    private var currentArtist: String = "Unknown Artist"
    private var currentAlbumArtPath: String? = null
    private var isPlaying: Boolean = false
    private var currentDuration: Long = 0
    private var currentPosition: Long = 0
    private var isShuffleMode: Boolean = false
    private var isFavorite: Boolean = false
    private var currentColor: Int? = null
    private var currentOutputName: String? = null
    private var fallbackArt: Bitmap? = null
    private var fallbackAccent: String? = null
    private var isCasting: Boolean = false
    /** A live stream (internet radio): no next/previous, seek, shuffle or favorite. */
    private var isLive: Boolean = false
    private var castDeviceName: String? = null
    private var castVolumePercent: Int = 70
    private var castVolumeProvider: VolumeProviderCompat? = null

    private var cachedAlbumArt: Bitmap? = null
    private var cachedAlbumArtPath: String? = null

    private var floatingOverlay: FloatingPlayerOverlay? = null

    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            android.util.Log.d("MusicNotification", "Received action: ${intent?.action}")
            when (intent?.action) {
                ACTION_PLAY_PAUSE -> {
                    android.util.Log.d("MusicNotification", "Play/Pause tapped. Current isPlaying=$isPlaying")
                    sendCommandToFlutter("togglePlayPause")
                    isPlaying = !isPlaying
                    val notification = buildNotification()
                    notificationManager.notify(NOTIFICATION_ID, notification)
                    android.util.Log.d("MusicNotification", "Optimistically updated to isPlaying=$isPlaying")
                }
                ACTION_NEXT -> {
                    android.util.Log.d("MusicNotification", "Next action triggered")
                    sendCommandToFlutter("next")
                }
                ACTION_PREVIOUS -> {
                    android.util.Log.d("MusicNotification", "Previous action triggered")
                    sendCommandToFlutter("previous")
                }
                ACTION_STOP -> {
                    android.util.Log.d("MusicNotification", "Stop action triggered")
                    sendCommandToFlutter("stop")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                ACTION_SHUFFLE -> {
                    android.util.Log.d("MusicNotification", "Shuffle action triggered")
                    isShuffleMode = !isShuffleMode
                    sendCommandToFlutter("toggleShuffle")
                    val notification = buildNotification()
                    notificationManager.notify(NOTIFICATION_ID, notification)
                }
                ACTION_FAVORITE -> {
                    android.util.Log.d("MusicNotification", "Favorite action triggered")
                    isFavorite = !isFavorite
                    sendCommandToFlutter("toggleFavorite")
                    val notification = buildNotification()
                    notificationManager.notify(NOTIFICATION_ID, notification)
                }
                ACTION_DISCONNECT_CAST -> {
                    android.util.Log.d("MusicNotification", "Disconnect cast action triggered")
                    sendCommandToFlutter("disconnectCast")
                }
            }
        }
    }

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                // ponytail: audio is on the TV while casting — headphone unplug
                // says nothing about remote playback.
                if (isCasting) {
                    android.util.Log.d(
                        "MusicNotification",
                        "ACTION_AUDIO_BECOMING_NOISY ignored while casting"
                    )
                    return
                }
                if (isPauseOnDisconnectEnabled()) {
                    android.util.Log.d(
                        "MusicNotification",
                        "ACTION_AUDIO_BECOMING_NOISY → pause"
                    )
                    sendCommandToFlutter("pause")
                } else {
                    android.util.Log.d(
                        "MusicNotification",
                        "[AudioFocus] ACTION_AUDIO_BECOMING_NOISY observed; pause-on-disconnect disabled"
                    )
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()
        setupMediaSession()
        // The car's MediaBrowser and the lock screen share this same session.
        setSessionToken(mediaSession.sessionToken)

        val filter = IntentFilter().apply {
            addAction(ACTION_PLAY_PAUSE)
            addAction(ACTION_NEXT)
            addAction(ACTION_PREVIOUS)
            addAction(ACTION_STOP)
            addAction(ACTION_SHUFFLE)
            addAction(ACTION_FAVORITE)
            addAction(ACTION_DISCONNECT_CAST)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(actionReceiver, filter)
        }

        val noisyFilter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            registerReceiver(noisyReceiver, noisyFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(noisyReceiver, noisyFilter)
        }

        FlutterEngineCache.getInstance().get("main_engine")?.let { engine ->
            methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, PLAYER_CHANNEL)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.let {
            if (it.hasExtra("title")) currentTitle = it.getStringExtra("title") ?: "Unknown"
            if (it.hasExtra("artist")) currentArtist = it.getStringExtra("artist") ?: "Unknown Artist"
            if (it.hasExtra("albumArtPath")) currentAlbumArtPath = it.getStringExtra("albumArtPath")
            if (it.hasExtra("outputName")) currentOutputName = it.getStringExtra("outputName")
            if (it.hasExtra("isPlaying")) isPlaying = it.getBooleanExtra("isPlaying", false)
            if (it.hasExtra("duration")) {
                currentDuration = it.getLongExtra("duration", -1L).takeIf { v -> v != -1L }
                    ?: it.getIntExtra("duration", 0).toLong()
            }
            if (it.hasExtra("position")) {
                currentPosition = it.getLongExtra("position", -1L).takeIf { v -> v != -1L }
                    ?: it.getIntExtra("position", 0).toLong()
            }
            if (it.hasExtra("isShuffle")) isShuffleMode = it.getBooleanExtra("isShuffle", false)
            if (it.hasExtra("isFavorite")) isFavorite = it.getBooleanExtra("isFavorite", false)
            if (it.hasExtra("color")) currentColor = it.getIntExtra("color", 0)
            if (it.hasExtra("isCasting")) isCasting = it.getBooleanExtra("isCasting", false)
            if (it.hasExtra("isLive")) isLive = it.getBooleanExtra("isLive", false)
            if (it.hasExtra("castDeviceName")) castDeviceName = it.getStringExtra("castDeviceName")
            if (it.hasExtra("castVolume")) {
                castVolumePercent = it.getIntExtra("castVolume", 70).coerceIn(0, 100)
            }

            it.getStringExtra("floating")?.let { action ->
                when (action) {
                    "show" -> showFloatingOverlay()
                    "hide" -> hideFloatingOverlay()
                }
            }
        }

        if (floatingOverlay?.shown == true) {
            floatingOverlay?.update(
                currentTitle, currentArtist, getAlbumArtBitmap(), isPlaying,
                currentDuration, currentPosition
            )
        }

        syncAudioFocusState()
        syncCastRouting()

        val notification = buildNotification()

        if (!isForegroundServiceStarted) {
            android.util.Log.d("MusicNotification", "Starting foreground service: isPlaying=$isPlaying")
            startForeground(NOTIFICATION_ID, notification)
            isForegroundServiceStarted = true
        } else {
            android.util.Log.d("MusicNotification", "Updating notification: isPlaying=$isPlaying, position=$currentPosition, duration=$currentDuration")
            notificationManager.notify(NOTIFICATION_ID, notification)
        }

        updateWakeLock()

        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (carClientConnected) {
            android.util.Log.d("MusicNotification", "Car media browser is connected; keep playback alive")
            return
        }
        if (isKeepPlayingOnQuit() && isPlaying) {
            android.util.Log.d("MusicNotification", "Task removed but keep-playing enabled; staying alive")
            return
        }
        android.util.Log.d("MusicNotification", "Task removed, shutting down app process")
        shutdownForTaskRemoval()
    }

    private fun isKeepPlayingOnQuit(): Boolean {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            prefs.getBoolean("flutter.app_keep_playing_on_quit", false)
        } catch (e: Exception) {
            false
        }
    }

    private fun isPauseOnDisconnectEnabled(): Boolean {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            prefs.getBoolean("flutter.app_pause_on_bluetooth_disconnect", true)
        } catch (e: Exception) {
            true
        }
    }

    override fun onGetRoot(
        clientPackageName: String,
        clientUid: Int,
        rootHints: Bundle?
    ): BrowserRoot? {
        // Authenticate the claimed package against the Binder UID. Android
        // Auto and system media clients may use different package names.
        val packages = packageManager.getPackagesForUid(clientUid)
        if (packages?.contains(clientPackageName) != true) return null
        // A car may connect before MainActivity has ever run. Initialize
        // Flutter without launching a phone Activity or blocking onGetRoot.
        carClientConnected = true
        Handler(Looper.getMainLooper()).post { ensureCarFlutterEngine() }
        return BrowserRoot(CAR_ROOT_ID, null)
    }

    override fun onUnbind(intent: Intent?): Boolean {
        if (intent?.action == "android.media.browse.MediaBrowserService") {
            carClientConnected = false
        }
        return super.onUnbind(intent)
    }

    override fun onLoadChildren(
        parentId: String,
        result: Result<List<MediaBrowserCompat.MediaItem>>
    ) {
        if (parentId == CAR_ROOT_ID) {
            result.sendResult(
                listOf(
                    carFolder("lokal/songs", WidgetPrefs.localizedText(this, R.string.native_car_songs)),
                    carFolder("lokal/likes", WidgetPrefs.localizedText(this, R.string.native_car_liked_songs)),
                    carFolder("lokal/playlists", WidgetPrefs.localizedText(this, R.string.native_car_playlists)),
                    carFolder("lokal/albums", WidgetPrefs.localizedText(this, R.string.native_car_albums))
                )
            )
            return
        }

        // Repository/playlist lookups run asynchronously in Flutter. Never
        // block Android Auto's binder or expose raw song paths in media IDs.
        val channel = flutterPlayerChannel()
        result.detach()
        if (channel == null || carEngineStarting) {
            // Cache requests until headless Dart has initialized its DB and
            // installed the incoming player channel handler.
            val request = Pair(parentId, result)
            pendingCarBrowses.add(request)
            Handler(Looper.getMainLooper()).postDelayed({
                if (pendingCarBrowses.remove(request)) result.sendResult(emptyList())
            }, 12000L)
            ensureCarFlutterEngine()
            return
        }
        dispatchCarBrowse(parentId, result, channel)
    }

    override fun onSearch(
        query: String,
        extras: Bundle?,
        result: Result<List<MediaBrowserCompat.MediaItem>>
    ) {
        val channel = flutterPlayerChannel()
        if (channel == null || carEngineStarting) {
            result.sendResult(emptyList())
            return
        }
        result.detach()
        dispatchCarBrowse(query, result, channel, "androidAutoSearch", "query")
    }

    private fun dispatchCarBrowse(
        parentId: String,
        result: Result<List<MediaBrowserCompat.MediaItem>>,
        channel: MethodChannel,
        command: String = "androidAutoBrowse",
        argumentName: String = "parentId"
    ) {
        val handler = Handler(Looper.getMainLooper())
        val completed = AtomicBoolean(false)
        val timeout = Runnable {
            if (completed.compareAndSet(false, true)) {
                android.util.Log.w("MusicNotification", "Android Auto browse timed out: $parentId")
                result.sendResult(emptyList())
            }
        }
        handler.postDelayed(timeout, 8000L)
        channel.invokeMethod(
            command,
            mapOf(argumentName to parentId),
            object : MethodChannel.Result {
                override fun success(reply: Any?) {
                    if (!completed.compareAndSet(false, true)) return
                    handler.removeCallbacks(timeout)
                    val entries = (reply as? List<*>)?.mapNotNull(::carEntry) ?: emptyList()
                    result.sendResult(entries)
                }

                override fun error(code: String, message: String?, details: Any?) {
                    android.util.Log.w("MusicNotification", "Car browse failed: $code ($message)")
                    finishEmpty()
                }

                override fun notImplemented() {
                    finishEmpty()
                }

                private fun finishEmpty() {
                    if (!completed.compareAndSet(false, true)) return
                    handler.removeCallbacks(timeout)
                    result.sendResult(emptyList())
                }
            }
        )
    }

    private fun carFolder(mediaId: String, name: String): MediaBrowserCompat.MediaItem =
        MediaBrowserCompat.MediaItem(
            MediaDescriptionCompat.Builder().setMediaId(mediaId).setTitle(name).build(),
            MediaBrowserCompat.MediaItem.FLAG_BROWSABLE
        )

    private fun carEntry(value: Any?): MediaBrowserCompat.MediaItem? {
        val row = value as? Map<*, *> ?: return null
        val id = (row["id"] as? String)?.takeIf { it.startsWith("lokal/") } ?: return null
        val title = (row["title"] as? String)?.takeIf { it.isNotBlank() } ?: return null
        val description = MediaDescriptionCompat.Builder().setMediaId(id).setTitle(title)
        (row["subtitle"] as? String)?.let(description::setSubtitle)
        val artwork = row["artUri"] as? String
        if (artwork?.startsWith("content://") == true ||
            artwork?.startsWith("https://") == true) {
            description.setIconUri(Uri.parse(artwork))
        }
        val flag = if (row["playable"] == true)
            MediaBrowserCompat.MediaItem.FLAG_PLAYABLE
        else MediaBrowserCompat.MediaItem.FLAG_BROWSABLE
        return MediaBrowserCompat.MediaItem(description.build(), flag)
    }

    /** Start the same Dart entrypoint when the car is the first app client. */
    private fun ensureCarFlutterEngine() {
        if (FlutterEngineCache.getInstance().get("main_engine") != null) return
        if (carEngineStarting) return
        carEngineStarting = true
        try {
            System.loadLibrary("rust_lib_flick_player")
            nativeInitRustAndroidContext(applicationContext)

            val engine = FlutterEngine(applicationContext, null, false)
            MainActivity.registerPluginsForMainEngine(engine)
            val messenger = engine.dartExecutor.binaryMessenger

            // Only the subset of native methods required during headless car
            // playback is registered here. MainActivity replaces these when
            // the user opens the phone UI.
            MethodChannel(messenger, PLAYER_CHANNEL).setMethodCallHandler { call, reply ->
                when (call.method) {
                    "androidAutoReady" -> {
                        carEngineStarting = false
                        reply.success(null)
                        val waiting = pendingCarBrowses.toList()
                        pendingCarBrowses.clear()
                        val channel = flutterPlayerChannel()
                        waiting.forEach { (id, result) ->
                            if (channel == null) result.sendResult(emptyList())
                            else dispatchCarBrowse(id, result, channel)
                        }
                        listOf("lokal/songs", "lokal/likes", "lokal/playlists", "lokal/albums")
                            .forEach { id -> notifyChildrenChanged(id) }
                    }
                    "showNotification", "updateNotification" -> {
                        try {
                            startCarNotification(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
                            reply.success(null)
                        } catch (error: Exception) {
                            reply.error("CAR_NOTIFICATION", error.message, null)
                        }
                    }
                    "hideNotification" -> {
                        stopSelf()
                        reply.success(null)
                    }
                    else -> reply.notImplemented()
                }
            }
            // MainActivity normally owns this handoff channel. There is no
            // pending phone intent to consume in a car-only startup.
            MethodChannel(messenger, "com.mossapps.flick/integration")
                .setMethodCallHandler { call, reply ->
                    if (call.method == "consumePendingExternalPlayback") reply.success(null)
                    else reply.notImplemented()
                }

            FlutterEngineCache.getInstance().put("main_engine", engine)
            methodChannel = MethodChannel(messenger, PLAYER_CHANNEL)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
        } catch (error: Exception) {
            android.util.Log.e("MusicNotification", "Android Auto Flutter bootstrap failed", error)
            carEngineStarting = false
            val waiting = pendingCarBrowses.toList()
            pendingCarBrowses.clear()
            waiting.forEach { (_, result) -> result.sendResult(emptyList()) }
        }
    }

    private fun startCarNotification(args: Map<*, *>) {
        val intent = Intent(this, MusicNotificationService::class.java)
        val fields = listOf(
            "title", "artist", "albumArtPath", "outputName", "castDeviceName"
        )
        fields.forEach { key ->
            if (args.containsKey(key)) intent.putExtra(key, args[key] as? String)
        }
        listOf("isPlaying", "isShuffle", "isFavorite", "isCasting", "isLive")
            .forEach { key ->
                (args[key] as? Boolean)?.let { intent.putExtra(key, it) }
            }
        listOf("duration", "position").forEach { key ->
            (args[key] as? Number)?.let { intent.putExtra(key, it.toLong()) }
        }
        listOf("color", "castVolume").forEach { key ->
            (args[key] as? Number)?.let { intent.putExtra(key, it.toInt()) }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun flutterPlayerChannel(): MethodChannel? {
        if (methodChannel == null) {
            FlutterEngineCache.getInstance().get("main_engine")?.let { engine ->
                methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, PLAYER_CHANNEL)
            }
        }
        return methodChannel
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(actionReceiver)
        } catch (e: Exception) {
        }
        try {
            unregisterReceiver(noisyReceiver)
        } catch (e: Exception) {
        }
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        wakeLock = null
        detachCastVolume()
        mediaSession.release()
        isForegroundServiceStarted = false
        hideFloatingOverlay()
    }

    private fun shutdownForTaskRemoval() {
        // Playback dies with the process; mirror that on home-screen widgets so the
        // play/pause icon can't stay stuck on "playing" after the app is killed.
        try {
            WidgetPrefs.get(this).edit().putBoolean(WidgetPrefs.KEY_IS_PLAYING, false).apply()
            WidgetPrefs.updateAllWidgets(this)
        } catch (_: Exception) {
        }

        try {
            if (isForegroundServiceStarted) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            }
        } catch (_: Exception) {
        }

        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        wakeLock = null

        try {
            FlutterEngineCache.getInstance().remove("main_engine")
        } catch (_: Exception) {
        }

        stopSelf()

        Handler(Looper.getMainLooper()).post {
            android.os.Process.killProcess(android.os.Process.myPid())
        }
    }

    private fun getFallbackArt(): Bitmap? {
        val accent = getSharedPreferences("lokal_launcher_icon", MODE_PRIVATE)
            .getString("wanted", "lime") ?: "lime"
        if (fallbackArt != null && fallbackAccent == accent) return fallbackArt
        val id = resources.getIdentifier("ic_lokal_$accent", "mipmap", packageName)
        val drawable = getDrawable(if (id != 0) id else R.mipmap.ic_lokal_lime) ?: return null
        val bitmap = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, 256, 256)
        drawable.draw(Canvas(bitmap))
        fallbackArt = bitmap
        fallbackAccent = accent
        return bitmap
    }

    private fun getAlbumArtBitmap(): Bitmap? {
        val path = currentAlbumArtPath
        if (path.isNullOrEmpty()) {
            cachedAlbumArt = null
            cachedAlbumArtPath = null
            return null
        }
        if (path == cachedAlbumArtPath && cachedAlbumArt != null) {
            return cachedAlbumArt
        }
        cachedAlbumArt = null
        cachedAlbumArtPath = null
        return try {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, options)
            val maxDim = maxOf(options.outWidth, options.outHeight)
            var sampleSize = 1
            while (maxDim / sampleSize > 512) {
                sampleSize *= 2
            }
            val decodeOptions = BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            val bitmap = BitmapFactory.decodeFile(path, decodeOptions)
            if (bitmap != null) {
                cachedAlbumArt = bitmap
                cachedAlbumArtPath = path
            }
            bitmap
        } catch (e: Exception) {
            android.util.Log.w("MusicNotification", "Failed to decode album art: ${e.message}")
            getFallbackArt()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                WidgetPrefs.localizedText(this, R.string.native_music_playback_channel),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = WidgetPrefs.localizedText(this@MusicNotificationService, R.string.native_music_playback_description)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun setupMediaSession() {
        mediaSession = MediaSessionCompat(this, "FlickMusicSession").apply {
            @Suppress("DEPRECATION")
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )

            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() { sendCommandToFlutter("play") }
                override fun onPlayFromMediaId(mediaId: String?, extras: Bundle?) {
                    if (!mediaId.isNullOrEmpty()) {
                        sendCommandToFlutter("androidAutoPlayMediaId", mapOf("mediaId" to mediaId))
                    }
                }
                override fun onPlayFromSearch(query: String?, extras: Bundle?) {
                    if (!query.isNullOrBlank()) {
                        sendCommandToFlutter("androidAutoPlaySearch", mapOf("query" to query))
                    }
                }
                override fun onPause() { sendCommandToFlutter("pause") }
                override fun onSkipToNext() { sendCommandToFlutter("next") }
                override fun onSkipToPrevious() { sendCommandToFlutter("previous") }
                override fun onStop() {
                    sendCommandToFlutter("stop")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                override fun onSeekTo(pos: Long) {
                    sendCommandToFlutter("seek", mapOf("position" to pos))
                }
                override fun onSetShuffleMode(shuffleMode: Int) {
                    sendCommandToFlutter("toggleShuffle")
                }
                override fun onCustomAction(action: String?, extras: android.os.Bundle?) {
                    android.util.Log.d("MusicNotification", "Custom action received: $action")
                    when (action) {
                        ACTION_SHUFFLE -> {
                            isShuffleMode = !isShuffleMode
                            sendCommandToFlutter("toggleShuffle")
                            updatePlaybackState()
                            val notification = buildNotification()
                            notificationManager.notify(NOTIFICATION_ID, notification)
                        }
                        ACTION_FAVORITE -> {
                            isFavorite = !isFavorite
                            sendCommandToFlutter("toggleFavorite")
                            updatePlaybackState()
                            val notification = buildNotification()
                            notificationManager.notify(NOTIFICATION_ID, notification)
                        }
                    }
                }
            })

            isActive = true
        }

        updateMediaSessionMetadata()
        updatePlaybackState()
    }

    private fun updateMediaSessionMetadata() {
        val metadata = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, currentArtist)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, currentDuration)

        getAlbumArtBitmap()?.let { bitmap ->
            metadata.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bitmap)
        }

        mediaSession.setMetadata(metadata.build())
    }

    private fun updatePlaybackState() {
        val state = if (isPlaying) PlaybackStateCompat.STATE_PLAYING
                    else PlaybackStateCompat.STATE_PAUSED
        val playbackSpeed = if (isPlaying) 1.0f else 0.0f

        mediaSession.setShuffleMode(
            if (isShuffleMode) PlaybackStateCompat.SHUFFLE_MODE_ALL
            else PlaybackStateCompat.SHUFFLE_MODE_NONE
        )

        val baseActions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_STOP
        val stateBuilder = PlaybackStateCompat.Builder()
            .setActions(
                if (isLive) baseActions
                else baseActions or
                    PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                    PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackStateCompat.ACTION_SEEK_TO or
                    PlaybackStateCompat.ACTION_SET_SHUFFLE_MODE
            )
            .setState(state, currentPosition, playbackSpeed, android.os.SystemClock.elapsedRealtime())

        if (!isLive && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val shuffleIcon = if (isShuffleMode) R.drawable.ic_shuffle_on else R.drawable.ic_shuffle
            val shuffleTitle = if (isShuffleMode) "Shuffle On" else "Shuffle Off"
            
            stateBuilder.addCustomAction(
                PlaybackStateCompat.CustomAction.Builder(
                    ACTION_SHUFFLE,
                    shuffleTitle,
                    shuffleIcon
                ).build()
            )

            val favoriteIcon = if (isFavorite) R.drawable.ic_favorite else R.drawable.ic_favorite_border
            val favoriteTitle = if (isFavorite) "Unfavorite" else "Favorite"
            
            stateBuilder.addCustomAction(
                PlaybackStateCompat.CustomAction.Builder(
                    ACTION_FAVORITE,
                    favoriteTitle,
                    favoriteIcon
                ).build()
            )
        }

        mediaSession.setPlaybackState(stateBuilder.build())
    }

    private fun updateWakeLock() {
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (pm == null) {
            android.util.Log.w("MusicNotification", "[WakeLock] PowerManager unavailable")
            return
        }

        if (isPlaying) {
            if (wakeLock == null) {
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "Flick:audio_playback"
                ).apply {
                    setReferenceCounted(false)
                }
            }
            if (wakeLock?.isHeld != true) {
                wakeLock?.acquire(/* 1 hour max, auto-renewed on each notification update */)
                android.util.Log.d("MusicNotification", "[WakeLock] Acquired PARTIAL_WAKE_LOCK")
            }
        } else {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
                android.util.Log.d("MusicNotification", "[WakeLock] Released PARTIAL_WAKE_LOCK")
            }
        }
    }

    private fun syncAudioFocusState() {
        android.util.Log.d(
            "MusicNotification",
            "[AudioFocus] Notification service defers focus ownership to the active playback engine (isPlaying=$isPlaying)"
        )
    }

    // ponytail: setPlaybackToRemote is what flips the system volume panel to the
    // cast target (TV icon, remote slider, hardware keys forwarded to us).
    // Route descriptor publishing alone doesn't do that.
    private fun syncCastRouting() {
        if (isCasting && castVolumeProvider == null) {
            attachCastVolume()
        } else if (!isCasting && castVolumeProvider != null) {
            detachCastVolume()
        }
        castVolumeProvider?.setCurrentVolume(castVolumePercent)
    }

    private fun attachCastVolume() {
        val provider = object : VolumeProviderCompat(
            VOLUME_CONTROL_ABSOLUTE,
            100,
            castVolumePercent
        ) {
            override fun onSetVolumeTo(volumeIndex: Int) {
                val clamped = volumeIndex.coerceIn(0, 100)
                castVolumePercent = clamped
                sendCommandToFlutter("setCastVolume", mapOf("volume" to clamped / 100.0))
            }

            override fun onAdjustVolume(direction: Int) {
                onSetVolumeTo(castVolumePercent + direction * 10)
            }
        }
        castVolumeProvider = provider
        mediaSession.setPlaybackToRemote(provider)
        android.util.Log.d("MusicNotification", "[Cast] MediaSession → remote volume (${castDeviceName ?: "unknown"})")
    }

    private fun detachCastVolume() {
        if (castVolumeProvider == null) return
        mediaSession.setPlaybackToLocal(AudioManager.STREAM_MUSIC)
        castVolumeProvider = null
        android.util.Log.d("MusicNotification", "[Cast] MediaSession → local volume")
    }

    private fun buildNotification(): Notification {
        updateMediaSessionMetadata()
        updatePlaybackState()

        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.let { intent ->
            intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        val albumArt: Bitmap? = getAlbumArtBitmap()

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(currentTitle)
            .setContentText(currentArtist)
            .setSubText(
                if (!currentOutputName.isNullOrBlank()) currentOutputName
                else if (isCasting) String.format(
                    WidgetPrefs.localizedText(this, R.string.native_music_casting_to),
                    castDeviceName ?: WidgetPrefs.localizedText(this, R.string.native_music_device),
                )
                else "${formatTime(currentPosition)} / ${formatTime(currentDuration)}"
            )
            .setSmallIcon(R.drawable.ic_notification)
            .setLargeIcon(albumArt)
            .setContentIntent(contentIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setOngoing(true)

        currentColor?.let { color ->
            builder.setColor(color)
            builder.setColorized(true)
        }

        if (isLive) {
            // A live station: play/pause only, no next/previous.
            val playPauseIntent = pendingBroadcast(100, ACTION_PLAY_PAUSE)
            val playPauseIcon = if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
            val playPauseText = WidgetPrefs.localizedText(this, if (isPlaying)
                R.string.native_music_action_pause else R.string.native_music_action_play)
            builder
                .setSubText(null)
                .addAction(playPauseIcon, playPauseText, playPauseIntent)
                .setStyle(
                    MediaNotificationCompat.MediaStyle()
                        .setMediaSession(mediaSession.sessionToken)
                        .setShowActionsInCompactView(0)
                        .setShowCancelButton(true)
                )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val playPauseIntent = pendingBroadcast(100, ACTION_PLAY_PAUSE)
            val prevIntent = pendingBroadcast(101, ACTION_PREVIOUS)
            val nextIntent = pendingBroadcast(102, ACTION_NEXT)

            val playPauseIcon = if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
            val playPauseText = WidgetPrefs.localizedText(this, if (isPlaying)
                R.string.native_music_action_pause else R.string.native_music_action_play)

            if (isCasting) {
                val disconnectIntent = pendingBroadcast(105, ACTION_DISCONNECT_CAST)
                builder
                    .addAction(R.drawable.ic_previous,
                        WidgetPrefs.localizedText(this, R.string.native_music_action_previous), prevIntent)
                    .addAction(playPauseIcon, playPauseText, playPauseIntent)
                    .addAction(R.drawable.ic_cast,
                        WidgetPrefs.localizedText(this, R.string.native_music_action_disconnect), disconnectIntent)
                    .setStyle(
                        MediaNotificationCompat.MediaStyle()
                            .setMediaSession(mediaSession.sessionToken)
                            .setShowActionsInCompactView(0, 1, 2)
                            .setShowCancelButton(true)
                    )
            } else {
                builder
                    .addAction(R.drawable.ic_previous,
                        WidgetPrefs.localizedText(this, R.string.native_music_action_previous), prevIntent)
                    .addAction(playPauseIcon, playPauseText, playPauseIntent)
                    .addAction(R.drawable.ic_next,
                        WidgetPrefs.localizedText(this, R.string.native_music_action_next), nextIntent)
                    .setStyle(
                        MediaNotificationCompat.MediaStyle()
                            .setMediaSession(mediaSession.sessionToken)
                            .setShowActionsInCompactView(0, 1, 2)
                            .setShowCancelButton(true)
                    )
            }
        } else {
            val playPauseIntent = pendingBroadcast(100, ACTION_PLAY_PAUSE)
            val prevIntent = pendingBroadcast(101, ACTION_PREVIOUS)
            val nextIntent = pendingBroadcast(102, ACTION_NEXT)
            val favoriteIntent = pendingBroadcast(103, ACTION_FAVORITE)
            val shuffleIntent = pendingBroadcast(104, ACTION_SHUFFLE)

            val playPauseIcon = if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
            val playPauseText = WidgetPrefs.localizedText(this, if (isPlaying)
                R.string.native_music_action_pause else R.string.native_music_action_play)
            val favoriteIcon = if (isFavorite) R.drawable.ic_favorite else R.drawable.ic_favorite_border
            val favoriteText = WidgetPrefs.localizedText(this, if (isFavorite)
                R.string.native_music_action_unfavorite else R.string.native_music_action_favorite)
            val shuffleIcon = if (isShuffleMode) R.drawable.ic_shuffle_on else R.drawable.ic_shuffle
            val shuffleText = WidgetPrefs.localizedText(this, if (isShuffleMode)
                R.string.native_music_action_shuffle_on else R.string.native_music_action_shuffle_off)

            if (isCasting) {
                val disconnectIntent = pendingBroadcast(105, ACTION_DISCONNECT_CAST)
                builder
                    .addAction(R.drawable.ic_previous,
                        WidgetPrefs.localizedText(this, R.string.native_music_action_previous), prevIntent)
                    .addAction(playPauseIcon, playPauseText, playPauseIntent)
                    .addAction(R.drawable.ic_next,
                        WidgetPrefs.localizedText(this, R.string.native_music_action_next), nextIntent)
                    .addAction(R.drawable.ic_cast,
                        WidgetPrefs.localizedText(this, R.string.native_music_action_disconnect), disconnectIntent)
                    .setStyle(
                        MediaNotificationCompat.MediaStyle()
                            .setMediaSession(mediaSession.sessionToken)
                            .setShowActionsInCompactView(0, 1, 2)
                            .setShowCancelButton(true)
                    )
            } else {
                builder
                    .addAction(R.drawable.ic_previous,
                        WidgetPrefs.localizedText(this, R.string.native_music_action_previous), prevIntent)
                    .addAction(playPauseIcon, playPauseText, playPauseIntent)
                    .addAction(R.drawable.ic_next,
                        WidgetPrefs.localizedText(this, R.string.native_music_action_next), nextIntent)
                    .addAction(shuffleIcon, shuffleText, shuffleIntent)
                    .addAction(favoriteIcon, favoriteText, favoriteIntent)
                    .setStyle(
                        MediaNotificationCompat.MediaStyle()
                            .setMediaSession(mediaSession.sessionToken)
                            .setShowActionsInCompactView(0, 1, 2)
                            .setShowCancelButton(true)
                    )
            }
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && currentDuration > 0) {
            val progress = ((currentPosition.toFloat() / currentDuration.toFloat()) * 100).toInt()
            builder.setProgress(100, progress, false)
        }

        return builder.build()
    }

    private fun pendingBroadcast(requestCode: Int, action: String): PendingIntent =
        PendingIntent.getBroadcast(
            this,
            requestCode,
            Intent(action).apply { setPackage(packageName) },
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun formatTime(millis: Long): String {
        val seconds = (millis / 1000).toInt()
        return String.format("%d:%02d", seconds / 60, seconds % 60)
    }

    fun updateNotification(
        title: String?, artist: String?, albumArtPath: String?,
        playing: Boolean?, duration: Long?, position: Long?,
        shuffle: Boolean?, favorite: Boolean?, color: Int? = null,
        casting: Boolean? = null, castName: String? = null, castVolume: Int? = null
    ) {
        title?.let { currentTitle = it }
        artist?.let { currentArtist = it }
        albumArtPath?.let { currentAlbumArtPath = it }
        playing?.let { isPlaying = it }
        duration?.let { currentDuration = it }
        position?.let { currentPosition = it }
        shuffle?.let { isShuffleMode = it }
        favorite?.let { isFavorite = it }
        color?.let { currentColor = it }
        casting?.let { isCasting = it }
        castName?.let { castDeviceName = it }
        castVolume?.let { castVolumePercent = it.coerceIn(0, 100) }

        val notification = buildNotification()
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    private fun showFloatingOverlay() {
        if (floatingOverlay == null) {
            floatingOverlay = FloatingPlayerOverlay(applicationContext)
        }
        floatingOverlay?.show(currentTitle, currentArtist, getAlbumArtBitmap(), isPlaying, currentDuration, currentPosition)
    }

    private fun hideFloatingOverlay() {
        floatingOverlay?.hide()
    }

    private fun sendCommandToFlutter(command: String, args: Map<String, Any>? = null) {
        android.os.Handler(mainLooper).post {
            try {
                if (methodChannel == null) {
                    android.util.Log.w("MusicNotification", "Method channel null, reconnecting…")
                    flutterPlayerChannel()
                    if (methodChannel == null) {
                        android.util.Log.w("MusicNotification", "No Flutter engine for media command: $command")
                    }
                }

                android.util.Log.d("MusicNotification", "→ Flutter: $command")
                methodChannel?.invokeMethod(command, args, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        android.util.Log.d("MusicNotification", "✓ $command")
                    }
                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        android.util.Log.e("MusicNotification", "✗ $command: $errorCode – $errorMessage")
                    }
                    override fun notImplemented() {
                        android.util.Log.e("MusicNotification", "✗ $command: not implemented")
                    }
                })
            } catch (e: Exception) {
                android.util.Log.e("MusicNotification", "Failed to send $command: ${e.message}", e)
            }
        }
    }
}
