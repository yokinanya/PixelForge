/// Temporary files for one-image redaction sessions.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/infrastructure/storage/temp_store.dart';

class RedactionStore {
  RedactionStore._(this._directory, this._exportDirectory);

  static RedactionStore? _instance;

  final Directory _directory;
  final Directory _exportDirectory;

  static RedactionStore withDirectory(Directory directory) =>
      RedactionStore._(directory, directory);

  static Future<RedactionStore> instance() async {
    if (_instance != null) return _instance!;
    final documents = await getApplicationDocumentsDirectory();
    final cache = await getApplicationCacheDirectory();
    final directory = Directory('${documents.path}/redaction_session');
    final exportDirectory = Directory('${cache.path}/redaction_exports');
    await Future.wait([
      directory.create(recursive: true),
      exportDirectory.create(recursive: true),
    ]);
    _instance = RedactionStore._(directory, exportDirectory);
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

  Future<int> cacheSize() async {
    if (!await _exportDirectory.exists()) return 0;
    var bytes = 0;
    for (final entity in _exportDirectory.listSync(followLinks: false)) {
      bytes += await _sizeOf(entity);
    }
    return bytes;
  }

  Future<int> clearCache() async {
    var bytes = 0;
    if (await _exportDirectory.exists()) {
      for (final entity in _exportDirectory.listSync(followLinks: false)) {
        bytes += await _sizeOf(entity);
        await entity.delete(recursive: true);
      }
    }
    await _exportDirectory.create(recursive: true);
    return bytes;
  }

  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
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

  Future<int> _sizeOf(FileSystemEntity entity) async {
    if (entity is File) return entity.length();
    if (entity is! Directory) return 0;
    var bytes = 0;
    for (final child in entity.listSync(followLinks: false)) {
      bytes += await _sizeOf(child);
    }
    return bytes;
  }
}
