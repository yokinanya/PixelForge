/// 系统分享入口状态与待处理图片。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pixelforge/src/infrastructure/share/share_intent_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ShareController extends ChangeNotifier {
  ShareController({required this._preferences, ShareIntentBridge? bridge})
    : _bridge = bridge ?? MethodChannelShareIntentBridge();

  static const preferenceKey = 'share_target_enabled';

  final SharedPreferences _preferences;
  final ShareIntentBridge _bridge;
  var _shareTargetEnabled = true;
  List<String> _pendingImages = const [];

  bool get shareTargetEnabled => _shareTargetEnabled;
  bool get hasPendingImages => _pendingImages.isNotEmpty;
  List<String> get pendingImages => List.unmodifiable(_pendingImages);

  Future<void> initialize() async {
    _bridge.setSharedImagesHandler(_receiveSharedImages);
    _shareTargetEnabled = _preferences.getBool(preferenceKey) ?? true;
    if (!Platform.isAndroid) return;
    await _bridge.setShareTargetEnabled(_shareTargetEnabled);
    _receiveSharedImages(await _bridge.getPendingSharedImages());
  }

  Future<void> setShareTargetEnabled(bool enabled) async {
    if (_shareTargetEnabled == enabled) return;
    await _bridge.setShareTargetEnabled(enabled);
    final persisted = await _preferences.setBool(preferenceKey, enabled);
    if (!persisted) throw StateError('无法保存分享设置');
    _shareTargetEnabled = enabled;
    notifyListeners();
  }

  List<String> takePendingImages() {
    final images = _pendingImages;
    _pendingImages = const [];
    if (images.isNotEmpty) notifyListeners();
    return List.unmodifiable(images);
  }

  Future<void> dismissPendingImages() async {
    final images = takePendingImages();
    await releaseSharedImages(images);
  }

  Future<void> releaseSharedImages(Iterable<String> paths) async {
    final uniquePaths = paths.where((path) => path.isNotEmpty).toSet();
    if (uniquePaths.isEmpty || !Platform.isAndroid) return;
    await _bridge.deleteSharedImages(uniquePaths);
  }

  void _receiveSharedImages(List<String> paths) {
    final newPaths = paths.where(
      (path) => path.isNotEmpty && !_pendingImages.contains(path),
    );
    final updated = [..._pendingImages, ...newPaths];
    if (updated.length == _pendingImages.length) return;
    _pendingImages = updated;
    notifyListeners();
  }
}
