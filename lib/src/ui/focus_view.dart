import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'thumb_image.dart';
import 'video_page.dart';

/// One image at a time. Swipe (or use the keyboard) to move through the
/// folder, pinch or Ctrl + wheel to zoom, double tap to go back to the grid.
class FocusView extends StatefulWidget {
  const FocusView({super.key, required this.state});
  final AppState state;

  @override
  State<FocusView> createState() => _FocusViewState();
}

class _FocusViewState extends State<FocusView> {
  late final PageController _pages;
  bool _zoomed = false;
  double _wheelDebt = 0;
  DateTime _lastWheelStep = DateTime.fromMillisecondsSinceEpoch(0);

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _pages = PageController(
      initialPage: state.selectedIndex < 0 ? 0 : state.selectedIndex,
    );
    state.addListener(_onState);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _precacheAround(state.selectedIndex);
    });
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    _pages.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    // Keyboard navigation, or the list shifting under us as files arrive:
    // either way make the pager show the selected item again.
    final target = state.selectedIndex;
    if (target < 0 || !_pages.hasClients) return;
    final current = _pages.page?.round();
    if (current != target) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _pages.hasClients &&
            _pages.page?.round() != state.selectedIndex &&
            state.selectedIndex >= 0) {
          _pages.jumpToPage(state.selectedIndex);
        }
      });
    }
  }

  void _precacheAround(int index) {
    final items = state.items;
    for (final i in [index + 1, index - 1, index + 2]) {
      if (i < 0 || i >= items.length) continue;
      final item = items[i];
      if (item.isVideo) continue;
      precacheImage(FileImage(File(item.path)), context, onError: (_, _) {});
    }
  }

  void _onWheel(PointerScrollEvent e) {
    // Trackpads send a stream of small deltas; turn them into discrete steps.
    _wheelDebt += e.scrollDelta.dy;
    final now = DateTime.now();
    if (_wheelDebt.abs() < 30 ||
        now.difference(_lastWheelStep) < const Duration(milliseconds: 70)) {
      return;
    }
    final forward = _wheelDebt > 0;
    _wheelDebt = 0;
    _lastWheelStep = now;
    state.move(forward ? 1 : -1);
  }

  @override
  Widget build(BuildContext context) {
    final items = state.items;
    if (items.isEmpty) return const SizedBox.expand();
    return ColoredBox(
      color: Palette.canvas,
      child: PageView.builder(
        controller: _pages,
        allowImplicitScrolling: true,
        physics: _zoomed
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        itemCount: items.length,
        onPageChanged: (index) {
          if (index != state.selectedIndex) state.select(index);
          _precacheAround(index);
        },
        itemBuilder: (context, index) {
          if (index >= items.length) return const SizedBox.shrink();
          final item = items[index];
          final active = index == state.selectedIndex;
          return _FocusPage(
            key: ValueKey<int>(item.id),
            state: state,
            item: item,
            active: active,
            onZoomChanged: (zoomed) {
              if (active && zoomed != _zoomed) setState(() => _zoomed = zoomed);
            },
            onWheel: _onWheel,
          );
        },
      ),
    );
  }
}

class _FocusPage extends StatefulWidget {
  const _FocusPage({
    super.key,
    required this.state,
    required this.item,
    required this.active,
    required this.onZoomChanged,
    required this.onWheel,
  });

  final AppState state;
  final MediaItem item;
  final bool active;
  final ValueChanged<bool> onZoomChanged;
  final ValueChanged<PointerScrollEvent> onWheel;

  @override
  State<_FocusPage> createState() => _FocusPageState();
}

class _FocusPageState extends State<_FocusPage> {
  final TransformationController _transform = TransformationController();

  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1.01;

  @override
  void didUpdateWidget(_FocusPage old) {
    super.didUpdateWidget(old);
    // Leaving a page puts it back to fit-to-screen.
    if (old.active && !widget.active && _zoomed) {
      _transform.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Claim the event so the zoom gesture underneath does not also take it.
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      final scroll = e as PointerScrollEvent;
      if (HardwareKeyboard.instance.isControlPressed) {
        _zoomAt(
          scroll.localPosition,
          scroll.scrollDelta.dy > 0 ? 1 / 1.2 : 1.2,
        );
      } else if (!_zoomed) {
        widget.onWheel(scroll);
      }
    });
  }

  void _zoomAt(Offset focal, double factor) {
    final current = _transform.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(1.0, 12.0).toDouble();
    if (next == current) return;
    if (next <= 1.0) {
      _transform.value = Matrix4.identity();
    } else {
      // Keep the point under the cursor fixed while scaling.
      final scene = _transform.toScene(focal);
      _transform.value = Matrix4.identity()
        ..translateByDouble(focal.dx, focal.dy, 0, 1)
        ..scaleByDouble(next, next, 1, 1)
        ..translateByDouble(-scene.dx, -scene.dy, 0, 1);
    }
    widget.onZoomChanged(_zoomed);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final Widget content;
    if (item.isVideo) {
      content = VideoPage(
        item: item,
        cache: widget.state.thumbs,
        active: widget.active,
        playbackAvailable: widget.state.videoPlayback,
      );
    } else {
      content = Stack(
        fit: StackFit.expand,
        children: [
          // The thumbnail is already in memory: show it at once, and let the
          // full image replace it when it has decoded.
          ThumbImage(
            cache: widget.state.thumbs,
            item: item,
            tier: 1,
            fit: BoxFit.contain,
            showPlaceholderIcon: false,
          ),
          Image.file(
            File(item.path),
            key: ValueKey<String>(item.version),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Palette.faint,
                size: 40,
              ),
            ),
          ),
        ],
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: widget.state.closeFocus,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 12,
        panEnabled: _zoomed,
        scaleEnabled: !item.isVideo,
        onInteractionEnd: (_) => widget.onZoomChanged(_zoomed),
        child: Listener(
          onPointerSignal: _signal,
          behavior: HitTestBehavior.opaque,
          child: SizedBox.expand(child: content),
        ),
      ),
    );
  }
}
