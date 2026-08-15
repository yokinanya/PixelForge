package com.yokinanya.pixelforge

import android.graphics.BitmapFactory
import android.graphics.Rect

internal object BarcodeRegionDetector {
    fun detect(path: String, width: Int, height: Int): List<Rect> {
        val bitmap = decode(path, width, height) ?: return emptyList()
        return try {
            LinearBarcodeRegionDetector.detect(
                bitmap,
                width.toFloat() / bitmap.width,
                height.toFloat() / bitmap.height,
            )
        } finally {
            bitmap.recycle()
        }
    }

    fun merge(existing: List<Rect>, refined: List<Rect>): List<Rect> {
        val merged = existing.toMutableList()
        for (region in refined) {
            val index = merged.indexOfFirst { current ->
                overlaps(current, region) && region.height() > current.height() * REFINE_HEIGHT_FACTOR
            }
            if (index >= 0) {
                merged[index] = region
            } else if (merged.none { overlaps(it, region) }) {
                merged += region
            }
        }
        return merged
    }

    private fun decode(path: String, width: Int, height: Int) =
        BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply {
                inSampleSize = sampleSize(width, height)
            },
        )

    private fun sampleSize(width: Int, height: Int): Int {
        var sample = 1
        while (maxOf(width / sample, height / sample) > MAX_SCAN_DIMENSION) sample *= 2
        return sample
    }

    private fun overlaps(first: Rect, second: Rect): Boolean =
        first.left < second.right && second.left < first.right &&
            first.top < second.bottom && second.top < first.bottom

    private const val MAX_SCAN_DIMENSION = 1800
    private const val REFINE_HEIGHT_FACTOR = 1.4f
}
