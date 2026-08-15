package com.yokinanya.pixelforge

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import android.widget.Toast
import java.io.File

class ShareReceiverActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val paths = try {
            copySharedImages(intent)
        } catch (error: Exception) {
            Toast.makeText(this, errorMessage(error), Toast.LENGTH_LONG).show()
            arrayListOf()
        }
        if (paths.isNotEmpty()) {
            try {
                startActivity(
                    Intent(this, MainActivity::class.java).apply {
                        addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP,
                        )
                        putStringArrayListExtra(MainActivity.SHARED_PATHS_EXTRA, paths)
                    },
                )
            } catch (error: Exception) {
                deleteFiles(paths)
                Toast.makeText(this, errorMessage(error), Toast.LENGTH_LONG).show()
            }
        }
        finish()
    }

    private fun errorMessage(error: Exception): String {
        return if (error is java.io.FileNotFoundException) {
            "无法读取分享图片"
        } else {
            "接收分享图片失败"
        }
    }

    private fun copySharedImages(intent: Intent?): ArrayList<String> {
        if (intent == null) return arrayListOf()
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM),
            )
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            else -> emptyList()
        }
        val directory = File(cacheDir, SHARED_IMAGES_DIRECTORY)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("无法创建分享缓存目录")
        }
        val copied = arrayListOf<String>()
        return try {
            uris.forEachIndexed { index, uri ->
                copied.add(copyImage(uri, directory, index))
            }
            copied
        } catch (error: Exception) {
            deleteFiles(copied)
            throw error
        }
    }

    private fun copyImage(uri: Uri, directory: File, index: Int): String {
        val extension = extensionFor(uri)
        val target = File(
            directory,
            "share_${System.currentTimeMillis()}_${index}.${extension}",
        )
        contentResolver.openInputStream(uri).use { input ->
            if (input == null) throw IllegalStateException("无法读取分享图片")
            target.outputStream().use { output -> input.copyTo(output) }
        }
        return target.absolutePath
    }

    private fun extensionFor(uri: Uri): String {
        val displayName = queryDisplayName(uri)
        val fromName = displayName?.substringAfterLast('.', "")
        if (!fromName.isNullOrBlank()) {
            val sanitized = fromName.filter(Char::isLetterOrDigit).lowercase()
            if (sanitized.isNotBlank()) return sanitized.take(MAX_EXTENSION_LENGTH)
        }
        val mimeType = contentResolver.getType(uri)
        return MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType) ?: DEFAULT_EXTENSION
    }

    private fun queryDisplayName(uri: Uri): String? {
        val cursor: Cursor = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        ) ?: return null
        return cursor.use {
            if (!it.moveToFirst()) return@use null
            it.getString(it.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))
        }
    }

    private fun deleteFiles(paths: Iterable<String>) {
        for (path in paths) {
            val file = File(path)
            if (file.exists() && !file.delete()) {
                throw IllegalStateException("无法删除分享临时文件: ${file.name}")
            }
        }
    }

    companion object {
        private const val SHARED_IMAGES_DIRECTORY = "shared_images"
        private const val DEFAULT_EXTENSION = "png"
        private const val MAX_EXTENSION_LENGTH = 8
    }
}
