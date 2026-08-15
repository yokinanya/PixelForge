/// 会话存储：导入图片保存在会话目录，预览文件保存在系统缓存目录。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixelforge/src/domain/models.dart';

const supportedImageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'};
const _imageHeaderBytes = 512 * 1024;

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

/// 从文件头解析图片尺寸。
ImageSize? parseImageSize(List<int> head) {
  if (_isPng(head)) {
    // PNG: bytes 16-23 为宽高（大端）。
    return ImageSize(
      (head[16] << 24) | (head[17] << 16) | (head[18] << 8) | head[19],
      (head[20] << 24) | (head[21] << 16) | (head[22] << 8) | head[23],
    );
  }
  final jpeg = _parseJpegSize(head);
  if (jpeg != null) return jpeg;
  final webp = _parseWebpSize(head);
  if (webp != null) return webp;
  final gif = _parseGifSize(head);
  if (gif != null) return gif;
  final bmp = _parseBmpSize(head);
  if (bmp != null) return bmp;
  return null;
}

bool _isPng(List<int> head) =>
    head.length >= 24 &&
    head[0] == 0x89 &&
    head[1] == 0x50 &&
    head[2] == 0x4E &&
    head[3] == 0x47 &&
    head[12] == 0x49 &&
    head[13] == 0x48 &&
    head[14] == 0x44 &&
    head[15] == 0x52;

ImageSize? _parseJpegSize(List<int> head) {
  if (head.length < 4 || head[0] != 0xFF || head[1] != 0xD8) return null;
  var index = 2;
  while (index + 3 < head.length) {
    if (head[index] != 0xFF) {
      index++;
      continue;
    }
    while (index < head.length && head[index] == 0xFF) {
      index++;
    }
    if (index >= head.length) return null;
    final marker = head[index++];
    if (marker == 0xD8 || marker == 0xD9 || marker == 0x01) continue;
    if (index + 1 >= head.length) return null;
    final length = (head[index] << 8) | head[index + 1];
    if (length < 2 || index + length > head.length) return null;
    if (_isJpegFrameMarker(marker) && length >= 7) {
      final height = (head[index + 3] << 8) | head[index + 4];
      final width = (head[index + 5] << 8) | head[index + 6];
      return ImageSize(width, height);
    }
    index += length;
  }
  return null;
}

bool _isJpegFrameMarker(int marker) =>
    marker >= 0xC0 && marker <= 0xC3 ||
    marker >= 0xC5 && marker <= 0xC7 ||
    marker >= 0xC9 && marker <= 0xCB ||
    marker >= 0xCD && marker <= 0xCF;

ImageSize? _parseWebpSize(List<int> head) {
  if (head.length < 16 ||
      head[0] != 0x52 ||
      head[1] != 0x49 ||
      head[2] != 0x46 ||
      head[3] != 0x46 ||
      head[8] != 0x57 ||
      head[9] != 0x45 ||
      head[10] != 0x42 ||
      head[11] != 0x50) {
    return null;
  }
  final chunk = String.fromCharCodes(head.sublist(12, 16));
  if (chunk == 'VP8X' && head.length >= 30) {
    final width = 1 + (head[24] | (head[25] << 8) | (head[26] << 16));
    final height = 1 + (head[27] | (head[28] << 8) | (head[29] << 16));
    return ImageSize(width, height);
  }
  if (chunk == 'VP8 ' && head.length >= 30) {
    return ImageSize(head[26] | (head[27] << 8), head[28] | (head[29] << 8));
  }
  if (chunk == 'VP8L' && head.length >= 25 && head[20] == 0x2F) {
    final width = 1 + (head[21] | ((head[22] & 0x3F) << 8));
    final height =
        1 + ((head[22] >> 6) | (head[23] << 2) | ((head[24] & 0x0F) << 10));
    return ImageSize(width, height);
  }
  return null;
}

/// Read and parse enough of an image to determine its dimensions.
Future<ImageSize> readImageSize(File file) async {
  if (!await file.exists()) {
    throw FileSystemException('图片文件不存在', file.path);
  }
  // JPEG 的 SOF 标记可能位于大段 EXIF/APP1 之后（可达数百 KB），
  // 因此读取 512KB 头部而非固定 64 字节。
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, _imageHeaderBytes)) {
    builder.add(chunk);
  }
  final size = parseImageSize(builder.takeBytes());
  if (size == null || size.width <= 0 || size.height <= 0) {
    throw FormatException('无法识别图片尺寸: ${file.path}');
  }
  return size;
}

ImageSize? _parseGifSize(List<int> head) {
  if (head.length < 10 ||
      String.fromCharCodes(head.sublist(0, 6)) != 'GIF87a' &&
          String.fromCharCodes(head.sublist(0, 6)) != 'GIF89a') {
    return null;
  }
  return ImageSize(head[6] | (head[7] << 8), head[8] | (head[9] << 8));
}

ImageSize? _parseBmpSize(List<int> head) {
  if (head.length < 26 || head[0] != 0x42 || head[1] != 0x4D) return null;
  final width = _signedLittleEndian(head, 18, 4).abs();
  final height = _signedLittleEndian(head, 22, 4).abs();
  return ImageSize(width, height);
}

int _signedLittleEndian(List<int> bytes, int offset, int length) {
  var value = 0;
  for (var i = 0; i < length; i++) {
    value |= bytes[offset + i] << (8 * i);
  }
  final signBit = 1 << (length * 8 - 1);
  return (value & signBit) == 0 ? value : value - (signBit << 1);
}
