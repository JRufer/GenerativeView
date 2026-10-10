import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'thumb_image.dart';
import 'video_page.dart';

/// One image at a time. Swipe (or use the keyboard) to move through the
/// folder, pinch or turn the wheel to zoom, double tap to go back to the grid.
class FocusView extends StatefulWidget {
  const FocusView({super.key, required this.state});
  final AppState state;

  @override
  State<FocusView> createState() => _FocusViewState();
}

class _FocusViewState extends State<FocusView> {
  late final PageController _pages;
  bool _zoomed = false;

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
  });

  final AppState state;
  final MediaItem item;
  final bool active;
  final ValueChanged<bool> onZoomChanged;

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

    // The scroll wheel zooms and only zooms (InteractiveViewer's own
    // behaviour); moving between images is for swipes and the keyboard.
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
        child: SizedBox.expand(child: content),
      ),
    );
  }
}
