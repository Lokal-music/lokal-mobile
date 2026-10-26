package com.mossapps.flick.youtube

import android.content.Context
import android.webkit.CookieManager
import com.mossapps.flick.youtube.potoken.PoTokenGenerator
import com.mossapps.flick.youtube.potoken.PoTokenWebView
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Android entry point for BitChord's InnerTubeX + BotGuard PoToken stream path.
 * Extraction and media preflight share the same client-bound identity.
 * Android playback does not walk stale hardcoded Dart clients first.
 */
internal object YoutubeNativeResolver {
    fun onStreamRefused(url: String) {
        InnerTubeXResolver.onRefused(url)
    }
    private val resolveMutex = Mutex()

    @Volatile
    private var initialized = false

    @Synchronized
    fun initialize(context: Context) {
        if (initialized) return
        val app = context.applicationContext
        val preferences = app.getSharedPreferences("innertubex_player_config", Context.MODE_PRIVATE)
        val tokenProvider = PoTokenGenerator(
            createMinter = { PoTokenWebView.getNewPoTokenGenerator(app) },
            available = { runCatching { CookieManager.getInstance() }.isSuccess },
        )
        InnerTubeXResolver.init(
            filesDir = app.filesDir,
            store = object : InnerTubeXResolver.ConfigStore {
                override fun getString(key: String): String? = preferences.getString(key, null)
                override fun getLong(key: String): Long? =
                    if (preferences.contains(key)) preferences.getLong(key, 0L) else null
                override fun putString(key: String, value: String) =
                    preferences.edit().putString(key, value).apply()
                override fun putLong(key: String, value: Long) =
                    preferences.edit().putLong(key, value).apply()
            },
            poTokenProvider = tokenProvider.asTokenProvider(),
        )
        initialized = true
    }

    /** Returns both Media3 playback legs without exposing cookies to the
     * video view. The same extraction session and mutex serve audio/video.
     */
    suspend fun resolveVideo(
        videoId: String,
        cookie: String?,
        visitorData: String?,
    ): Map<String, Any?> = withTimeout(45_000L) {
        resolveMutex.withLock {
            check(initialized) { "YouTube resolver is not initialized." }
            if (Innertube.updateSession(cookie, visitorData)) {
                InnerTubeXResolver.onSessionChanged()
            }
            val resolved = InnerTubeXResolver.resolvePlayableVideo(videoId)
            val video = requireNotNull(resolved.videoUrl)
            mapOf(
                "audioUrl" to resolved.url,
                "videoUrl" to video,
                "audioMime" to resolved.mimeType.substringBefore(';'),
                "videoMime" to resolved.videoMimeType,
                "height" to resolved.videoHeight,
                "headers" to resolved.headers,
            )
        }
    }

    suspend fun resolveStream(
        videoId: String,
        cookie: String?,
        visitorData: String?,
    ): Map<String, Any?> = withTimeout(45_000L) {
        resolveMutex.withLock {
            check(initialized) { "YouTube resolver is not initialized." }
            if (Innertube.updateSession(cookie, visitorData)) {
                InnerTubeXResolver.onSessionChanged()
            }
            val stream = try {
                InnerTubeXResolver.resolvePlayable(videoId, maxAttempts = 3)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A stale browser session must not make public music unplayable.
                // This changes only the extraction session, not the saved account.
                if (cookie.isNullOrBlank()) throw e
                Innertube.updateSession(null, null)
                InnerTubeXResolver.onSessionChanged()
                InnerTubeXResolver.resolvePlayable(videoId, maxAttempts = 3)
            }
            val length = stream.url.toHttpUrlOrNull()
                ?.queryParameter("clen")
                ?.toLongOrNull()
            mapOf(
                "url" to stream.url,
                "length" to length,
                "mime" to stream.mimeType,
                "bitrate" to stream.kbps.takeIf { it > 0 }?.times(1000),
                "headers" to stream.headers,
            )
        }
    }
}
