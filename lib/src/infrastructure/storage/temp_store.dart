/// 会话存储：导入图片保存在会话目录，预览文件保存在系统缓存目录。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixelforge/src/domain/models.dart';

import 'image_size_parser.dart';

export 'image_size_parser.dart' show parseImageSize, readImageSize;

const supportedImageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'};

String imageExtensionForPath(String sourcePath) {
  final extension = sourcePath.split('.').last.toLowerCase();
  if (!supportedImageExtensions.contains(extension)) {
    throw FormatException('不支持的图片格式: .$extension');
  }
  return extension;
}

/// 管理会话中的临时文件。
class TempStore {
  TempStore._(this._dir, this._previewDir);

  final Directory _dir;
  final Directory _previewDir;
  static TempStore? _instance;

  static Future<TempStore> instance() async {
    if (_instance != null) return _instance!;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/stitch_session');
    final cache = await getApplicationCacheDirectory();
    final previewDir = Directory('${cache.path}/stitch_preview');
    await Future.wait([
      dir.create(recursive: true),
      previewDir.create(recursive: true),
    ]);
    await _removeLegacyPreviews(dir);
    _instance = TempStore._(dir, previewDir);
    return _instance!;
  }

  /// 使用自定义目录（测试注入用）。
  @visibleForTesting
  static TempStore withDirectory(Directory dir) =>
      TempStore._(dir, Directory('${dir.path}/stitch_preview'));

  /// 把外部文件复制进会话目录（附带序号）。
  Future<String> importFile(String sourcePath, int index) async {
    final safeExt = imageExtensionForPath(sourcePath);
    final dest =
        '${_dir.path}/img_${index}_${DateTime.now().microsecondsSinceEpoch}.$safeExt';
    await File(sourcePath).copy(dest);
    return dest;
  }

  /// 生成一次预览合成的临时输出路径。
  String previewPath(int version) => '${_previewDir.path}/preview_$version.png';

  /// 删除单个会话临时文件。
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// 清理历史预览文件，可保留当前正在使用的预览。
  Future<int> clearPreviewCache({String? keepPath}) async {
    var removedBytes = 0;
    if (!await _previewDir.exists()) {
      await _previewDir.create(recursive: true);
      return removedBytes;
    }
    final normalizedKeepPath = keepPath == null
        ? null
        : _normalizePath(keepPath);
    final files = _previewDir.listSync(followLinks: false).whereType<File>();
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      if (!name.startsWith('preview_') ||
          _normalizePath(file.path) == normalizedKeepPath) {
        continue;
      }
      removedBytes += await file.length();
      await file.delete();
    }
    return removedBytes;
  }

  String _normalizePath(String path) {
    final absolute = File(path).absolute.path.replaceAll('\\', '/');
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  /// 清理 Stitch 自己拥有的预览缓存。
  Future<int> clearCache() async {
    var removedBytes = 0;
    if (!await _previewDir.exists()) {
      await _previewDir.create(recursive: true);
      return removedBytes;
    }
    for (final entity in _previewDir.listSync(followLinks: false)) {
      removedBytes += await _sizeOf(entity);
      await entity.delete(recursive: true);
    }
    await _previewDir.create(recursive: true);
    return removedBytes;
  }

  /// 统计 Stitch 预览缓存大小。
  Future<int> cacheSize() => _directorySize(_previewDir);

  /// 读取图片尺寸（头部解析，不解码整图）。
  Future<ImageSize> readSize(String path) async {
    return readImageSize(File(path));
  }

  /// 清空会话目录。
  Future<void> clear() async {
    await _clearDirectory(_dir);
    await _dir.create(recursive: true);
    if (_previewDir.path == _dir.path) return;
    await _clearDirectory(_previewDir);
    await _previewDir.create(recursive: true);
  }

  Future<void> _clearDirectory(Directory directory) async {
    final files = directory.listSync(followLinks: false);
    for (final f in files) {
      await f.delete(recursive: f is Directory);
    }
  }

  Future<int> _sizeOf(FileSystemEntity entity) async {
    if (entity is File) return entity.length();
    if (entity is! Directory) return 0;
    var bytes = 0;
    for (final child in entity.listSync(followLinks: false)) {
      bytes += await _sizeOf(child);
    }
    return bytes;
  }

  Future<int> _directorySize(Directory directory) async {
    if (!await directory.exists()) return 0;
    var bytes = 0;
    for (final entity in directory.listSync(followLinks: false)) {
      bytes += await _sizeOf(entity);
    }
    return bytes;
  }

  static Future<void> _removeLegacyPreviews(Directory directory) async {
    final files = directory.listSync(followLinks: false).whereType<File>();
    for (final file in files) {
      if (file.uri.pathSegments.last.startsWith('preview_')) {
        await file.delete();
      }
    }
  }

  /// 当前会话文件列表。
  List<String> list() => _dir
      .listSync(followLinks: false)
      .whereType<File>()
      .map((f) => f.path)
      .toList();
}
