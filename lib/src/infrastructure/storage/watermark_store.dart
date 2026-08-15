/// 临时保存隐私保护水印会话与导出文件。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/infrastructure/storage/temp_store.dart';

class WatermarkStore {
  WatermarkStore._(this._directory, this._exportDirectory);

  static WatermarkStore? _instance;

  final Directory _directory;
  final Directory _exportDirectory;

  static WatermarkStore withDirectory(Directory directory) =>
      WatermarkStore._(directory, directory);

  static Future<WatermarkStore> instance() async {
    if (_instance != null) return _instance!;
    final documents = await getApplicationDocumentsDirectory();
    final cache = await getApplicationCacheDirectory();
    final directory = Directory('${documents.path}/watermark_session');
    final exportDirectory = Directory('${cache.path}/watermark_exports');
    await Future.wait([
      directory.create(recursive: true),
      exportDirectory.create(recursive: true),
    ]);
    _instance = WatermarkStore._(directory, exportDirectory);
    return _instance!;
  }

  Future<String> importFile(String sourcePath) async {
    final safeExt = imageExtensionForPath(sourcePath);
    final destination =
        '${_directory.path}/image_${DateTime.now().microsecondsSinceEpoch}.$safeExt';
    return (await File(sourcePath).copy(destination)).path;
  }

  Future<ImageSize> readSize(String path) async {
    return readImageSize(File(path));
  }

  String exportPath(String fileName) => '${_exportDirectory.path}/$fileName';

  Future<void> ensureExportDirectory() =>
      _exportDirectory.create(recursive: true);

  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<int> cacheSize() => _directorySize(_exportDirectory);

  Future<int> clearCache() async {
    final bytes = await _directorySize(_exportDirectory);
    await _clearDirectory(_exportDirectory);
    await _exportDirectory.create(recursive: true);
    return bytes;
  }

  Future<void> clear() async {
    await _clearDirectory(_directory);
    await _directory.create(recursive: true);
    await _clearDirectory(_exportDirectory);
    await _exportDirectory.create(recursive: true);
  }

  Future<void> _clearDirectory(Directory directory) async {
    if (!directory.existsSync()) return;
    for (final entity in directory.listSync(followLinks: false)) {
      await entity.delete(recursive: entity is Directory);
    }
  }

  Future<int> _directorySize(Directory directory) async {
    if (!await directory.exists()) return 0;
    var bytes = 0;
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is File) {
        bytes += await entity.length();
      } else if (entity is Directory) {
        bytes += await _directorySize(entity);
      }
    }
    return bytes;
  }
}
