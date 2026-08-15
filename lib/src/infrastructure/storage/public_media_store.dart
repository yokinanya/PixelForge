/// 将导出的图片写入 Android 公共图片库。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pixelforge/src/domain/models.dart';

class PublicMediaStore {
  static const _channel = MethodChannel('stitch/public_media');

  static Future<String> saveImage({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    required ExportLocation location,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('当前平台未实现公共目录导出');
    }
    final result = await _channel.invokeMethod<String>('saveImage', {
      'sourcePath': sourcePath,
      'displayName': displayName,
      'mimeType': mimeType,
      'directory': location.key,
    });
    if (result == null || result.isEmpty) {
      throw StateError('公共目录没有返回保存位置');
    }
    return result;
  }
}
