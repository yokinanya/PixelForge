/// 导入截图缩略图的横向排序与拖动交互。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pixelforge/src/domain/models.dart';

const thumbnailStripHeight = 108.0;
const _thumbnailWidth = 82.0;
const _thumbnailHeight = 92.0;
const _thumbnailCacheWidth = 164;
const _autoScrollEdge = 40.0;
const _autoScrollStep = 8.0;

class ThumbnailReorderStrip extends StatefulWidget {
  const ThumbnailReorderStrip({
    super.key,
    required this.images,
    required this.enabled,
    required this.currentIndex,
    required this.onSelect,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragOver,
    required this.onDragLeave,
    required this.onDragEnd,
  });

  final List<SessionImage> images;
  final bool enabled;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<String> onDragStarted;
  final ValueChanged<Offset> onDragUpdate;
  final ValueChanged<String> onDragOver;
  final ValueChanged<String> onDragLeave;
  final VoidCallback onDragEnd;

  @override
  State<ThumbnailReorderStrip> createState() => _ThumbnailReorderStripState();
}

class _ThumbnailReorderStripState extends State<ThumbnailReorderStrip> {
  final _scrollController = ScrollController();
  final _viewportKey = GlobalKey();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: thumbnailStripHeight,
      child: SingleChildScrollView(
        key: _viewportKey,
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: List.generate(widget.images.length, _buildItem)),
      ),
    );
  }

  Widget _buildItem(int index) {
    final image = widget.images[index];
    return _ThumbnailDropTarget(
      key: ValueKey(image.path),
      image: image,
      index: index,
      selected: index == widget.currentIndex,
      enabled: widget.enabled,
      onTap: () => widget.onSelect(index),
      onDragStarted: () => widget.onDragStarted(image.path),
      onDragUpdate: _handleDragUpdate,
      onDragOver: () => widget.onDragOver(image.path),
      onDragLeave: () => widget.onDragLeave(image.path),
      onDragEnd: widget.onDragEnd,
    );
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    widget.onDragUpdate(details.globalPosition);
    if (!_scrollController.hasClients) return;
    final renderObject = _viewportKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return;
    final left = renderObject.localToGlobal(Offset.zero).dx;
    final right = left + renderObject.size.width;
    final x = details.globalPosition.dx;
    if (x < left + _autoScrollEdge) {
      _scrollBy(-_autoScrollStep);
    } else if (x > right - _autoScrollEdge) {
      _scrollBy(_autoScrollStep);
    }
  }

  void _scrollBy(double delta) {
    final position = _scrollController.position;
    final offset = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (offset != position.pixels) _scrollController.jumpTo(offset);
  }
}

class _ThumbnailDropTarget extends StatelessWidget {
  const _ThumbnailDropTarget({
    super.key,
    required this.image,
    required this.index,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragOver,
    required this.onDragLeave,
    required this.onDragEnd,
  });

  final SessionImage image;
  final int index;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDragStarted;
  final ValueChanged<DragUpdateDetails> onDragUpdate;
  final VoidCallback onDragOver;
  final VoidCallback onDragLeave;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _thumbnailWidth,
      height: _thumbnailHeight,
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) =>
            enabled && details.data != image.path,
        onMove: enabled ? (_) => onDragOver() : null,
        onLeave: enabled ? (_) => onDragLeave() : null,
        builder: (context, candidateData, rejectedData) {
          return LongPressDraggable<String>(
            data: image.path,
            maxSimultaneousDrags: enabled ? 1 : 0,
            hapticFeedbackOnStart: true,
            ignoringFeedbackPointer: true,
            onDragStarted: onDragStarted,
            onDragUpdate: onDragUpdate,
            onDragEnd: (_) => onDragEnd(),
            feedback: Material(
              color: Colors.transparent,
              elevation: 8,
              child: SizedBox(
                width: _thumbnailWidth,
                height: _thumbnailHeight,
                child: _ThumbnailCard(
                  image: image,
                  index: index,
                  selected: true,
                  enabled: false,
                  onTap: () {},
                ),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.25,
              child: _ThumbnailCard(
                image: image,
                index: index,
                selected: selected,
                enabled: enabled,
                onTap: onTap,
              ),
            ),
            child: _ThumbnailCard(
              image: image,
              index: index,
              selected: selected,
              enabled: enabled,
              onTap: onTap,
            ),
          );
        },
      ),
    );
  }
}

class _ThumbnailCard extends StatelessWidget {
  const _ThumbnailCard({
    required this.image,
    required this.index,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final SessionImage image;
  final int index;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.outlineVariant;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      elevation: selected ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: outline, width: selected ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(image.path),
              fit: BoxFit.contain,
              cacheWidth: _thumbnailCacheWidth,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            ),
            Align(
              alignment: Alignment.topLeft,
              child: _ThumbnailBadge(label: '${index + 1}'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThumbnailBadge extends StatelessWidget {
  const _ThumbnailBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class DragDeleteZone extends StatelessWidget {
  const DragDeleteZone({super.key, required this.armed});

  final bool armed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = armed ? scheme.error : scheme.surfaceContainerHighest;
    final foreground = armed ? scheme.onError : scheme.onSurfaceVariant;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).shadowColor.withValues(alpha: 0.24),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            armed ? Icons.delete_forever_outlined : Icons.delete_outline,
            color: foreground,
          ),
          const SizedBox(width: 8),
          Text(
            armed ? '松手删除' : '拖到这里删除',
            style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
