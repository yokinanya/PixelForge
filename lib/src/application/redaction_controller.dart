import 'package:flutter/foundation.dart';
import 'package:pixelforge/src/application/redaction_classifier.dart';
import 'package:pixelforge/src/application/redaction_exporter.dart';
import 'package:pixelforge/src/application/redaction_history.dart';
import 'package:pixelforge/src/application/redaction_models.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/infrastructure/ffi/rust_bridge.dart';
import 'package:pixelforge/src/infrastructure/redaction/redaction_detector.dart';
import 'package:pixelforge/src/infrastructure/storage/redaction_store.dart';

class RedactionController extends ChangeNotifier {
  RedactionController({
    required this.store,
    RedactionDetector? detector,
    RustBridge? bridge,
    SensitiveTextClassifier? classifier,
  }) : _detector = detector ?? const MethodChannelRedactionDetector(),
       _bridge = bridge ?? RustBridge.instance(),
       _classifier = classifier ?? SensitiveTextClassifier();

  final RedactionStore store;
  final RedactionDetector _detector;
  final RustBridge? _bridge;
  final SensitiveTextClassifier _classifier;

  RedactionStage _stage = RedactionStage.empty;
  String? _imagePath;
  ImageSize? _imageSize;
  List<DetectionCandidate> _candidates = const [];
  List<MaskRegion> _masks = const [];
  var _maskSettings = MaskStyleSettings.defaultSettings;
  List<RedactionSnapshot> _history = const [];
  var _historyIndex = -1;
  var _analyzing = false;
  var _exporting = false;
  Future<void>? _exportRun;
  Future<int>? _cacheRun;
  var _operationToken = 0;
  String? _error;

  RedactionStage get stage => _stage;
  String? get imagePath => _imagePath;
  ImageSize? get imageSize => _imageSize;
  List<DetectionCandidate> get candidates => List.unmodifiable(_candidates);
  List<MaskRegion> get masks => List.unmodifiable(_masks);
  MaskStyle get maskStyle => _maskSettings.style;
  MaskColorMode get maskColorMode => _maskSettings.colorMode;
  int get maskColor => _maskSettings.color;
  double get maskPadding => _maskSettings.padding;
  bool get analyzing => _analyzing;
  bool get exporting => _exporting;
  bool get canUndo => _historyIndex > 0;
  bool get canRedo => _historyIndex >= 0 && _historyIndex < _history.length - 1;
  String? get error => _error;

  Future<void> importImage(String sourcePath) async {
    final operationToken = ++_operationToken;
    _analyzing = false;
    final exportRun = _exportRun;
    if (exportRun != null) await exportRun;
    if (operationToken != _operationToken) return;
    final previousPath = _takeCurrentImage();
    String? importedPath;
    try {
      if (previousPath != null) await store.deleteFile(previousPath);
      if (operationToken != _operationToken) return;
      _error = null;
      importedPath = await store.importFile(sourcePath);
      final size = await store.readSize(importedPath);
      if (operationToken != _operationToken) {
        return;
      }
      if (size.width <= 0 || size.height <= 0) {
        throw const FormatException('无法读取图片尺寸');
      }
      _imagePath = importedPath;
      importedPath = null;
      _imageSize = size;
      _candidates = const [];
      _masks = const [];
      _maskSettings = MaskStyleSettings.defaultSettings;
      _stage = RedactionStage.previewing;
      _resetHistory();
      notifyListeners();
      await Future<void>.delayed(Duration.zero);
      await analyze();
    } catch (error) {
      if (operationToken != _operationToken) return;
      _stage = _imagePath == null
          ? RedactionStage.empty
          : RedactionStage.previewing;
      _error = '导入或识别失败：$error';
      notifyListeners();
    } finally {
      if (importedPath != null) await store.deleteFile(importedPath);
    }
  }

