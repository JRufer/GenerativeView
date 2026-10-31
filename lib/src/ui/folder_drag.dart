import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'move_ui.dart' show folderName;
import 'thumb_image.dart';

/// Marks a folder row as a place pictures can be dropped: found by hit
/// testing where the pointer is.
@immutable
class FolderDrop {
  const FolderDrop(this.path);
  final String path;
}

/// A folder row that pictures can be dropped on: lit while a drag is over
/// it, and, if it can be opened, opened after a moment there.
class FolderDropTarget extends StatefulWidget {
  const FolderDropTarget({super.key, required this.state, required this.path, required this.child, this.onHoverOpen});
  final AppState state;
  final String path;
  final Widget child;

  /// Called once the drag has rested on the row for a moment: open it to
  /// show the folders inside.
  final VoidCallback? onHoverOpen;

  @override
  State<FolderDropTarget> createState() => _FolderDropTargetState();
}

class _FolderDropTargetState extends State<FolderDropTarget> {
  Timer? _open;
  bool _over = false;

  @override
  void initState() {
    super.initState();
    widget.state.folderDrag.addListener(_changed);
  }

  @override
  void didUpdateWidget(FolderDropTarget old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      old.state.folderDrag.removeListener(_changed);
      widget.state.folderDrag.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _open?.cancel();
    widget.state.folderDrag.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final over = widget.state.folderDrag.value?.folder == widget.path;
    if (over == _over) return;
    _open?.cancel();
    _open = over && widget.onHoverOpen != null ? Timer(const Duration(milliseconds: 700), () => widget.onHoverOpen?.call()) : null;
    setState(() => _over = over);
  }

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: FolderDrop(widget.path),
      behavior: HitTestBehavior.translucent,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          color: _over ? Palette.accent.withValues(alpha: 0.18) : null,
          border: _over ? Border.all(color: Palette.accent, width: 1.5) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: widget.child,
      ),
    );
  }
}

/// The folder whose row is under [position], if any.
String? folderAt(BuildContext context, Offset position) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, position, View.of(context).viewId);
  for (final entry in result.path) {
    final target = entry.target;
    if (target is RenderMetaData && target.metaData is FolderDrop) {
      return (target.metaData as FolderDrop).path;
    }
  }
  return null;
}

/// Lets a tile be dragged with the mouse: onto a folder in the left panel
/// to move it there (copy with Ctrl held), or out of the window, where the
/// system takes over the drag and other programs get the files. Touch and
/// pens are left to scroll and press as usual.
class PictureDrag extends StatefulWidget {
  const PictureDrag({
    super.key,
    required this.state,
    required this.targets,
    required this.onDrop,
    required this.child,
    this.onDragOut,
  });

  final AppState state;

  /// What the drag carries, worked out when it starts: the tile's picture,
  /// or every ticked one if it is ticked.
  final List<MediaItem> Function() targets;

  /// What was carried, dropped on the folder at a path; copy rather than
  /// move.
  final void Function(List<MediaItem> items, String dir, bool copy) onDrop;

  /// Hand the drag to the system, as files, to leave the window. Null
  /// where that cannot be done.
  final void Function(List<MediaItem> items)? onDragOut;

  final Widget child;

  /// How far the mouse moves, button held, before a drag starts.
  static const double slop = 12;

  /// How close to the window's edge the pointer comes before the drag is
  /// handed to the system (unless it is over a folder).
  static const double edge = 4;

  @override
  State<PictureDrag> createState() => _PictureDragState();
}

class _PictureDragState extends State<PictureDrag> {
  Offset? _down;
  List<MediaItem>? _items;
  OverlayEntry? _feedback;

  ValueNotifier<FolderDragInfo?> get _drag => widget.state.folderDrag;

  @override
  void dispose() {
    // Gone mid-drag (the grid changed under it): end the drag, but not by
    // telling the folder rows while the tree is being torn down.
    final owner = _items != null;
    _down = null;
    _items = null;
    _removeFeedback();
    if (owner) {
      final drag = _drag;
      scheduleMicrotask(() {
        if (drag.value != null) drag.value = null;
      });
    }
    super.dispose();
  }

  void _removeFeedback() {
    _feedback?.remove();
    _feedback?.dispose();
    _feedback = null;
  }

  bool get _copyHeld {
    final k = HardwareKeyboard.instance;
    return k.isControlPressed || k.isMetaPressed;
  }

  void _start(Offset position) {
    final items = widget.targets();
    if (items.isEmpty) return;
    _items = items;
    _drag.value = FolderDragInfo(items, position, null);
    final entry = OverlayEntry(builder: (_) => _DragFeedback(state: widget.state));
    _feedback = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _update(Offset position) {
    final items = _items;
    if (items == null) return;
    final folder = folderAt(context, position);
    final size = MediaQuery.sizeOf(context);
    final out = position.dx <= PictureDrag.edge ||
        position.dy <= PictureDrag.edge ||
        position.dx >= size.width - PictureDrag.edge ||
        position.dy >= size.height - PictureDrag.edge;
    final dragOut = widget.onDragOut;
    if (out && folder == null && dragOut != null) {
      // Leaving the window: the system carries the files from here.
      _end();
      dragOut(items);
      return;
    }
    _drag.value = FolderDragInfo(items, position, folder, copy: _copyHeld);
  }

  void _drop() {
    final items = _items;
    final folder = _drag.value?.folder;
    final copy = _copyHeld;
    _end();
    if (items != null && folder != null) widget.onDrop(items, folder, copy);
  }

  void _end() {
    _down = null;
    _items = null;
    _removeFeedback();
    if (_drag.value != null) _drag.value = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        _down = e.kind == PointerDeviceKind.mouse && e.buttons == kPrimaryMouseButton ? e.position : null;
      },
      onPointerMove: (e) {
        if (e.buttons != kPrimaryMouseButton) return;
        if (_items != null) {
          _update(e.position);
          return;
        }
        final down = _down;
        if (down == null || (e.position - down).distance < PictureDrag.slop) return;
        _down = null;
        _start(e.position);
        _update(e.position);
      },
      onPointerUp: (_) {
        if (_items != null) {
          _drop();
        } else {
          _down = null;
        }
      },
      onPointerCancel: (_) => _end(),
      child: widget.child,
    );
  }
}

/// What follows the pointer during a drag: the first picture, how many
/// there are, and where they would go.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FolderDragInfo?>(
      valueListenable: state.folderDrag,
      builder: (context, info, _) {
        if (info == null || info.items.isEmpty) return const SizedBox.shrink();
        final n = info.items.length;
        final folder = info.folder;
        return Positioned(
          left: info.position.dx + 12,
          top: info.position.dy + 12,
          child: IgnorePointer(
            child: Material(
              key: const ValueKey<String>('drag-feedback'),
              color: Palette.raised,
              elevation: 6,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: ThumbImage(cache: state.thumbs, item: info.items.first, tier: 0, fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        folder == null
                            ? (n == 1 ? '1 file' : '$n files')
                            : '${info.copy ? 'Copy' : 'Move'} ${n == 1 ? '' : '$n '}to ${folderName(folder)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: folder == null ? Palette.muted : Palette.text),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
