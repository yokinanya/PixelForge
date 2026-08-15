package com.yokinanya.pixelforge

import android.graphics.Bitmap
import android.graphics.Rect
import kotlin.math.floor
import kotlin.math.max

internal object LinearBarcodeRegionDetector {
    fun detect(bitmap: Bitmap, scaleX: Float, scaleY: Float): List<Rect> {
        val rowSpans = buildRowSpans(bitmap)
        return buildClusters(rowSpans)
            .filter { it.isBarcode }
            .map { it.toRect(scaleX, scaleY, bitmap) }
    }

    private fun buildRowSpans(bitmap: Bitmap): List<RowSpan> {
        val result = mutableListOf<RowSpan>()
        val pixels = IntArray(bitmap.width)
        for (y in 0 until bitmap.height) {
            bitmap.getPixels(pixels, 0, bitmap.width, 0, y, bitmap.width, 1)
            result += rowSpans(pixels, y)
        }
        return result
    }

    private fun rowSpans(pixels: IntArray, y: Int): List<RowSpan> {
        val darkRuns = mutableListOf<IntRange>()
        var start = -1
        for (x in pixels.indices) {
            if (isDark(pixels[x])) {
                if (start < 0) start = x
            } else if (start >= 0) {
                darkRuns += start until x
                start = -1
            }
        }
        if (start >= 0) darkRuns += start until pixels.size
        return mergeRuns(y, darkRuns)
    }

    private fun mergeRuns(y: Int, runs: List<IntRange>): List<RowSpan> {
        if (runs.isEmpty()) return emptyList()
        val result = mutableListOf<RowSpan>()
        var first = runs.first().first
        var last = runs.first().last
        var count = 1
        var darkPixels = runs.first().count()
        for (run in runs.drop(1)) {
            val gap = run.first - last - 1
            if (gap <= MAX_WHITE_GAP) {
                last = run.last
                count++
                darkPixels += run.count()
                continue
            }
            addSpan(result, y, first, last, count, darkPixels)
            first = run.first
            last = run.last
            count = 1
            darkPixels = run.count()
        }
        addSpan(result, y, first, last, count, darkPixels)
        return result
    }

    private fun addSpan(
        output: MutableList<RowSpan>,
        y: Int,
        first: Int,
        last: Int,
        runs: Int,
        darkPixels: Int,
    ) {
        val width = last - first + 1
        val density = darkPixels.toFloat() / width
        if (runs < MIN_RUNS || width < MIN_WIDTH || density > MAX_DARK_DENSITY) return
        output += RowSpan(y, first, last, runs)
    }

    private fun buildClusters(rows: List<RowSpan>): List<Cluster> {
        val clusters = mutableListOf<Cluster>()
        for (row in rows) {
            val index = clusters.indexOfLast { cluster ->
                row.y - cluster.bottom <= MAX_ROW_GAP &&
                    horizontalOverlap(row, cluster) >= MIN_HORIZONTAL_OVERLAP
            }
            if (index < 0) {
                clusters += Cluster.from(row)
            } else {
                clusters[index] = clusters[index].add(row)
            }
        }
        return clusters
    }

    private fun horizontalOverlap(row: RowSpan, cluster: Cluster): Float {
        val overlap = max(0, minOf(row.right, cluster.right) - maxOf(row.left, cluster.left))
        return overlap.toFloat() / minOf(row.width, cluster.width)
    }

    private fun isDark(pixel: Int): Boolean {
        val red = (pixel shr 16) and 0xff
        val green = (pixel shr 8) and 0xff
        val blue = pixel and 0xff
        val luminance = (RED_WEIGHT * red + GREEN_WEIGHT * green + BLUE_WEIGHT * blue) /
            LUMINANCE_SCALE
        return luminance < DARK_PIXEL_THRESHOLD
    }

    private data class RowSpan(
        val y: Int,
        val left: Int,
        val right: Int,
        val runs: Int,
    ) {
        val width: Int get() = right - left + 1
    }

    private data class Cluster(
        val top: Int,
        val bottom: Int,
        val left: Int,
        val right: Int,
        val rows: Int,
        val runCount: Int,
    ) {
        val width: Int get() = right - left + 1
        val height: Int get() = bottom - top + 1
        val aspect: Float get() = width.toFloat() / height
        val averageRuns: Float get() = runCount.toFloat() / rows
        val isBarcode: Boolean
            get() = height >= MIN_HEIGHT &&
                rows >= height * MIN_ROW_COVERAGE &&
                averageRuns >= MIN_AVERAGE_RUNS &&
                aspect in MIN_ASPECT..MAX_ASPECT

        fun add(row: RowSpan): Cluster = copy(
            bottom = row.y,
            left = minOf(left, row.left),
            right = maxOf(right, row.right),
            rows = rows + 1,
            runCount = runCount + row.runs,
        )

        fun toRect(scaleX: Float, scaleY: Float, bitmap: Bitmap): Rect {
            val originalWidth = (bitmap.width * scaleX).toInt()
            val originalHeight = (bitmap.height * scaleY).toInt()
            return Rect(
            floor(left * scaleX).toInt().coerceAtLeast(0),
            floor(top * scaleY).toInt().coerceAtLeast(0),
            floor((right + 1) * scaleX).toInt().coerceAtMost(originalWidth),
            floor((bottom + 1 + TEXT_PADDING) * scaleY)
                .toInt()
                .coerceAtMost(originalHeight),
            )
        }

        companion object {
            fun from(row: RowSpan) = Cluster(
                top = row.y,
                bottom = row.y,
                left = row.left,
                right = row.right,
                rows = 1,
                runCount = row.runs,
            )
        }
    }

    private const val MAX_WHITE_GAP = 6
    private const val MIN_WIDTH = 40
    private const val MIN_RUNS = 10
    private const val MAX_DARK_DENSITY = 0.95f
    private const val MAX_ROW_GAP = 2
    private const val MIN_HORIZONTAL_OVERLAP = 0.45f
    private const val MIN_HEIGHT = 20
    private const val MIN_ROW_COVERAGE = 0.55f
    private const val MIN_AVERAGE_RUNS = 10
    private const val MIN_ASPECT = 2f
    private const val MAX_ASPECT = 14f
    private const val TEXT_PADDING = 24
    private const val DARK_PIXEL_THRESHOLD = 145
    private const val RED_WEIGHT = 299
    private const val GREEN_WEIGHT = 587
    private const val BLUE_WEIGHT = 114
    private const val LUMINANCE_SCALE = 1000
}
