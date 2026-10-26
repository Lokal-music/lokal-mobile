package com.mossapps.flick.youtube

import android.content.Context
import android.net.Uri
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
import androidx.media3.exoplayer.source.MergingMediaSource
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
    private val player = ExoPlayer.Builder(context).build().apply {
        setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true, // Own Android audio focus while native video is playing.
        )
        setHandleAudioBecomingNoisy(true)
    }
    private val view = (LayoutInflater.from(context).inflate(
        R.layout.lokal_music_video_player, null
    ) as PlayerView).apply {
        useController = false
        setShutterBackgroundColor(android.graphics.Color.BLACK)
        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        // Layout XML supplies a TextureView so Flutter chrome can overlay it.
        this.player = this@LokalMusicVideoView.player
        keepScreenOn = true
    }
    private val channel = MethodChannel(messenger, "lokal/media3_video/$viewId")
    private var error: String? = null
    private var disposed = false

    init {
        player.addListener(object : Player.Listener {
            override fun onPlayerError(exception: PlaybackException) {
                error = "Video couldn't play in Media3"
            }
        })
        channel.setMethodCallHandler { call, result ->
            if (disposed) {
                result.error("DISPOSED", "Video view closed", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "snapshot" -> result.success(snapshot())
                "play" -> { player.play(); result.success(snapshot()) }
                "pause" -> { player.pause(); result.success(snapshot()) }
                "seek" -> {
                    val value = (call.argument<Number>("positionMs")?.toLong() ?: 0L)
                    player.seekTo(value.coerceAtLeast(0L)); result.success(snapshot())
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
            // Audio is first (as in Prism): Media3 aligns two tracks
            // belonging to this *same video*, with one playback clock.
            player.setMediaSource(MergingMediaSource(true, false, audioSource, videoSource))
            player.prepare()
            player.playWhenReady = true
        } catch (e: Exception) {
            error = "This video has no compatible native stream"
        }
    }

    private fun snapshot(): Map<String, Any?> = mapOf(
        "playing" to player.isPlaying,
        "buffering" to (player.playbackState == Player.STATE_BUFFERING),
        "ready" to (player.playbackState == Player.STATE_READY),
        "positionMs" to player.currentPosition.coerceAtLeast(0),
        "durationMs" to player.duration.takeIf { it > 0 }?.coerceAtLeast(0),
        "error" to error,
    )

    override fun getView(): View = view

    override fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        view.keepScreenOn = false
        view.player = null
        player.stop()
        player.release()
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
