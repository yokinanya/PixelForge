package com.yokinanya.pixelforge

import android.content.Context
import java.io.File

class CacheDirectoryManager(context: Context) {
    private val applicationCacheDir = context.cacheDir
    private val directories = listOf(applicationCacheDir, context.codeCacheDir) +
        context.externalCacheDirs.toList()
    private val recreatedCacheDirectories = listOf(
        "stitch_preview",
        "redaction_exports",
        "watermark_exports",
        "shared_images",
    )

    fun size(): Long = directories.sumOf(::sizeOf)

    fun clear(): Long {
        val bytes = size()
        for (directory in directories) clearChildren(directory)
        for (name in recreatedCacheDirectories) {
            File(applicationCacheDir, name).mkdirs()
        }
        return bytes
    }

    fun clearOrphanedSharedImages(keepPaths: Set<String>) {
        val directory = File(applicationCacheDir, SHARED_IMAGES_DIRECTORY)
        if (!directory.isDirectory) return
        val keep = keepPaths.map { File(it).canonicalFile.path }.toSet()
        for (file in directory.listFiles().orEmpty()) {
            if (file.canonicalFile.path in keep) continue
            if (!file.deleteRecursively()) {
                throw IllegalStateException("无法清理分享临时文件: ${file.name}")
            }
        }
    }

    private fun clearChildren(directory: File) {
        for (child in directory.listFiles().orEmpty()) {
            if (!child.deleteRecursively()) {
                throw IllegalStateException("无法清理缓存文件: ${child.name}")
            }
        }
    }

    private fun sizeOf(file: File): Long {
        if (file.isFile) return file.length()
        return file.listFiles().orEmpty().sumOf(::sizeOf)
    }

    companion object {
        private const val SHARED_IMAGES_DIRECTORY = "shared_images"
    }
}
