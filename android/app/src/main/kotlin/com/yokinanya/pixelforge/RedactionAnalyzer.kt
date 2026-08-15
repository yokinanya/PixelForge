package com.yokinanya.pixelforge

import android.content.Context
import android.graphics.Rect
import android.net.Uri
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import android.os.Handler
import android.os.Looper

class RedactionAnalyzer(private val context: Context) {
    private val refinementExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val chineseRecognizer: TextRecognizer = TextRecognition.getClient(
        ChineseTextRecognizerOptions.Builder().build(),
    )
    private val latinRecognizer: TextRecognizer = TextRecognition.getClient(
        TextRecognizerOptions.DEFAULT_OPTIONS,
    )
    private val barcodeScanner: BarcodeScanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder().build(),
    )
    private val faceDetector = lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                .build(),
        )
    }

    fun analyze(path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.isFile) {
            result.error("INVALID_IMAGE", "图片文件不存在", null)
            return
        }
        val image = try {
            InputImage.fromFilePath(context, Uri.fromFile(file))
        } catch (error: Exception) {
            result.error("IMAGE_READ_FAILED", error.message ?: "无法读取图片", null)
            return
        }
        val tasks = mutableListOf<Task<*>>(
            chineseRecognizer.process(image),
            latinRecognizer.process(image),
            barcodeScanner.process(image),
        )
        val faceTask = faceDetector.value.process(image)
        tasks += faceTask
        Tasks.whenAllComplete(tasks)
            .addOnSuccessListener(refinementExecutor) { completed ->
                val failure = completed.firstOrNull { !it.isSuccessful }?.exception
                if (failure != null) {
                    postError(result, "DETECTION_FAILED", failure.message ?: "本地识别失败")
                    return@addOnSuccessListener
                }
                try {
                    val chinese = completed[0].result as Text
                    val latin = completed[1].result as Text
                    val barcodes = completed[2].result as List<*>
                    val faces = completed[3].result as? List<*> ?: emptyList<Any>()
                    postSuccess(
                        result,
                        mapOf(
                            "width" to image.width,
                            "height" to image.height,
                            "detections" to buildDetections(
                                listOf(
                                    RecognizedText("chinese", chinese),
                                    RecognizedText("latin", latin),
                                ),
                                barcodes,
                                faces,
                                path,
                                image.width,
                                image.height,
                            ),
                        ),
                    )
                } catch (error: Exception) {
                    postError(
                        result,
                        "DETECTION_PARSE_FAILED",
                        error.message ?: "识别结果解析失败",
                    )
                }
            }
            .addOnFailureListener(refinementExecutor) { error ->
                postError(result, "DETECTION_FAILED", error.message ?: "本地识别失败")
            }
    }

    fun close() {
        chineseRecognizer.close()
        latinRecognizer.close()
        barcodeScanner.close()
        if (faceDetector.isInitialized()) faceDetector.value.close()
        refinementExecutor.shutdownNow()
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun buildDetections(
        textResults: List<RecognizedText>,
        barcodes: List<*>,
        faces: List<*>,
        sourcePath: String,
        imageWidth: Int,
        imageHeight: Int,
    ): List<Map<String, Any?>> {
        val detections = mutableListOf<Map<String, Any?>>()
        for (recognized in textResults) {
            for (block in recognized.text.textBlocks) {
                for (line in block.lines) {
                    val bounds = line.boundingBox ?: continue
                    detections += detection(
                        "textLine",
                        bounds,
                        line.text,
                        line.confidence.toDouble(),
                        recognized.name,
                        line.elements.mapNotNull { element ->
                            val elementBounds = element.boundingBox ?: return@mapNotNull null
                            mapOf(
                                "text" to element.text,
                                "rect" to rect(elementBounds),
                                "symbols" to element.symbols.mapNotNull { symbol ->
                                    val symbolBounds = symbol.boundingBox
                                        ?: return@mapNotNull null
                                    mapOf(
                                        "text" to symbol.text,
                                        "rect" to rect(symbolBounds),
                                    )
                                },
                            )
                        },
                    )
                }
            }
        }
        for (item in barcodes) {
            val barcode = item as Barcode
            if (barcode.format == Barcode.FORMAT_QR_CODE) {
                val bounds = barcode.boundingBox ?: continue
                detections += detection("qrCode", bounds, null, 0.98)
            }
        }
       val existingBarcodeRects = barcodes.mapNotNull { item ->
           val barcode = item as Barcode
            val bounds = barcode.boundingBox
            if (barcode.format == Barcode.FORMAT_QR_CODE || bounds == null) {
                null
            } else if (bounds.left >= 0 && bounds.top >= 0 &&
                bounds.right <= imageWidth && bounds.bottom <= imageHeight
            ) {
                bounds
            } else {
                null
            }
       }
        val refinedBarcodeRects = BarcodeRegionDetector.detect(
            path = sourcePath,
            width = imageWidth,
            height = imageHeight,
        )
        for (bounds in BarcodeRegionDetector.merge(existingBarcodeRects, refinedBarcodeRects)) {
            detections += detection("barcode", bounds, null, 0.97)
        }
        for (item in faces) {
            val bounds = (item as com.google.mlkit.vision.face.Face).boundingBox
            detections += detection("face", bounds, null, 0.98)
        }
        return detections
    }

    private fun detection(
        kind: String,
        bounds: Rect,
        text: String?,
        confidence: Double,
        recognizer: String? = null,
        fragments: List<Map<String, Any?>> = emptyList(),
    ): Map<String, Any?> = mapOf(
        "kind" to kind,
        "text" to text,
        "confidence" to confidence,
        "recognizer" to recognizer,
        "rect" to rect(bounds),
        "fragments" to fragments,
    )

    private fun rect(bounds: Rect): Map<String, Int> = mapOf(
        "x" to bounds.left,
        "y" to bounds.top,
        "w" to bounds.width(),
        "h" to bounds.height(),
    )

    private data class RecognizedText(
        val name: String,
        val text: Text,
    )

}
