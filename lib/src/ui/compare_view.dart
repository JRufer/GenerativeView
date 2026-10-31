import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/compare.dart';
import '../core/media_image.dart';
import '../core/models.dart';
import '../theme.dart';
import 'meta_panel.dart' show copyText, toast;
import 'notes_widgets.dart' show starColor;

/// The fewest and most pictures the compare view takes.
const int compareMin = 2;
const int compareMax = 4;

/// The letter each picture goes by in the compare view.
const List<String> compareLetters = ['A', 'B', 'C', 'D'];

/// Open the compare view for [items]: two to four pictures side by side,
/// zoomed and moved together, with their settings set out and what differs
/// picked out. Videos are left out.
Future<void> openCompare(BuildContext context, AppState state, List<MediaItem> items) async {
  final pictures = items.where((i) => !i.isVideo).toList();
  if (pictures.length < compareMin) {
    toast(context, 'Tick two to four pictures to compare them');
    return;
  }
  if (pictures.length > compareMax) {
    toast(context, 'Comparing the first four of the ${pictures.length} ticked');
  }
  final shown = pictures.take(compareMax).toList();
  await Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 140),
      reverseTransitionDuration: const Duration(milliseconds: 100),
      pageBuilder: (_, _, _) => ComparePage(state: state, items: shown),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// Two to four pictures side by side. Pinching, scrolling or dragging any
/// of them zooms and moves them all, so the same spot of each is in view;
/// a double tap zooms in there, or back out. Their settings are listed
/// beside or under them, a column each, with the rows that differ marked,
/// and each prompt worded against the first picture's.
class ComparePage extends StatefulWidget {
  const ComparePage({super.key, required this.state, required this.items});
  final AppState state;
  final List<MediaItem> items;

  @override
  State<ComparePage> createState() => _ComparePageState();
}

class _ComparePageState extends State<ComparePage> {
  List<GenInfo>? _infos;
  Object? _error;

  /// Shared by every picture: how far zoomed in, and how far moved, as a
  /// fraction of the pane it is in.
  double _zoom = 1;
  Offset _pan = Offset.zero;

  // Where a pinch or drag started.
  double _zoomAtStart = 1;
  Offset _point = Offset.zero;

  bool _details = true;
  bool _onlyDifferences = true;

  static const double _maxZoom = 8;

