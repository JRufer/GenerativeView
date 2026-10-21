import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../core/thumb_cache.dart';
import '../platform.dart';
import '../theme.dart';
import 'compare_view.dart';
import 'image_menu.dart';
import 'notes_widgets.dart';
import 'remix_status.dart' show HighlightPulse;
import 'thumb_image.dart';

const double _gap = 3;

/// The resizable thumbnail grid.
///
/// Tile size changes by slider, by pinch, or by Ctrl + scroll wheel, and the
/// grid keeps its place while it does. Tiles crop to fill or show the whole
/// image, per [AppState.cropTiles]. Tap selects, double tap opens the image,
/// and a right click or a press-and-hold brings up its menu.
///
/// The box in each tile's top right corner ticks it (as does Ctrl-click, and
/// Shift-click ticks a run); once any is ticked, a tap anywhere on a tile
/// ticks or unticks it, and the menu acts on all that are ticked. On the
/// desktop a tile can be dragged out of the window as its file (with the
/// others ticked, if it is one of them).
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
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _reveal(state.selectedIndex),
      );
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
        _scroll.jumpTo(
          target.clamp(0.0, _scroll.position.maxScrollExtent).toDouble(),
        );
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
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _reveal(state.selectedIndex),
      );
    }
  }

  /// Whether any of the selected tile is on screen.
  bool _selectionInView() {
    final index = state.selectedIndex;
    if (index < 0 || !_scroll.hasClients) return false;
    final top = (index ~/ _columns) * _rowExtent;
    final offset = _scroll.offset;
    return top + _rowExtent > offset && top < offset + _viewport;
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
      _scroll.jumpTo(
        target.clamp(0.0, _scroll.position.maxScrollExtent).toDouble(),
      );
    }
  }

  /// The tile last ticked or unticked, where a Shift-click run starts.
  int _anchor = -1;

  void _tap(int index, MediaItem item) {
    final keyboard = HardwareKeyboard.instance;
    final ctrl = isPrimaryShortcutModifier(
      isControlPressed: keyboard.isControlPressed,
      isMetaPressed: keyboard.isMetaPressed,
    );
    if (keyboard.isShiftPressed && state.checkedCount > 0 && _anchor >= 0 && _anchor < state.items.length) {
      // A run from the last one ticked to this one.
      final from = math.min(_anchor, index), to = math.max(_anchor, index);
      for (var i = from; i <= to; i++) {
        final it = state.items[i];
        if (!state.isChecked(it.id)) state.toggleChecked(it);
      }
      _anchor = index;
      state.select(index);
      return;
    }
    if (ctrl || state.checkedCount > 0) {
      _check(index, item);
      return;
    }
    final now = DateTime.now();
    final again =
        item.id == _lastTapId &&
        now.difference(_lastTapAt) < const Duration(milliseconds: 350);
    _lastTapId = item.id;
    _lastTapAt = now;
    if (again) {
      _lastTapId = -1;
      state.openFocus(index);
    } else {
      state.select(index);
    }
  }

  /// Tick [item], or untick it; it becomes the one shown.
  void _check(int index, MediaItem item) {
    _lastTapId = -1;
    _anchor = index;
    state.toggleChecked(item);
    state.select(index);
  }

  /// A tile dragged out of the window: its file, or every ticked one if it
  /// is ticked.
  void _dragOut(MediaItem item) {
    dragFilesOut([for (final t in state.targetsFor(item)) t.path]);
  }

  void _menu(int index, MediaItem item, Offset position) {
    // Two fingers resting on the grid are a pinch, not a long press.
    if (_pointers.length > 1) return;
    state.select(index);
    showImageMenu(context, state, item, position);
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
            return _Hint(
              icon: Icons.error_outline,
              title: 'Could not read this folder',
              detail: scan.error!,
            );
          }
          if (scan.running) {
            return const _Hint(
              icon: Icons.hourglass_empty,
              title: 'Reading folder…',
              detail: '',
            );
          }
          if (state.query.trim().isNotEmpty && (state.contentSearch || state.lookingAlike)) {
            // Described, not searched for: what is missing depends on how
            // far content search has got.
            return ValueListenableBuilder<ContentStatus>(
              valueListenable: state.content,
              builder: (context, status, _) {
                if (!status.installed) {
                  return _Hint(
                    icon: Icons.image_search,
                    title: state.lookingAlike ? '“More like this” is not set up yet' : 'Content search is not set up yet',
                    detail: 'It needs the content search model first. See above.',
                  );
                }
                if (state.lookingAlike && state.queryError != null && !status.indexing) {
                  return _Hint(
                    icon: Icons.image_search,
                    title: 'Could not find look-alikes',
                    detail: state.queryError!,
                  );
                }
                if (status.indexing || status.embedded == 0) {
                  return const _Hint(
                    icon: Icons.hourglass_empty,
                    title: 'Looking at the pictures…',
                    detail: 'Matches appear as they are found.',
                  );
                }
                return _Hint(
                  icon: Icons.search_off,
                  title: 'No picture here shows “${state.query.trim()}”',
                  detail:
                      'Content search goes by what the pictures show, '
                      'and lists only the ones that match.',
                );
              },
            );
          }
          if (RegExp(r'(^|\s)(is|type|kind|media):(near-)?dup', caseSensitive: false).hasMatch(state.query)) {
            return const _Hint(
              icon: Icons.filter_none,
              title: 'No near-duplicates here',
              detail: 'None of these pictures has an all-but-identical twin among them. '
                  'Pictures are compared by what they look like, at the same shape.',
            );
          }
          if (state.query.trim().isNotEmpty) {
            return _Hint(
              icon: Icons.search_off,
              title: 'Nothing matches “${state.query.trim()}”',
              detail:
                  'Search looks for whole words in prompts, and at file, '
                  'model and LoRA names. Add * to match part of a word: fox*',
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
        // When the view gets shorter under a selection that was on screen
        // (the metadata footer opening, the soft keyboard coming up), keep
        // that tile in sight.
        if (constraints.maxHeight < _viewport && _selectionInView()) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _reveal(state.selectedIndex),
          );
        }
        final width = constraints.maxWidth;
        final columns = math.max(
          1,
          ((width - _gap) / (state.tileSize + _gap)).floor(),
        );
        final tile = (width - _gap * (columns + 1)) / columns;
        _columns = columns;
        _rowExtent = tile + _gap;
        _viewport = constraints.maxHeight;
        state.gridColumns = columns;
        state.gridRowsPerPage = math.max(1, (_viewport / _rowExtent).floor());

        final dpr = MediaQuery.devicePixelRatioOf(context);
        final tier = ThumbCache.tierFor(tile * dpr);

        final grid = Listener(
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
                  fresh: state.fresh.contains(item.id),
                  highlight: state.highlightIds.contains(item.id) ? state.highlightTick : 0,
                  compact: tile < 130,
                  tier: tier,
                  cache: state.thumbs,
                  fit: state.cropTiles ? BoxFit.cover : BoxFit.contain,
                  selected: index == state.selectedIndex,
                  checked: state.isChecked(item.id),
                  onTap: () => _tap(index, item),
                  onCheck: () => _check(index, item),
                  onMenu: (position) => _menu(index, item, position),
                  onDragOut: canDragFilesOut ? () => _dragOut(item) : null,
                );
              },
            ),
          ),
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            grid,
            if (state.fresh.isNotEmpty || state.checkedCount > 0)
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      if (state.checkedCount > 0) SelectionBar(state: state),
                      if (state.fresh.isNotEmpty) _NewPill(state: state),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// "3 selected": what is ticked, with the menu for all of them (the same
