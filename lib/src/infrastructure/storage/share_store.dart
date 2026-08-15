/// 调用系统分享面板分享临时导出文件。
library;

import 'dart:io';

import 'package:flutter/services.dart';

class ShareStore {
  static const _channel = MethodChannel('stitch/public_media');

  static Future<void> shareImage({
    required String sourcePath,
    required String displayName,
    required String mimeType,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('当前平台未实现图片分享');
    }
    await _channel.invokeMethod<void>('shareImage', {
      'sourcePath': sourcePath,
      'displayName': displayName,
      'mimeType': mimeType,
    });
  }
}