  @override
  void initState() {
    super.initState();
    Future.wait([for (final i in widget.items) widget.state.metadata(i)]).then(
      (infos) {
        if (mounted) setState(() => _infos = infos);
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e);
      },
    );
  }

  void _close() => Navigator.of(context).maybePop();

  // ------------------------------------------------------------ zooming

  /// Zoom to [zoom], keeping the spot under [focal] (in a pane of [size])
  /// where it is.
  void _zoomAt(double zoom, Offset focal, Size size) {
    zoom = zoom.clamp(1.0, _maxZoom);
    final c = size.center(Offset.zero);
    final spot = c + (focal - c - _scaled(_pan, size)) / _zoom;
    final pan = focal - c - (spot - c) * zoom;
    setState(() {
      _zoom = zoom;
      _pan = _clamp(Offset(pan.dx / size.width, pan.dy / size.height), zoom);
    });
  }

  static Offset _scaled(Offset fraction, Size size) => Offset(fraction.dx * size.width, fraction.dy * size.height);

  /// No further than the picture's edge reaches the pane's.
  static Offset _clamp(Offset pan, double zoom) {
    final reach = (zoom - 1) / 2;
    return Offset(pan.dx.clamp(-reach, reach), pan.dy.clamp(-reach, reach));
  }

  void _reset() => setState(() {
        _zoom = 1;
        _pan = Offset.zero;
      });

  void _step(int direction, Size? size) {
    final s = size ?? const Size(1, 1);
    _zoomAt(_zoom * math.pow(1.25, direction), s.center(Offset.zero), s);
  }

  Size? _lastPane;

  // ------------------------------------------------------------ layout

  /// The columns that show [aspects] (width over height) biggest in [box],
  /// and the size of each pane.
  static (int, Size) _grid(Size box, List<double> aspects) {
    var best = (1, Size.zero);
    var bestScale = -1.0;
    final n = aspects.length;
    for (var columns = 1; columns <= n; columns++) {
      final rows = (n / columns).ceil();
      final pane = Size(box.width / columns, box.height / rows);
      // The smallest of the pictures, as fitted, is what limits the view.
      var scale = double.infinity;
      for (final a in aspects) {
        final w = math.min(pane.width, pane.height * a);
        scale = math.min(scale, w * (w / a));
      }
      if (scale > bestScale) {
        bestScale = scale;
        best = (columns, pane);
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.items.length;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.keyI): () => setState(() => _details = !_details),
        const SingleActivator(LogicalKeyboardKey.bracketRight): () => setState(() => _details = !_details),
        const SingleActivator(LogicalKeyboardKey.keyD): () => setState(() => _onlyDifferences = !_onlyDifferences),
        const SingleActivator(LogicalKeyboardKey.digit0): _reset,
        const SingleActivator(LogicalKeyboardKey.equal): () => _step(1, _lastPane),
        const SingleActivator(LogicalKeyboardKey.add): () => _step(1, _lastPane),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _step(1, _lastPane),
        const SingleActivator(LogicalKeyboardKey.minus): () => _step(-1, _lastPane),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _step(-1, _lastPane),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Palette.canvas,
          body: SafeArea(
            child: Column(
              children: [
                _TopBar(
                  count: n,
                  details: _details,
                  onlyDifferences: _onlyDifferences,
                  zoomed: _zoom > 1.001,
                  onBack: _close,
                  onDetails: () => setState(() => _details = !_details),
                  onOnlyDifferences: () => setState(() => _onlyDifferences = !_onlyDifferences),
                  onReset: _reset,
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      // Side by side in a wide window; underneath otherwise.
                      final side = box.maxWidth >= 900 && box.maxWidth > box.maxHeight * 1.25;
                      final pictures = _pictures();
                      if (!_details) return pictures;
                      final details = _Details(
                        infos: _infos,
                        error: _error,
                        items: widget.items,
                        onlyDifferences: _onlyDifferences,
                      );
                      if (side) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: pictures),
                            Container(
                              width: math.min(440, box.maxWidth * 0.36),
                              decoration: const BoxDecoration(
                                color: Palette.panel,
                                border: Border(left: BorderSide(color: Palette.line)),
                              ),
                              child: details,
                            ),
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 3, child: pictures),
                          Expanded(
                            flex: 2,
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Palette.panel,
                                border: Border(top: BorderSide(color: Palette.line)),
                              ),
                              child: details,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pictures() {
    final items = widget.items;
    return LayoutBuilder(
      builder: (context, box) {
        // Each pane has its picture's name under it, outside the picture.
        const caption = 26.0;
        final aspects = [
          for (final i in items) i.width > 0 && i.height > 0 ? i.width / i.height : 1.0,
        ];
        final (columns, pane) = _grid(Size(box.maxWidth, box.maxHeight), aspects);
        final imageSize = Size(pane.width - 4, math.max(1, pane.height - caption - 4));
        _lastPane = imageSize;
        return Wrap(
          children: [
            for (var i = 0; i < items.length; i++)
              SizedBox(
                key: ValueKey<String>('compare-pane-$i'),
                width: box.maxWidth / columns,
                height: pane.height,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Column(
                    children: [
                      SizedBox(
                        width: imageSize.width,
                        height: imageSize.height,
                        child: _pane(items[i], imageSize),
                      ),
                      SizedBox(height: caption, child: _Caption(letter: compareLetters[i], item: items[i])),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _pane(MediaItem item, Size size) {
    final c = size.center(Offset.zero);
    final offset = _scaled(_pan, size);
    // Zoomed about the middle of the pane, then moved.
    final transform = Matrix4.identity()
      ..setEntry(0, 0, _zoom)
      ..setEntry(1, 1, _zoom)
      ..setEntry(0, 3, c.dx * (1 - _zoom) + offset.dx)
      ..setEntry(1, 3, c.dy * (1 - _zoom) + offset.dy);
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver.register(event, (_) {
            final dy = event.scrollDelta.dy;
            if (dy == 0) return;
            _zoomAt(_zoom * (dy < 0 ? 1.15 : 1 / 1.15), event.localPosition, size);
          });
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (d) {
          _zoomAtStart = _zoom;
          _point = d.localFocalPoint;
        },
        onScaleUpdate: (d) {
          if (d.pointerCount > 1) {
            _zoomAt(_zoomAtStart * d.scale, d.localFocalPoint, size);
          } else if (_zoom > 1.001) {
            final moved = d.localFocalPoint - _point;
            setState(() => _pan = _clamp(_pan + Offset(moved.dx / size.width, moved.dy / size.height), _zoom));
          }
          // A pinch moves its focal point too.
          _point = d.localFocalPoint;
        },
        onDoubleTapDown: (d) => _point = d.localPosition,
        onDoubleTap: () {
          if (_zoom > 1.001) {
            _reset();
          } else {
            _zoomAt(2.5, _point, size);
          }
        },
        child: ClipRect(
          child: ColoredBox(
            color: Palette.tile,
            child: Transform(
              transform: transform,
              child: SizedBox.expand(
                child: Image(
                  image: mediaImage(item),
                  fit: BoxFit.contain,
                  filterQuality: _zoom > 1.5 ? FilterQuality.none : FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image_outlined, color: Palette.faint),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.count,
    required this.details,
    required this.onlyDifferences,
    required this.zoomed,
    required this.onBack,
    required this.onDetails,
    required this.onOnlyDifferences,
    required this.onReset,
  });
  final int count;
  final bool details;
  final bool onlyDifferences;
  final bool zoomed;
  final VoidCallback onBack;
  final VoidCallback onDetails;
  final VoidCallback onOnlyDifferences;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    Widget button({required Key key, required String tooltip, required IconData icon, required VoidCallback onTap, bool on = false}) => Tooltip(
          message: tooltip,
          child: InkWell(
            key: key,
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            hoverColor: Palette.hover,
            child: SizedBox(width: 38, height: 38, child: Icon(icon, size: 19, color: on ? Palette.accent : Palette.muted)),
          ),
        );
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: Palette.panel,
        border: Border(bottom: BorderSide(color: Palette.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          button(key: const ValueKey<String>('compare-back'), tooltip: 'Back (Esc)', icon: Icons.arrow_back, onTap: onBack),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Comparing $count pictures',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          if (zoomed)
            button(key: const ValueKey<String>('compare-fit'), tooltip: 'Fit them again (0)', icon: Icons.fit_screen_outlined, onTap: onReset),
          // Said in words, not only as an icon: it changes what the list shows.
          FilterChip(
            key: const ValueKey<String>('compare-differences'),
            showCheckmark: false,
            avatar: Icon(
              onlyDifferences ? Icons.check_box : Icons.check_box_outline_blank,
              size: 17,
              color: onlyDifferences ? Palette.accent : Palette.muted,
            ),
            label: const Text('Only differences'),
            tooltip: 'List only the settings that differ (D)',
            selected: onlyDifferences,
            onSelected: details ? (_) => onOnlyDifferences() : null,
          ),
          const SizedBox(width: 4),
          button(
            key: const ValueKey<String>('compare-details'),
            tooltip: details ? 'Hide the settings (I)' : 'Show the settings (I)',
            icon: Icons.view_sidebar_outlined,
            on: details,
            onTap: onDetails,
          ),
        ],
      ),
    );
  }
}

/// A picture's letter, name and stars, under it.
class _Caption extends StatelessWidget {
  const _Caption({required this.letter, required this.item});
  final String letter;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Letter(letter),
        const SizedBox(width: 6),
        Expanded(
          child: Tooltip(
            message: item.path,
            child: Text(item.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Palette.muted)),
          ),
        ),
        if (item.rating > 0)
          Text('★' * item.rating, style: const TextStyle(fontSize: 11, color: starColor)),
        if (item.flag == Flag.keep) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.check_circle, size: 14, color: Color(0xFF7BC88F))),
        if (item.flag == Flag.reject) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.cancel, size: 14, color: Palette.danger)),
      ],
    );
  }
}

class _Letter extends StatelessWidget {
  const _Letter(this.letter);
  final String letter;

  @override
  Widget build(BuildContext context) => Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Palette.raised, borderRadius: BorderRadius.circular(4), border: Border.all(color: Palette.line)),
        child: Text(letter, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Palette.text)),
      );
}

/// The settings, a row each, with each picture's value under the row's
/// name; the rows that differ are marked.
class _Details extends StatelessWidget {
  const _Details({required this.infos, required this.error, required this.items, required this.onlyDifferences});
  final List<GenInfo>? infos;
  final Object? error;
  final List<MediaItem> items;
  final bool onlyDifferences;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return const Center(child: Text('Could not read their settings', style: TextStyle(color: Palette.muted)));
    }
    final infos = this.infos;
    if (infos == null) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final all = compareRows(infos);
    final differ = all.where((r) => r.differs).length;
    // The prompt always shows: its word-by-word comparison is the point.
    final rows = onlyDifferences ? all.where((r) => r.differs || r.label == 'Prompt').toList() : all;
    return ListView(
      key: const ValueKey<String>('compare-details-list'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      children: [
        Text(
          differ == 0
              ? 'Their settings are the same.'
              : differ == 1
                  ? '1 setting differs. Prompts are worded against A: added words are blue, missing ones struck through.'
                  : '$differ settings differ. Prompts are worded against A: added words are blue, missing ones struck through.',
          key: const ValueKey<String>('compare-summary'),
          style: const TextStyle(fontSize: 12, color: Palette.faint, height: 1.4),
        ),
        for (final r in rows) _Row(row: r),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row});
  final CompareRow row;

  @override
  Widget build(BuildContext context) {
    final differs = row.differs;
    return Container(
      key: ValueKey<String>('compare-row-${row.label}'),
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: differs ? Palette.accent : Palette.line, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            row.label.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.9,
              fontWeight: FontWeight.w600,
              color: differs ? Palette.accent : Palette.faint,
            ),
          ),
          const SizedBox(height: 3),
          for (var i = 0; i < row.values.length; i++)
            InkWell(
              onTap: row.values[i].isEmpty ? null : () => copyText(context, row.values[i], row.label.toLowerCase()),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.only(top: 1), child: _Letter(compareLetters[i])),
                    const SizedBox(width: 8),
                    Expanded(child: _value(i, differs)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _value(int i, bool differs) {
    final value = row.values[i];
    const base = TextStyle(fontSize: 12.5, color: Palette.text, height: 1.4);
    if (value.trim().isEmpty) {
      return const Text('—', style: TextStyle(fontSize: 12.5, color: Palette.faint));
    }
    if (!row.prompt || i == 0 || !differs) {
      // Settings that differ from A's are brighter than those that match it.
      final same = i > 0 && !CompareRow('', [row.values.first, value]).differs;
      return Text(value, style: base.copyWith(color: differs && i > 0 && same ? Palette.muted : Palette.text));
    }
    return Text.rich(
      TextSpan(
        children: [
          for (final piece in wordDiff(row.values.first, value))
            TextSpan(
              text: piece.text,
              style: switch (piece.change) {
                Change.same => null,
                Change.added => TextStyle(
                    color: Palette.accent,
                    backgroundColor: Palette.accent.withValues(alpha: 0.14),
                    fontWeight: FontWeight.w600,
                  ),
                Change.removed => const TextStyle(
                    color: Palette.faint,
                    decoration: TextDecoration.lineThrough,
                    decorationColor: Palette.faint,
                  ),
              },
            ),
        ],
      ),
      style: base,
    );
  }
}
