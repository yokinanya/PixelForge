package com.yokinanya.pixelforge

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ComponentName
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.annotation.NonNull
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private lateinit var mediaChannel: MethodChannel
    private lateinit var redactionChannel: MethodChannel
    private lateinit var shareChannel: MethodChannel
    private lateinit var cacheChannel: MethodChannel
    private var redactionAnalyzer: RedactionAnalyzer? = null
    private lateinit var cacheDirectoryManager: CacheDirectoryManager
    private var pendingSaveRequest: SaveRequest? = null
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingShareResult: MethodChannel.Result? = null
    private val pendingSharedPaths = mutableListOf<String>()
    private var deliveringSharedImages = false

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        collectSharedPaths(intent)
        cacheDirectoryManager = CacheDirectoryManager(this)
        cacheDirectoryManager.clearOrphanedSharedImages(pendingSharedPaths.toSet())
        mediaChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        mediaChannel.setMethodCallHandler { call, result ->
            if (call.method == SAVE_IMAGE_METHOD) {
                handleSaveImage(call, result)
            } else if (call.method == SHARE_IMAGE_METHOD) {
                handleShareImage(call, result)
            } else {
                result.notImplemented()
            }
        }
        redactionChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            REDACTION_CHANNEL_NAME,
        )
        redactionChannel.setMethodCallHandler { call, result ->
            if (call.method != ANALYZE_IMAGE_METHOD) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>(IMAGE_PATH_KEY)
            if (path.isNullOrBlank()) {
                result.error("INVALID_ARGUMENT", "图片路径不能为空", null)
                return@setMethodCallHandler
            }
            try {
                getRedactionAnalyzer().analyze(path, result)
            } catch (error: Exception) {
                result.error("DETECTION_INIT_FAILED", error.message ?: "本地识别初始化失败", null)
            }
        }
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_CHANNEL_NAME,
        )
        shareChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                GET_PENDING_SHARED_IMAGES_METHOD -> {
                    result.success(ArrayList(pendingSharedPaths))
                    pendingSharedPaths.clear()
                }
                DELETE_SHARED_IMAGES_METHOD -> {
                    val paths = call.argument<List<*>>(PATHS_KEY)
                    if (paths == null || paths.any { it !is String }) {
                        result.error("INVALID_ARGUMENT", "分享文件路径参数无效", null)
                    } else {
                        try {
                            deleteSharedImages(paths.filterIsInstance<String>())
                            result.success(null)
                        } catch (error: Exception) {
                            result.error(
                                "DELETE_SHARED_IMAGES_FAILED",
                                error.message ?: "清理分享文件失败",
                                null,
                            )
                        }
                    }
                }
                SET_SHARE_TARGET_ENABLED_METHOD -> {
                    val enabled = call.argument<Boolean>(ENABLED_KEY)
                    if (enabled == null) {
                        result.error("INVALID_ARGUMENT", "分享设置参数无效", null)
                    } else {
                        setShareTargetEnabled(enabled)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        cacheChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CACHE_CHANNEL_NAME,
        )
        cacheChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                RUNTIME_CACHE_SIZE_METHOD -> result.success(cacheDirectoryManager.size())
                CLEAR_RUNTIME_CACHE_METHOD -> result.success(cacheDirectoryManager.clear())
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        collectSharedPaths(intent)
        Handler(Looper.getMainLooper()).post { deliverPendingSharedImages() }
    }

    override fun onPostResume() {
        super.onPostResume()
        deliverPendingSharedImages()
    }

    override fun onDestroy() {
        redactionAnalyzer?.close()
        super.onDestroy()
    }

    private fun getRedactionAnalyzer(): RedactionAnalyzer {
        return redactionAnalyzer ?: RedactionAnalyzer(this).also {
            redactionAnalyzer = it
        }
    }

    private fun handleShareImage(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>(SOURCE_PATH_KEY)
        val displayName = call.argument<String>(DISPLAY_NAME_KEY)
        val mimeType = call.argument<String>(MIME_TYPE_KEY)
        if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank() || mimeType.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "分享文件参数不完整", null)
            return
        }
        try {
            val source = File(sourcePath)
            if (!source.isFile) throw IllegalStateException("导出文件不存在")
            if (pendingShareResult != null) {
                result.error("SHARE_BUSY", "已有一个分享请求正在处理", null)
                return
            }
            val authority = applicationContext.packageName + ".fileprovider"
            val uri = FileProvider.getUriForFile(this, authority, source)
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_TITLE, displayName)
                clipData = ClipData.newRawUri("shared_image", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            pendingShareResult = result
            val chooser = Intent.createChooser(shareIntent, "分享图片").apply {
                putExtra(
                    Intent.EXTRA_EXCLUDE_COMPONENTS,
                    arrayOf(ComponentName(this@MainActivity, ShareReceiverActivity::class.java)),
                )
            }
            startActivityForResult(
                chooser,
                SHARE_REQUEST_CODE,
            )
        } catch (error: Exception) {
            pendingShareResult = null
            result.error("SHARE_FAILED", error.message ?: "打开分享面板失败", null)
        }
    }

    private fun collectSharedPaths(intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_MAIN) {
            val paths = intent?.getStringArrayListExtra(SHARED_PATHS_EXTRA).orEmpty()
            for (path in paths) {
                if (path.isNotBlank() && !pendingSharedPaths.contains(path)) {
                    pendingSharedPaths.add(path)
                }
            }
        }
    }

    private fun deliverPendingSharedImages() {
        if (!::shareChannel.isInitialized || deliveringSharedImages ||
            pendingSharedPaths.isEmpty()
        ) return
        val paths = pendingSharedPaths.toList()
        deliveringSharedImages = true
        shareChannel.invokeMethod(
            SHARED_IMAGES_METHOD,
            paths,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    pendingSharedPaths.removeAll(paths.toSet())
                    deliveringSharedImages = false
                }

                override fun error(code: String, message: String?, details: Any?) {
                    deliveringSharedImages = false
                }

                override fun notImplemented() {
                    deliveringSharedImages = false
                }
            },
        )
    }

    private fun setShareTargetEnabled(enabled: Boolean) {
        val state = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        packageManager.setComponentEnabledSetting(
            ComponentName(this, ShareReceiverActivity::class.java),
            state,
            PackageManager.DONT_KILL_APP,
        )
    }

    private fun deleteSharedImages(paths: List<String>) {
        val root = File(cacheDir, SHARED_IMAGES_DIRECTORY).canonicalFile
        val rootPath = root.path + File.separator
        for (path in paths) {
            val file = File(path).canonicalFile
            if (file.path != root.path && !file.path.startsWith(rootPath)) {
                throw IllegalArgumentException("分享文件路径不在应用缓存目录内")
            }
            if (file.exists() && !file.delete()) {
                throw IllegalStateException("无法删除分享临时文件: ${file.name}")
            }
            pendingSharedPaths.remove(path)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SHARE_REQUEST_CODE) return
        val result = pendingShareResult
        pendingShareResult = null
        result?.success(null)
    }

    private fun handleSaveImage(call: MethodCall, result: MethodChannel.Result) {
        val request = SaveRequest(
            sourcePath = call.argument<String>(SOURCE_PATH_KEY),
            displayName = call.argument<String>(DISPLAY_NAME_KEY),
            mimeType = call.argument<String>(MIME_TYPE_KEY),
            directory = call.argument<String>(DIRECTORY_KEY) ?: PICTURES_DIRECTORY,
        )
        if (request.sourcePath.isNullOrBlank() || request.displayName.isNullOrBlank() ||
            request.mimeType.isNullOrBlank()
        ) {
            result.error("INVALID_ARGUMENT", "公共目录导出参数不完整", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (pendingSaveResult != null) {
                result.error("SAVE_BUSY", "已有一个公共目录保存请求正在处理", null)
                return
            }
            pendingSaveRequest = request
            pendingSaveResult = result
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                WRITE_PERMISSION_REQUEST,
            )
            return
        }
        saveImage(request, result)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != WRITE_PERMISSION_REQUEST) return
        val request = pendingSaveRequest
        val result = pendingSaveResult
        pendingSaveRequest = null
        pendingSaveResult = null
        if (request == null || result == null) return
        if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
            result.error("PERMISSION_DENIED", "需要存储权限才能写入公共目录", null)
            return
        }
        saveImage(request, result)
    }

    private fun saveImage(request: SaveRequest, result: MethodChannel.Result) {
        try {
            val source = File(requireNotNull(request.sourcePath))
            if (!source.isFile) throw IllegalStateException("导出文件不存在")
            val savedPath = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveWithMediaStore(
                    source,
                    requireNotNull(request.displayName),
                    requireNotNull(request.mimeType),
                    requireNotNull(request.directory),
                )
            } else {
                saveWithLegacyStorage(
                    source,
                    requireNotNull(request.displayName),
                    requireNotNull(request.mimeType),
                    requireNotNull(request.directory),
                )
            }
            result.success(savedPath)
        } catch (error: Exception) {
            result.error("SAVE_FAILED", error.message ?: "写入公共目录失败", null)
        }
    }

    private fun saveWithMediaStore(
        source: File,
        displayName: String,
        mimeType: String,
        directory: String,
    ): String {
        val inDownloads = directory == DOWNLOADS_DIRECTORY
        val collection = if (inDownloads) {
            MediaStore.Downloads.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val relativeRoot = if (inDownloads) {
            Environment.DIRECTORY_DOWNLOADS
        } else {
            Environment.DIRECTORY_PICTURES
        }
        val relativePath = relativeRoot + "/" + ALBUM_NAME
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                relativePath,
            )
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val resolver = contentResolver
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("无法创建公共图片库条目")
        try {
            copyFile(source, resolver.openOutputStream(uri) ?: throw IllegalStateException("无法打开公共图片库"))
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
                null,
                null,
            )
            return relativePath + "/" + displayName
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    private fun saveWithLegacyStorage(
        source: File,
        displayName: String,
        mimeType: String,
        directory: String,
    ): String {
        val root = if (directory == DOWNLOADS_DIRECTORY) {
            Environment.DIRECTORY_DOWNLOADS
        } else {
            Environment.DIRECTORY_PICTURES
        }
        val targetDirectory = File(
            Environment.getExternalStoragePublicDirectory(root),
            ALBUM_NAME,
        )
        if (!targetDirectory.exists() && !targetDirectory.mkdirs()) {
            throw IllegalStateException("无法创建公共图片目录")
        }
        val target = File(targetDirectory, displayName)
        copyFile(source, target.outputStream())
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DATA, target.absolutePath)
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
        }
        contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("无法创建公共图片库条目")
        return target.absolutePath
    }

    private fun copyFile(source: File, output: java.io.OutputStream) {
        output.use { destination ->
            FileInputStream(source).use { input -> input.copyTo(destination) }
        }
    }

    private data class SaveRequest(
        val sourcePath: String?,
        val displayName: String?,
        val mimeType: String?,
        val directory: String?,
    )

    companion object {
        private const val CHANNEL_NAME = "stitch/public_media"
        private const val REDACTION_CHANNEL_NAME = "pixelforge/redaction"
        private const val SHARE_CHANNEL_NAME = "pixelforge/share"
        private const val CACHE_CHANNEL_NAME = "pixelforge/cache"
        private const val SHARED_IMAGES_METHOD = "sharedImages"
        private const val SHARED_IMAGES_DIRECTORY = "shared_images"
        private const val GET_PENDING_SHARED_IMAGES_METHOD = "getPendingSharedImages"
        private const val DELETE_SHARED_IMAGES_METHOD = "deleteSharedImages"
        private const val SET_SHARE_TARGET_ENABLED_METHOD = "setShareTargetEnabled"
        private const val RUNTIME_CACHE_SIZE_METHOD = "runtimeCacheSize"
        private const val CLEAR_RUNTIME_CACHE_METHOD = "clearRuntimeCache"
        private const val ENABLED_KEY = "enabled"
        const val SHARED_PATHS_EXTRA = "pixelforge.shared_paths"
        private const val ANALYZE_IMAGE_METHOD = "analyzeImage"
        private const val IMAGE_PATH_KEY = "imagePath"
        private const val SAVE_IMAGE_METHOD = "saveImage"
        private const val SHARE_IMAGE_METHOD = "shareImage"
        private const val SOURCE_PATH_KEY = "sourcePath"
        private const val DISPLAY_NAME_KEY = "displayName"
        private const val MIME_TYPE_KEY = "mimeType"
        private const val PATHS_KEY = "paths"
        private const val SHARE_REQUEST_CODE = 7201
        private const val DIRECTORY_KEY = "directory"
        private const val PICTURES_DIRECTORY = "pictures"
        private const val DOWNLOADS_DIRECTORY = "downloads"
        private const val ALBUM_NAME = "PixelForge"
        private const val WRITE_PERMISSION_REQUEST = 7101
    }
}
