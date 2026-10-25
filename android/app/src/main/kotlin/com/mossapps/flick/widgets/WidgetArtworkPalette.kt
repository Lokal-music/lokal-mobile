package com.mossapps.flick.widgets

import android.graphics.Bitmap
import android.graphics.Color
import com.mossapps.flick.R

/**
 * Apple Music-inspired album-tinted surfaces, built from a few pixels of the
 * actual sleeve. Using dark, pre-defined rounded drawables rather than a giant
 * transferred artwork bitmap keeps launcher Binder updates lightweight and
 * guarantees white metadata stays readable.
 */
internal object WidgetArtworkPalette {
    fun background(artwork: Bitmap?): Int {
        if (artwork == null || artwork.width <= 0 || artwork.height <= 0) {
            return R.drawable.widget_bg_3
        }
        val votes = FloatArray(5)
        val hsv = FloatArray(3)
        for (row in 0 until 5) {
            for (col in 0 until 5) {
                val x = ((col + 0.5f) * artwork.width / 5).toInt()
                    .coerceIn(0, artwork.width - 1)
                val y = ((row + 0.5f) * artwork.height / 5).toInt()
                    .coerceIn(0, artwork.height - 1)
                Color.colorToHSV(artwork.getPixel(x, y), hsv)
                val saturation = hsv[1]
                val brightness = hsv[2]
                if (saturation < 0.18f || brightness < 0.13f) continue
                val hue = hsv[0]
                val group = when {
                    hue < 35f || hue >= 340f -> 0 // rose/red
                    hue < 75f -> 1 // amber
                    hue < 175f -> 2 // green
                    hue < 260f -> 3 // blue
                    else -> 4 // purple
                }
                votes[group] += saturation * brightness
            }
        }
        val winner = votes.indices.maxByOrNull { votes[it] } ?: return R.drawable.widget_bg_3
        if (votes[winner] < 0.5f) return R.drawable.widget_bg_3
        return when (winner) {
            0 -> R.drawable.widget_surface_rose
            1 -> R.drawable.widget_surface_gold
            2 -> R.drawable.widget_surface_green
            3 -> R.drawable.widget_surface_blue
            else -> R.drawable.widget_surface_violet
        }
    }
}
