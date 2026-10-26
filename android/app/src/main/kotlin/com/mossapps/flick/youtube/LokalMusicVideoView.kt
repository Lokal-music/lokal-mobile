package com.mossapps.flick.youtube

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.LayoutInflater
import com.mossapps.flick.R
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** ExoPlayer's own texture-backed video stage inside Flutter's full player.
 * The two DASH-style direct URLs belong to one video ID. This must never be
 * used for Lokal's separate song recording or for an arbitrary HTTP URL.
 */
internal class LokalMusicVideoFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?> ?: emptyMap()
        return LokalMusicVideoView(context, messenger, viewId, params)
    }
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class LokalMusicVideoView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    params: Map<String, Any?>,
) : PlatformView {
    // Audio is the stable transport/master clock. Video uses an independent
    // muted player so its timeline can be nudged without changing the sound.
    private val audioPlayer = ExoPlayer.Builder(context).build().apply {
        setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true, // Own Android audio focus while native video is playing.
        )
        setHandleAudioBecomingNoisy(true)
    }
    private val videoPlayer = ExoPlayer.Builder(context).build().apply {
        volume = 0f
        trackSelectionParameters = trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
            .build()
    }
    private val syncHandler = Handler(Looper.getMainLooper())
    private var offsetMs = ((params["offsetMs"] as? Number)?.toLong() ?: 0L)
        .coerceIn(-60000L, 60000L)
    private val syncTask = object : Runnable {
        override fun run() {
            if (disposed) return
            syncVideoToAudio()
            syncHandler.postDelayed(this, 250L)
        }
    }
    private val view = (LayoutInflater.from(context).inflate(
        R.layout.lokal_music_video_player, null
    ) as PlayerView).apply {
        useController = false
        setShutterBackgroundColor(android.graphics.Color.BLACK)
        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        // Layout XML supplies a TextureView so Flutter chrome can overlay it.
        this.player = this@LokalMusicVideoView.videoPlayer
        keepScreenOn = true
    }
    private val channel = MethodChannel(messenger, "lokal/media3_video/$viewId")
    private var error: String? = null
    private var disposed = false

    init {
        val listener = object : Player.Listener {
            override fun onPlayerError(exception: PlaybackException) {
                error = "Video couldn't play in Media3"
            }
        }
        audioPlayer.addListener(listener)
        videoPlayer.addListener(listener)
        syncHandler.post(syncTask)
        channel.setMethodCallHandler { call, result ->
            if (disposed) {
                result.error("DISPOSED", "Video view closed", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "snapshot" -> result.success(snapshot())
                "play" -> {
                    audioPlayer.play()
                    syncVideoToAudio(force = true)
                    result.success(snapshot())
                }
                "pause" -> {
                    audioPlayer.pause()
                    videoPlayer.pause()
                    result.success(snapshot())
                }
                "seek" -> {
                    val value = (call.argument<Number>("positionMs")?.toLong() ?: 0L)
                    audioPlayer.seekTo(value.coerceAtLeast(0L))
                    syncVideoToAudio(force = true)
                    result.success(snapshot())
                }
                "setOffset" -> {
                    offsetMs = (call.argument<Number>("offsetMs")?.toLong() ?: 0L)
                        .coerceIn(-60000L, 60000L)
                    syncVideoToAudio(force = true)
                    result.success(snapshot())
                }
                "fill" -> {
                    val fill = call.argument<Boolean>("fill") == true
                    view.resizeMode = if (fill) AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                        else AspectRatioFrameLayout.RESIZE_MODE_FIT
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        try {
            val audio = requireNotNull(params["audioUrl"] as? String)
            val video = requireNotNull(params["videoUrl"] as? String)
            check(isPlayableMediaUrl(audio) && isPlayableMediaUrl(video)) { "Invalid media URL" }
            @Suppress("UNCHECKED_CAST")
            val headers = (params["headers"] as? Map<String, String>) ?: emptyMap()
            val http = DefaultHttpDataSource.Factory()
                .setDefaultRequestProperties(headers)
                .setAllowCrossProtocolRedirects(false)
                .setConnectTimeoutMs(15000)
                .setReadTimeoutMs(20000)
            val sourceFactory = ProgressiveMediaSource.Factory(
                DefaultDataSource.Factory(context, http)
            )
            val audioSource = sourceFactory.createMediaSource(
                MediaItem.fromUri(Uri.parse(audio))
            )
            val videoSource = sourceFactory.createMediaSource(
                MediaItem.fromUri(Uri.parse(video))
            )
            // The two URLs belong to one video, not Lokal's unrelated
            // currently playing album recording. Audio stays authoritative;
            // changing offset seeks ONLY the muted visual track.
            audioPlayer.setMediaSource(audioSource)
            videoPlayer.setMediaSource(videoSource)
            audioPlayer.prepare()
            videoPlayer.prepare()
            audioPlayer.playWhenReady = true
            videoPlayer.playWhenReady = true
        } catch (e: Exception) {
            error = "This video has no compatible native stream"
        }
    }

    private fun syncVideoToAudio(force: Boolean = false) {
        if (disposed) return
        if (audioPlayer.playbackState == Player.STATE_IDLE ||
            videoPlayer.playbackState == Player.STATE_IDLE) return
        val target = (audioPlayer.currentPosition.coerceAtLeast(0) + offsetMs)
            .coerceAtLeast(0)
        // For negative offsets, keep the video at its opening frame until
        // the song clock catches up; never rewind the audio.
        val beforeVideoStart = audioPlayer.currentPosition + offsetMs < 0L
        if (beforeVideoStart || !audioPlayer.isPlaying) {
            videoPlayer.pause()
            if (beforeVideoStart && (force || videoPlayer.currentPosition > 150L)) {
                videoPlayer.seekTo(0L)
            }
            return
        }
        if (force ||
            (videoPlayer.playbackState == Player.STATE_READY &&
                kotlin.math.abs(videoPlayer.currentPosition - target) > 180L)) {
            videoPlayer.seekTo(target)
        }
        if (!videoPlayer.playWhenReady) videoPlayer.play()
    }

    private fun snapshot(): Map<String, Any?> = mapOf(
        "playing" to audioPlayer.isPlaying,
        "buffering" to (audioPlayer.playbackState == Player.STATE_BUFFERING),
        "ready" to (audioPlayer.playbackState == Player.STATE_READY),
        "positionMs" to audioPlayer.currentPosition.coerceAtLeast(0),
        "durationMs" to audioPlayer.duration.takeIf { it > 0 }?.coerceAtLeast(0),
        "offsetMs" to offsetMs,
        "error" to error,
    )

    override fun getView(): View = view

    override fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        view.keepScreenOn = false
        syncHandler.removeCallbacks(syncTask)
        view.player = null
        audioPlayer.stop()
        videoPlayer.stop()
        audioPlayer.release()
        videoPlayer.release()
    }

    companion object {
        fun isPlayableMediaUrl(value: String): Boolean {
            val uri = Uri.parse(value)
            val host = uri.host?.lowercase() ?: return false
            return uri.scheme == "https" &&
                (host == "googlevideo.com" || host.endsWith(".googlevideo.com"))
        }
    }
}
