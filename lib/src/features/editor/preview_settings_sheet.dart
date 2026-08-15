/// 完整结果预览的裁切设置。
library;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/application/session_controller.dart';
import 'package:pixelforge/src/application/session_models.dart';

class PreviewSettingsSheet extends StatelessWidget {
  const PreviewSettingsSheet({super.key, required this.session});

  final SessionController session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final settings = session.exportSettings;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('预览设置', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '切换后会立即重新生成完整长图预览。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('移除系统状态栏'),
                  subtitle: const Text('仅处理首张图片'),
                  value: settings.removeStatusBar,
                  onChanged: (value) =>
                      _apply(settings: settings, removeStatusBar: value),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('去除底部多余留白'),
                  subtitle: const Text('仅处理最后一张图片底部'),
                  value: settings.trimBottomWhitespace,
                  onChanged: (value) =>
                      _apply(settings: settings, trimBottomWhitespace: value),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _apply({
    required ExportSettings settings,
    bool? removeStatusBar,
    bool? trimBottomWhitespace,
  }) {
    session.applyExportSettings(
      format: settings.format,
      jpegQuality: settings.jpegQuality,
      removeStatusBar: removeStatusBar ?? settings.removeStatusBar,
      trimBottomWhitespace:
          trimBottomWhitespace ?? settings.trimBottomWhitespace,
      retainedBottomEdge: settings.retainedBottomEdge,
    );
  }
}
