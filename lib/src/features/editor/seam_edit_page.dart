/// 单个接缝的局部放大编辑页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelforge/src/application/session_controller.dart';
import 'package:pixelforge/src/application/session_models.dart';
import 'package:pixelforge/src/application/session_provider.dart';
import 'package:pixelforge/src/features/editor/seam_focus_preview.dart';

class SeamEditPage extends ConsumerStatefulWidget {
  const SeamEditPage({
    super.key,
    required this.session,
    required this.pairIndex,
  });

  final SessionController session;
  final int pairIndex;

  @override
  ConsumerState<SeamEditPage> createState() => _SeamEditPageState();
}

class _SeamEditPageState extends ConsumerState<SeamEditPage> {
  late int _draftTopCut;
  late int _draftBottomCut;

  @override
  void initState() {
    super.initState();
    final seam = widget.session.seams[widget.pairIndex];
    _draftTopCut = seam?.topCut ?? 0;
    _draftBottomCut = seam?.bottomCut ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionProvider);
    final seam = _currentSeam;
    if (seam == null) {
      return const Scaffold(body: Center(child: Text('接缝数据不可用')));
    }
    final top = widget.session.images[widget.pairIndex];
    final bottom = widget.session.images[widget.pairIndex + 1];
    return Scaffold(
      appBar: AppBar(title: Text('调整接缝 ${widget.pairIndex + 1}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _SeamStatus(
            seam: seam,
            topCut: _draftTopCut,
            bottomCut: _draftBottomCut,
          ),
          const SizedBox(height: 12),
          SeamFocusPreview(
            top: top,
            bottom: bottom,
            dx: seam.dx,
            topCut: _draftTopCut,
            bottomCut: _draftBottomCut,
            onTopCutChanged: (value) => setState(() => _draftTopCut = value),
            onBottomCutChanged: (value) =>
                setState(() => _draftBottomCut = value),
            onCommit: _commitCuts,
          ),
          const SizedBox(height: 8),
          Text(
            '上方切线控制第一张图的结束位置，下方切线控制第二张图的开始位置。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              widget.session.resetSeam(widget.pairIndex);
              setState(() {
                _draftTopCut = seam.analysis.dy + seam.automaticBottomCut;
                _draftBottomCut = seam.automaticBottomCut;
              });
            },
            icon: const Icon(Icons.refresh),
            label: const Text('恢复自动匹配'),
          ),
        ],
      ),
    );
  }

  void _commitCuts() {
    final applied = widget.session.setManualCuts(
      widget.pairIndex,
      topCut: _draftTopCut,
      bottomCut: _draftBottomCut,
    );
    if (!applied) {
      if (mounted && widget.session.lastError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(widget.session.lastError!)));
      }
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  SeamState? get _currentSeam {
    if (widget.pairIndex < 0 ||
        widget.pairIndex >= widget.session.seams.length) {
      return null;
    }
    return widget.session.seams[widget.pairIndex];
  }
}

class _SeamStatus extends StatelessWidget {
  const _SeamStatus({
    required this.seam,
    required this.topCut,
    required this.bottomCut,
  });

  final SeamState seam;
  final int topCut;
  final int bottomCut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          Icon(
            seam.manual ? Icons.tune : Icons.auto_awesome,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(seam.manual ? '手动调整' : '自动匹配'),
          const Spacer(),
          Text(
            '上 $topCut px · 下 $bottomCut px',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
