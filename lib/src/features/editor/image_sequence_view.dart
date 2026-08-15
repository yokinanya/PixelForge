/// 导入截图的横向预览与排序区域。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pixelforge/src/application/session_controller.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/features/editor/image_sequence_components.dart';
import 'package:pixelforge/src/features/editor/thumbnail_reorder_strip.dart';

const _deleteZoneHeight = 76.0;
const _deleteZoneBottomGap = 8.0;

class ImageSequenceView extends StatefulWidget {
  const ImageSequenceView({super.key, required this.session});

  final SessionController session;

  @override
  State<ImageSequenceView> createState() => _ImageSequenceViewState();
}

class _ImageSequenceViewState extends State<ImageSequenceView> {
  late final PageController _pageController;
  late List<SessionImage> _orderedImages;
  var _currentIndex = 0;
  String? _draggingPath;
  int? _dragStartIndex;
  int? _dragCurrentIndex;
  String? _lastHoverPath;
  var _deleteArmed = false;
  final _deleteZoneKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _orderedImages = List.of(widget.session.images);
  }

  @override
  void didUpdateWidget(covariant ImageSequenceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncImagesIfNeeded();
    _keepCurrentIndexInRange();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final images = _orderedImages;
    final session = widget.session;
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: ImageSequencePreview(
                      controller: _pageController,
                      images: images,
                      currentIndex: _currentIndex,
                      onPageChanged: _setCurrentIndex,
                    ),
                  ),
                  ThumbnailReorderStrip(
                    images: images,
                    enabled: !session.analyzing,
                    currentIndex: _currentIndex,
                    onSelect: _selectImage,
                    onDragStarted: _startDrag,
                    onDragUpdate: _updateDragPosition,
                    onDragOver: _handleDragOver,
                    onDragLeave: _handleDragLeave,
                    onDragEnd: _finishDrag,
                  ),
                ],
              ),
              if (_draggingPath != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: thumbnailStripHeight + _deleteZoneBottomGap,
                  height: _deleteZoneHeight,
                  child: IgnorePointer(
                    key: _deleteZoneKey,
                    child: Center(child: DragDeleteZone(armed: _deleteArmed)),
                  ),
                ),
            ],
          ),
        ),
        CalculationFooter(session: session),
      ],
    );
  }

  void _setCurrentIndex(int index) {
    if (!mounted || index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  void _selectImage(int index) {
    if (index == _currentIndex || !_pageController.hasClients) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _syncImagesIfNeeded() {
    if (_draggingPath != null ||
        _sameImageOrder(_orderedImages, widget.session.images)) {
      return;
    }
    _orderedImages = List.of(widget.session.images);
  }

  bool _sameImageOrder(List<SessionImage> first, List<SessionImage> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index].path != second[index].path) return false;
    }
    return true;
  }

  void _startDrag(String path) {
    if (widget.session.analyzing) return;
    final index = _orderedImages.indexWhere((image) => image.path == path);
    if (index < 0) return;
    setState(() {
      _draggingPath = path;
      _dragStartIndex = index;
      _dragCurrentIndex = index;
      _lastHoverPath = null;
      _deleteArmed = false;
    });
  }

  void _updateDragPosition(Offset position) {
    if (_draggingPath == null) return;
    final renderObject = _deleteZoneKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return;
    final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    final armed = rect.contains(position);
    if (armed != _deleteArmed) setState(() => _deleteArmed = armed);
  }

  void _handleDragOver(String targetPath) {
    final draggingPath = _draggingPath;
    if (draggingPath == null || targetPath == draggingPath) return;
    if (_lastHoverPath == targetPath) return;
    final from = _orderedImages.indexWhere(
      (image) => image.path == draggingPath,
    );
    final target = _orderedImages.indexWhere(
      (image) => image.path == targetPath,
    );
    if (from < 0 || target < 0) return;
    final selectedPath = _orderedImages[_currentIndex].path;
    final reordered = List.of(_orderedImages);
    final image = reordered.removeAt(from);
    reordered.insert(target, image);
    setState(() {
      _orderedImages = reordered;
      _dragCurrentIndex = target;
      _lastHoverPath = targetPath;
      _currentIndex = reordered.indexWhere((item) => item.path == selectedPath);
    });
  }

  void _handleDragLeave(String targetPath) {
    if (_lastHoverPath == targetPath) {
      setState(() => _lastHoverPath = null);
    }
  }

  void _finishDrag() {
    if (widget.session.analyzing) {
      _resetDragState();
      return;
    }
    final draggingPath = _draggingPath;
    final start = _dragStartIndex;
    final current = _dragCurrentIndex;
    if (draggingPath == null || start == null || current == null) return;
    final shouldDelete = _deleteArmed;
    final selectedPath = _orderedImages[_currentIndex].path;
    final nextImages = shouldDelete
        ? _orderedImages.where((image) => image.path != draggingPath).toList()
        : _orderedImages;
    final selectedIndex = nextImages.indexWhere(
      (image) => image.path == selectedPath,
    );
    setState(() {
      _orderedImages = nextImages;
      _currentIndex = selectedIndex < 0
          ? nextImages.isEmpty
                ? 0
                : _currentIndex.clamp(0, nextImages.length - 1)
          : selectedIndex;
      _resetDragState();
    });
    if (shouldDelete) {
      unawaited(widget.session.removeImage(start));
    } else if (start != current) {
      unawaited(widget.session.moveImage(start, current));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToCurrentPage();
    });
  }

  void _resetDragState() {
    _draggingPath = null;
    _dragStartIndex = null;
    _dragCurrentIndex = null;
    _lastHoverPath = null;
    _deleteArmed = false;
  }

  void _keepCurrentIndexInRange() {
    final maxIndex = _orderedImages.length - 1;
    final nextIndex = _currentIndex.clamp(0, maxIndex < 0 ? 0 : maxIndex);
    if (nextIndex == _currentIndex) return;
    _currentIndex = nextIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToCurrentPage();
    });
  }

  void _jumpToCurrentPage() {
    if (_pageController.hasClients) {
      _pageController.jumpToPage(_currentIndex);
    }
  }
}
