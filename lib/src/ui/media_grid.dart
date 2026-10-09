import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../core/thumb_cache.dart';
import '../theme.dart';
import 'thumb_image.dart';

const double _gap = 3;

/// The resizable thumbnail grid.
///
/// Tile size changes by slider, by pinch, or by Ctrl + scroll wheel, and the
/// grid keeps its place while it does. Tap selects, double tap opens the
/// image.
class MediaGrid extends StatefulWidget {
  const MediaGrid({super.key, required this.state});
  final AppState state;

  @override
  State<MediaGrid> createState() => _MediaGridState();
}

class _MediaGridState extends State<MediaGrid> {
  final ScrollController _scroll = ScrollController();

  int _columns = 1;
  double _rowExtent = 1;
  double _viewport = 0;

  int _seenReveal = 0;
  double _seenTileSize = 0;
  String? _seenFolder;

  // Double-tap detection done by hand: a GestureDetector with onDoubleTap
  // would hold every single tap back for 300 ms.
  int _lastTapId = -1;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Pinch tracking.
  final Map<int, Offset> _pointers = {};
  double _pinchStartDistance = 0;
  double _pinchStartSize = 0;

  bool _ctrl = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _seenReveal = state.revealTick;
    _seenTileSize = state.tileSize;
    state.addListener(_onState);
    HardwareKeyboard.instance.addHandler(_onKey);
    if (state.selectedIndex >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(state.selectedIndex));
    }
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _scroll.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl != _ctrl && mounted) setState(() => _ctrl = ctrl);
    return false;
  }

  void _onState() {
    if (!mounted) return;
    // Keep the row at the top of the view where it is when tiles resize.
    if (state.tileSize != _seenTileSize && _scroll.hasClients) {
      final anchor = (_scroll.offset / _rowExtent).floor() * _columns;
      _seenTileSize = state.tileSize;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final target = (anchor ~/ _columns) * _rowExtent;
        _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent).toDouble());
      });
      return;
    }
    if (state.folder != _seenFolder) {
      _seenFolder = state.folder;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
    setState(() {});
    if (state.revealTick != _seenReveal) {
      _seenReveal = state.revealTick;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(state.selectedIndex));
    }
  }

  /// Scroll just far enough that item [index] is fully visible.
  void _reveal(int index) {
    if (!mounted || index < 0 || !_scroll.hasClients) return;
    final top = (index ~/ _columns) * _rowExtent;
    final bottom = top + _rowExtent + _gap;
    final offset = _scroll.offset;
    double? target;
    if (top < offset) {
      target = top;
    } else if (bottom > offset + _viewport) {
      target = bottom - _viewport;
    }
    if (target != null) {
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent).toDouble());
    }
  }

  void _tap(int index, MediaItem item) {
    final now = DateTime.now();
    final again = item.id == _lastTapId && now.difference(_lastTapAt) < const Duration(milliseconds: 350);
    _lastTapId = item.id;
    _lastTapAt = now;
    if (again) {
      _lastTapId = -1;
      state.openFocus(index);
    } else {
      state.select(index);
    }
  }

  void _pointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      final p = _pointers.values.toList();
      _pinchStartDistance = (p[0] - p[1]).distance;
      _pinchStartSize = state.tileSize;
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2 && _pinchStartDistance > 20) {
      final p = _pointers.values.toList();
      final scale = (p[0] - p[1]).distance / _pinchStartDistance;
      state.setTileSize(_pinchStartSize * scale);
    }
  }

  void _pointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    _pinchStartDistance = 0;
  }

  void _pointerSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent && _ctrl) {
      final step = e.scrollDelta.dy > 0 ? 1 / 1.12 : 1.12;
      state.setTileSize(state.tileSize * step);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = state.items;
    if (state.folder == null) {
      return const _Hint(
        icon: Icons.folder_open_outlined,
        title: 'Choose a folder',
        detail: 'Pick a folder on the left to browse its images.',
      );
    }
    if (items.isEmpty) {
      if (!state.loaded) return const SizedBox.expand();
      return ValueListenableBuilder<ScanStatus>(
        valueListenable: state.scan,
        builder: (context, scan, _) {
          if (scan.error != null) {
            return _Hint(icon: Icons.error_outline, title: 'Could not read this folder', detail: scan.error!);
          }
          if (scan.running) {
            return const _Hint(icon: Icons.hourglass_empty, title: 'Reading folder…', detail: '');
          }
          if (state.query.trim().isNotEmpty) {
            return _Hint(
              icon: Icons.search_off,
              title: 'Nothing matches “${state.query.trim()}”',
              detail: 'Search looks at file names, prompts, models and LoRAs.',
            );
          }
          return _Hint(
            icon: Icons.image_not_supported_outlined,
            title: 'No images here',
            detail: state.recursive
                ? 'This folder and its sub-folders hold no images or videos.'
                : 'This folder holds no images or videos. Sub-folders are not included.',
          );
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = math.max(1, ((width - _gap) / (state.tileSize + _gap)).floor());
        final tile = (width - _gap * (columns + 1)) / columns;
        _columns = columns;
        _rowExtent = tile + _gap;
        _viewport = constraints.maxHeight;
        state.gridColumns = columns;
        state.gridRowsPerPage = math.max(1, (_viewport / _rowExtent).floor());

        final dpr = MediaQuery.devicePixelRatioOf(context);
        final tier = ThumbCache.tierFor(tile * dpr);

        return Listener(
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerUp,
          onPointerCancel: _pointerUp,
          onPointerSignal: _pointerSignal,
          child: Scrollbar(
            controller: _scroll,
            child: GridView.builder(
              controller: _scroll,
              // With Ctrl held the wheel resizes tiles instead of scrolling.
              physics: _ctrl ? const NeverScrollableScrollPhysics() : null,
              padding: const EdgeInsets.all(_gap),
              scrollCacheExtent: const ScrollCacheExtent.viewport(0.75),
              addAutomaticKeepAlives: false,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: _gap,
                crossAxisSpacing: _gap,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                if (index >= items.length) return const SizedBox.shrink();
                final item = items[index];
                return _Tile(
                  key: ValueKey<int>(item.id),
                  item: item,
                  tier: tier,
                  cache: state.thumbs,
                  selected: index == state.selectedIndex,
                  onTap: () => _tap(index, item),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.item,
    required this.tier,
    required this.cache,
    required this.selected,
    required this.onTap,
  });

  final MediaItem item;
  final int tier;
  final ThumbCache cache;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Semantics(
        label: item.name,
        selected: selected,
        image: true,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: selected ? Border.all(color: Palette.accent, width: 2) : null,
            borderRadius: BorderRadius.circular(3),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: ColoredBox(
              color: Palette.tile,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ThumbImage(cache: cache, item: item, tier: tier),
                  if (item.isVideo) _VideoBadge(durationMs: item.durationMs),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoBadge extends StatelessWidget {
  const _VideoBadge({required this.durationMs});
  final int durationMs;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Container(
        margin: const EdgeInsets.all(5),
        padding: const EdgeInsets.fromLTRB(3, 1, 6, 1),
        decoration: BoxDecoration(
          color: const Color(0xB3000000),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_arrow, size: 14, color: Colors.white),
            if (durationMs > 0)
              Text(
                formatDuration(durationMs),
                style: const TextStyle(color: Colors.white, fontSize: 11, height: 1.2),
              ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.title, required this.detail});
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: Palette.faint),
            const SizedBox(height: 14),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Palette.text)),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Palette.muted, height: 1.4),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