/// one a right click on any of them brings up), Select all, and a way to
/// untick them all.
class SelectionBar extends StatelessWidget {
  const SelectionBar({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final n = state.checkedCount;
    final all = n == state.items.length;
    Widget button({required Key key, required String tooltip, required IconData icon, required void Function(BuildContext) onTap}) =>
        Builder(
          builder: (context) => Tooltip(
            message: tooltip,
            child: InkResponse(
              key: key,
              radius: 18,
              onTap: () => onTap(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Icon(icon, size: 18, color: Palette.text),
              ),
            ),
          ),
        );
    return Material(
      key: const ValueKey<String>('selection-bar'),
      color: Palette.raised,
      elevation: 4,
      shape: const StadiumBorder(side: BorderSide(color: Palette.accent, width: 1.2)),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_box, size: 18, color: Palette.accent),
            const SizedBox(width: 6),
            Text(
              '$n selected',
              key: const ValueKey<String>('selection-count'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            if (!all)
              button(
                key: const ValueKey<String>('selection-all'),
                tooltip: 'Select all (Ctrl A)',
                icon: Icons.select_all,
                onTap: (_) => state.checkAll(),
              ),
            if (n >= compareMin && n <= compareMax)
              button(
                key: const ValueKey<String>('selection-compare'),
                tooltip: 'Compare them side by side (V)',
                icon: Icons.compare,
                onTap: (context) => openCompare(context, state, state.checkedItems),
              ),
            button(
              key: const ValueKey<String>('selection-menu'),
              tooltip: 'What to do with them',
              icon: Icons.more_vert,
              onTap: (context) {
                final items = state.checkedItems;
                if (items.isEmpty) return;
                final box = context.findRenderObject()! as RenderBox;
                showImageMenu(context, state, items.first, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
              },
            ),
            button(
              key: const ValueKey<String>('selection-clear'),
              tooltip: 'Clear the selection (Esc)',
              icon: Icons.close,
              onTap: (_) => state.clearChecked(),
            ),
          ],
        ),
      ),
    );
  }
}