  Future<void> analyze() async {
    final path = _imagePath;
    if (path == null || _analyzing) return;
    final operationToken = _operationToken;
    _analyzing = true;
    _stage = RedactionStage.analyzing;
    _error = null;
    notifyListeners();
    try {
      final result = await _detector.analyze(path);
      if (operationToken != _operationToken) return;
      _imageSize = result.size;
      _candidates = _classifier.classify(result.rawDetections);
      _masks = [
        for (final candidate in _candidates)
          if (candidate.selected) _maskForCandidate(candidate),
      ];
      _stage = RedactionStage.editing;
      _resetHistory();
    } catch (error) {
      if (operationToken != _operationToken) return;
      _stage = RedactionStage.editing;
      _error = '识别失败：$error';
    }
    _analyzing = false;
    notifyListeners();
  }

  void toggleCandidate(String id) {
    final index = _candidates.indexWhere((candidate) => candidate.id == id);
    if (index < 0) return;
    final candidate = _candidates[index];
    final next = candidate.copyWith(selected: !candidate.selected);
    final updated = List<DetectionCandidate>.of(_candidates)..[index] = next;
    _candidates = updated;
    if (_stage == RedactionStage.editing) _syncMaskForCandidate(next);
    _recordHistory();
    notifyListeners();
  }

  void addManualRect(PixelRect rect) {
    final size = _imageSize;
    if (size == null) return;
    final clamped = rect.clampTo(size).normalized();
    if (clamped.width < 2 || clamped.height < 2) return;
    _masks = [
      ..._masks,
      MaskRegion(
        id: 'manual_${DateTime.now().microsecondsSinceEpoch}',
        rect: _expandedRect(clamped),
        sourceRect: clamped,
        source: MaskSource.manual,
        style: _maskSettings.style,
        colorMode: _maskSettings.colorMode,
        color: _maskSettings.color,
      ),
    ];
    _recordHistory();
    notifyListeners();
  }

  void removeMask(String id) {
    final next = _masks.where((mask) => mask.id != id).toList();
    if (next.length == _masks.length) return;
    _masks = next;
    final candidateId = id.startsWith('mask_') ? id.substring(5) : null;
    if (candidateId != null) _setCandidateSelection(candidateId, false);
    _recordHistory();
    notifyListeners();
  }

  void undo() {
    if (!canUndo) return;
    _historyIndex--;
    _restore(_history[_historyIndex]);
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _historyIndex++;
    _restore(_history[_historyIndex]);
    notifyListeners();
  }

  void setMaskStyle(MaskStyle style) =>
      _updateMaskSettings(_maskSettings.copyWith(style: style));

  void setMaskColorMode(MaskColorMode mode) =>
      _updateMaskSettings(_maskSettings.copyWith(colorMode: mode));

  void setMaskColor(int color) => _updateMaskSettings(
    _maskSettings.copyWith(colorMode: MaskColorMode.fixed, color: color),
  );

  void setMaskPadding(double padding) =>
      _updateMaskSettings(_maskSettings.copyWith(padding: padding));

  String exportPath(String fileName) => store.exportPath(fileName);

  Future<int> cacheSize() => store.cacheSize();

  Future<int> clearCache() async {
    final running = _cacheRun;
    if (running != null) return running;
    final run = _clearCache(_exportRun);
    _cacheRun = run;
    try {
      return await run;
    } finally {
      if (identical(_cacheRun, run)) _cacheRun = null;
    }
  }

  Future<int> _clearCache(Future<void>? exportRun) async {
    if (exportRun != null) await exportRun;
    return store.clearCache();
  }

  Future<bool> exportNow({
    required String outPath,
    required ExportFormat format,
    int quality = 95,
  }) async {
    final cacheRun = _cacheRun;
    if (cacheRun != null) await cacheRun;
    final running = _exportRun;
    if (running != null) {
      await running;
      return false;
    }
    final run = _performExport(
      outPath: outPath,
      format: format,
      quality: quality,
    );
    late final Future<void> tracked;
    tracked = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _exportRun = tracked;
    try {
      return await run;
    } finally {
      if (identical(_exportRun, tracked)) _exportRun = null;
    }
  }

