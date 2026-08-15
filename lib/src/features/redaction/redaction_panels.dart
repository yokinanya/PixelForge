/// Unified bottom workspace for redaction editing.
library;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/application/redaction_controller.dart';
import 'package:pixelforge/src/application/redaction_models.dart';
import 'package:pixelforge/src/features/redaction/redaction_style_controls.dart';

class RedactionWorkspacePanel extends StatelessWidget {
  const RedactionWorkspacePanel({
    super.key,
    required this.session,
    required this.mode,
    required this.styleExpanded,
    required this.enabled,
    required this.onOpenList,
    required this.onModeChanged,
    required this.onToggleStyle,
  });

  final RedactionController session;
  final RedactionInteractionMode mode;
  final bool styleExpanded;
  final bool enabled;
  final VoidCallback onOpenList;
  final ValueChanged<RedactionInteractionMode> onModeChanged;
  final VoidCallback onToggleStyle;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text('已添加 ${session.masks.length} 个遮挡区域')),
              _ToolIcon(
                icon: Icons.checklist,
                tooltip: '选择列表',
                enabled: enabled,
                onPressed: onOpenList,
              ),
              _ToolIcon(
                icon: Icons.select_all,
                tooltip: '选择模式',
                enabled: enabled,
                selected: mode == RedactionInteractionMode.selection,
                onPressed: () =>
                    _toggleMode(RedactionInteractionMode.selection),
              ),
              _ToolIcon(
                icon: Icons.crop_free,
                tooltip: '自由框选',
                enabled: enabled,
                selected: mode == RedactionInteractionMode.freeBox,
                onPressed: () => _toggleMode(RedactionInteractionMode.freeBox),
              ),
              _ToolIcon(
                icon: Icons.tune,
                tooltip: styleExpanded ? '收起遮挡样式' : '展开遮挡样式',
                enabled: enabled,
                selected: styleExpanded,
                onPressed: onToggleStyle,
              ),
            ],
          ),
          if (styleExpanded && enabled) ...[
            const SizedBox(height: 10),
            RedactionStyleControls(session: session),
          ],
        ],
      ),
    );
  }

  void _toggleMode(RedactionInteractionMode next) {
    onModeChanged(mode == next ? RedactionInteractionMode.normal : next);
  }
}

class _ToolIcon extends StatelessWidget {
  const _ToolIcon({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: IconButton.filledTonal(
      onPressed: enabled ? onPressed : null,
      isSelected: selected,
      icon: Icon(icon),
    ),
  );
}

String redactionCandidateLabel(DetectionCandidate candidate) =>
    switch (candidate.kind) {
      DetectionKind.personName => '可能的姓名',
      DetectionKind.address => '可能的地址',
      DetectionKind.phone => '手机号',
      DetectionKind.email => '邮箱',
      DetectionKind.url => '网址',
      DetectionKind.ipAddress => 'IP 地址',
      DetectionKind.longNumber => '疑似编号',
      DetectionKind.qrCode => '二维码',
      DetectionKind.barcode => '条形码',
      DetectionKind.face => '人脸',
      DetectionKind.textLine =>
        candidate.text == null ? '文字' : '文字：${candidate.text}',
    };
