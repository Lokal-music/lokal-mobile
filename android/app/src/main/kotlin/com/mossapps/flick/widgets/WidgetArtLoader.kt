package com.mossapps.flick.widgets

import android.content.Context
import android.net.Uri
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File

/**
 * RemoteViews sends bitmaps to the home launcher over Binder. Avoid 1024px
 * album art: even a single such image can exceed the widget transaction
 * budget once multiple widgets or text bitmaps are present.
 */
internal object WidgetArtLoader {
    private const val MAX_ART_EDGE = 288

    fun load(path: String?, maxPx: Int = MAX_ART_EDGE): Bitmap? =
        loadInternal(null, path, maxPx)

    /** MediaStore's content:// artwork is not a File path. Decode it through
     * ContentResolver instead of treating it as a missing cover. */
    fun load(context: Context, path: String?, maxPx: Int = MAX_ART_EDGE): Bitmap? =
        loadInternal(context, path, maxPx)

    private fun loadInternal(context: Context?, path: String?, maxPx: Int): Bitmap? {
        if (path.isNullOrBlank()) return null
        val content = path.startsWith("content://")
        if (!content && path.contains("://")) return null
        val file = if (content) null else File(path)
        if (file != null && (!file.isFile || !file.canRead())) return null
        if (content && context == null) return null
        val edge = maxPx.coerceIn(64, MAX_ART_EDGE)
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            if (content) {
                context!!.contentResolver.openInputStream(Uri.parse(path))?.use {
                    BitmapFactory.decodeStream(it, null, bounds)
                }
            } else BitmapFactory.decodeFile(file!!.absolutePath, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val options = BitmapFactory.Options().apply {
                inSampleSize = calculateSampleSize(bounds.outWidth, bounds.outHeight, edge)
                inPreferredConfig = Bitmap.Config.RGB_565
            }
            val sampled = if (content) {
                context!!.contentResolver.openInputStream(Uri.parse(path))?.use {
                    BitmapFactory.decodeStream(it, null, options)
                }
            } else BitmapFactory.decodeFile(file!!.absolutePath, options)
            if (sampled == null) return null
            if (sampled.width <= edge && sampled.height <= edge) sampled
            else {
                val scale = minOf(edge.toFloat() / sampled.width, edge.toFloat() / sampled.height)
                val resized = Bitmap.createScaledBitmap(
                    sampled,
                    (sampled.width * scale).toInt().coerceAtLeast(1),
                    (sampled.height * scale).toInt().coerceAtLeast(1),
                    true,
                )
                if (resized !== sampled) sampled.recycle()
                resized
            }
        } catch (_: Exception) {
            null
        } catch (_: OutOfMemoryError) {
            null
        }
    }

    private fun calculateSampleSize(w: Int, h: Int, maxPx: Int): Int {
        var sample = 1
        while (w / sample > maxPx * 2 || h / sample > maxPx * 2) sample *= 2
        return sample
    }
}