  Future<bool> _performExport({
    required String outPath,
    required ExportFormat format,
    required int quality,
  }) async {
    final source = _imagePath;
    if (_bridge == null) {
      _error = 'Rust 原生引擎未加载';
      notifyListeners();
      return false;
    }
    if (source == null || _masks.isEmpty) {
      _error = '请至少确认一个需要遮挡的区域';
      notifyListeners();
      return false;
    }
    _exporting = true;
    _error = null;
    notifyListeners();
    try {
      await store.ensureExportDirectory();
      await RedactionExporter(_bridge).export(
        sourcePath: source,
        masks: _masks,
        format: format,
        quality: quality,
        outPath: outPath,
      );
      return true;
    } catch (error) {
      _error = '导出失败：$error';
      return false;
    } finally {
      _exporting = false;
      notifyListeners();
    }
  }

  Future<void> clear() async {
    final operationToken = ++_operationToken;
    final previousPath = _takeCurrentImage();
    final exportRun = _exportRun;
    _analyzing = false;
    _exporting = false;
    _stage = RedactionStage.empty;
    _imageSize = null;
    _candidates = const [];
    _masks = const [];
    _maskSettings = MaskStyleSettings.defaultSettings;
    _resetHistory();
    _error = null;
    notifyListeners();
    try {
      if (exportRun != null) await exportRun;
      if (previousPath != null) await store.deleteFile(previousPath);
    } catch (error) {
      _error = '清理图片失败：$error';
      notifyListeners();
      rethrow;
    }
    if (operationToken == _operationToken) notifyListeners();
  }

  String? _takeCurrentImage() {
    final path = _imagePath;
    _imagePath = null;
    return path;
  }

  void _syncMaskForCandidate(DetectionCandidate candidate) {
    final maskId = 'mask_${candidate.id}';
    final next = _masks.where((mask) => mask.id != maskId).toList();
    if (candidate.selected) next.add(_maskForCandidate(candidate));
    _masks = next;
  }

  MaskRegion _maskForCandidate(DetectionCandidate candidate) {
    final sourceRect = candidate.rect.clampTo(_imageSize!).normalized();
    return candidate
        .toMask(settings: _maskSettings)
        .copyWith(rect: _expandedRect(sourceRect), sourceRect: sourceRect);
  }

  PixelRect _expandedRect(PixelRect sourceRect) => sourceRect
      .expand(_maskSettings.padding)
      .clampTo(_imageSize!)
      .normalized();

  void _updateMaskSettings(MaskStyleSettings settings) {
    if (_maskSettings.style == settings.style &&
        _maskSettings.colorMode == settings.colorMode &&
        _maskSettings.color == settings.color &&
        _maskSettings.padding == settings.padding) {
      return;
    }
    _maskSettings = settings;
    _masks = [
      for (final mask in _masks)
        mask.copyWith(
          style: settings.style,
          colorMode: settings.colorMode,
          color: settings.color,
          rect: _expandedRect(mask.sourceRect),
        ),
    ];
    _recordHistory();
    notifyListeners();
  }

  void _setCandidateSelection(String id, bool selected) {
    final index = _candidates.indexWhere((candidate) => candidate.id == id);
    if (index < 0) return;
    _candidates = List<DetectionCandidate>.of(_candidates)
      ..[index] = _candidates[index].copyWith(selected: selected);
  }

  void _resetHistory() {
    _history = [RedactionSnapshot(_candidates, _masks, _maskSettings)];
    _historyIndex = 0;
  }

  void _recordHistory() {
    final next = _history.take(_historyIndex + 1).toList()
      ..add(RedactionSnapshot(_candidates, _masks, _maskSettings));
    _history = next;
    _historyIndex = next.length - 1;
  }

  void _restore(RedactionSnapshot snapshot) {
    _candidates = List.of(snapshot.candidates);
    _masks = List.of(snapshot.masks);
    _maskSettings = snapshot.settings;
  }
}
