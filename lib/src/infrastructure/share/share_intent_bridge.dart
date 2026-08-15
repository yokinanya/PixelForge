/// Android 系统分享入口的 Flutter 桥接。
library;

import 'package:flutter/services.dart';

abstract interface class ShareIntentBridge {
  void setSharedImagesHandler(ValueChanged<List<String>> handler);

  Future<List<String>> getPendingSharedImages();

  Future<void> deleteSharedImages(Iterable<String> paths);

  Future<void> setShareTargetEnabled(bool enabled);
}

class MethodChannelShareIntentBridge implements ShareIntentBridge {
  MethodChannelShareIntentBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('pixelforge/share');

  final MethodChannel _channel;

  @override
  void setSharedImagesHandler(ValueChanged<List<String>> handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'sharedImages') {
        throw MissingPluginException('未知的分享方法：${call.method}');
      }
      final paths = (call.arguments as List<dynamic>).cast<String>();
      handler(paths);
      return true;
    });
  }

  @override
  Future<List<String>> getPendingSharedImages() async {
    final result = await _channel.invokeMethod<List<dynamic>>(
      'getPendingSharedImages',
    );
    return (result ?? const <dynamic>[]).cast<String>();
  }

  @override
  Future<void> deleteSharedImages(Iterable<String> paths) {
    return _channel.invokeMethod<void>('deleteSharedImages', {
      'paths': paths.toList(growable: false),
    });
  }

  @override
  Future<void> setShareTargetEnabled(bool enabled) {
    return _channel.invokeMethod<void>('setShareTargetEnabled', {
      'enabled': enabled,
    });
  }
}
