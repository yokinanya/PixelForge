/// Android 应用缓存统计与清理。
library;

import 'dart:io';

import 'package:flutter/services.dart';

class ApplicationCacheStore {
  const ApplicationCacheStore._();

  static const _channel = MethodChannel('pixelforge/cache');

  static Future<int> runtimeCacheSize() async {
    if (!Platform.isAndroid) return 0;
    return await _channel.invokeMethod<int>('runtimeCacheSize') ?? 0;
  }

  static Future<int> clearRuntimeCache() async {
    if (!Platform.isAndroid) return 0;
    return await _channel.invokeMethod<int>('clearRuntimeCache') ?? 0;
  }
}