/// "3 new": pictures arrived while the folder was open. Tap to go to the
/// newest; the cross forgets them.
class _NewPill extends StatelessWidget {
  const _NewPill({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final n = state.fresh.length;
    return Material(
      key: const ValueKey<String>('new-pill'),
      color: Palette.accent,
      elevation: 4,
      shape: const StadiumBorder(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            customBorder: const StadiumBorder(),
            onTap: state.showNewest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.fiber_new, size: 18, color: Color(0xFF0B1020)),
                  const SizedBox(width: 6),
                  Text(
                    n == 1 ? '1 new picture' : '$n new pictures',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF0B1020)),
                  ),
                ],
              ),
            ),
          ),
          Tooltip(
            message: 'Mark as seen',
            child: InkResponse(
              radius: 16,
              onTap: state.clearFresh,
              child: const Padding(
                padding: EdgeInsets.fromLTRB(4, 8, 12, 8),
                child: Icon(Icons.close, size: 16, color: Color(0xFF0B1020)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.item,
    required this.fresh,
    this.highlight = 0,
    required this.compact,
    required this.tier,
    required this.cache,
    required this.fit,
    required this.selected,
    this.checked = false,
    required this.onTap,
    required this.onCheck,
    required this.onMenu,
    this.onDragOut,
  });

  final MediaItem item;
  final int tier;
  final ThumbCache cache;

  /// Arrived while the folder was open, and not looked at yet.
  final bool fresh;

  /// Non-zero while the eye is being drawn to this tile (a remix just
  /// gone to); a new number plays the animation again.
  final int highlight;

  /// Small enough that the marks are kept short.
  final bool compact;

  /// cover = cropped to fill the square, contain = the whole image.
  final BoxFit fit;
  final bool selected;

  /// Ticked, to be acted on with others.
  final bool checked;
  final VoidCallback onTap;

  /// The corner box was tapped.
  final VoidCallback onCheck;

  /// Called with where the pointer was on a right click or a long press.
  final ValueChanged<Offset> onMenu;

  /// Dragged with the mouse: carry the file out of the window. Null where
  /// that cannot be done.
  final VoidCallback? onDragOut;

  @override
  Widget build(BuildContext context) {
    return HighlightPulse(
      tick: highlight,
      child: _body(),
    );
  }

  /// How round a tile's corners are; the picture inside a whole-image
  /// (uncropped) tile is rounded a touch less, so it sits inside the box.
  static const double _radius = 6;
  static const double _pictureRadius = 4;

  Widget _picture() {
    final w = item.width, h = item.height;
    if (fit == BoxFit.contain && w > 0 && h > 0) {
      // Fitted to its own shape, so its own corners can be rounded.
      return Center(
        child: AspectRatio(
          aspectRatio: w / h,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_pictureRadius),
            child: ThumbImage(cache: cache, item: item, tier: tier, fit: fit),
          ),
        ),
      );
    }
    return ThumbImage(cache: cache, item: item, tier: tier, fit: fit);
  }

  Widget _body() {
    final tile = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onSecondaryTapUp: (details) => onMenu(details.globalPosition),
      onLongPressStart: (details) => onMenu(details.globalPosition),
      child: Semantics(
        label: item.name,
        selected: selected,
        checked: checked,
        image: true,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: checked
                ? Border.all(color: Palette.accent, width: 3)
                : selected
                ? Border.all(color: Palette.accent, width: 2)
                : fresh
                ? Border.all(color: Palette.accent.withValues(alpha: 0.7), width: 1.5)
                : null,
            borderRadius: BorderRadius.circular(_radius),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: ColoredBox(
              color: Palette.tile,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Rejected pictures fade back, so the keepers stand out.
                  Opacity(
                    opacity: item.flag == Flag.reject ? 0.4 : 1,
                    child: _picture(),
                  ),
                  if (checked) const ColoredBox(color: Color(0x2E7AA2F7)),
                  if (item.isVideo) _VideoBadge(durationMs: item.durationMs),
                  if (item.rating > 0 || item.flag != Flag.none)
                    TileMarks(rating: item.rating, flag: item.flag, compact: compact, besideCheck: true),
                  Align(
                    alignment: Alignment.topRight,
                    child: _CheckBox(key: ValueKey<String>('tile-check-${item.id}'), checked: checked, onTap: onCheck),
                  ),
                  if (fresh)
                    const Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: EdgeInsets.all(6),
                        child: _FreshDot(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final drag = onDragOut;
    if (drag == null) return tile;
    return _DragOut(onDragOut: drag, child: tile);
  }
}

/// The tick box in a tile's corner: empty, or filled and ticked. Bigger to
/// the finger than it looks.
class _CheckBox extends StatelessWidget {
  const _CheckBox({super.key, required this.checked, required this.onTap});
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // Held, it is still a tick, not the menu.
      onLongPress: () {},
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 5, 5, 12),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: checked ? Palette.accent : const Color(0x59000000),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: checked ? Palette.accent : const Color(0xE6FFFFFF), width: 1.6),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 3)],
          ),
          child: checked ? const Icon(Icons.check, size: 15, color: Color(0xFF0B1020)) : null,
        ),
      ),
    );
  }
}

/// Starts a drag of files out of the window when the mouse is pressed on
/// [child] and moved a little way with the button held. Touch and pens
/// are left to scroll and press as usual.
class _DragOut extends StatefulWidget {
  const _DragOut({required this.onDragOut, required this.child});
  final VoidCallback onDragOut;
  final Widget child;

  @override
  State<_DragOut> createState() => _DragOutState();
}

class _DragOutState extends State<_DragOut> {
  Offset? _down;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        _down = e.kind == PointerDeviceKind.mouse && e.buttons == kPrimaryMouseButton ? e.position : null;
      },
      onPointerMove: (e) {
        final down = _down;
        if (down == null || e.buttons != kPrimaryMouseButton) return;
        if ((e.position - down).distance < 12) return;
        _down = null;
        widget.onDragOut();
      },
      onPointerUp: (_) => _down = null,
      onPointerCancel: (_) => _down = null,
      child: widget.child,
    );
  }
}

class _FreshDot extends StatelessWidget {
  const _FreshDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: Palette.accent,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xCC000000), width: 1.5),
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
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  height: 1.2,
                ),
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
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Palette.text),
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Palette.muted,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
