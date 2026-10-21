import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/backends.dart' show ImageInput;
import '../theme.dart';

// ---------------------------------------------------------------- the mask

/// What a mask stroke does.
enum MaskKind {
  /// A line of the brush's width along [MaskOp.points].
  stroke,

  /// The shape [MaskOp.points] trace round, filled.
  trace,

  /// All of the picture.
  all,

  /// The painted part becomes the unpainted part, and the other way round.
  invert,
}

/// One thing done to a mask. Points are fractions of the picture's width
/// and height (0 to 1), and the brush radius a fraction of its width, so
/// a mask applies to the picture at any size.
class MaskOp {
  const MaskOp(this.kind, {this.erase = false, this.points = const [], this.radius = 0});
  final MaskKind kind;

  /// Takes paint away rather than adding it.
  final bool erase;
  final List<Offset> points;
  final double radius;
}

/// The colour a mask is shown in over a picture.
const Color maskTint = Color(0xFFFF4F7B);

/// Paint [ops] onto [canvas] over a picture of [size], in [color]. Erasing
/// clears what is under it, so this is drawn in a layer of its own.
void paintMask(Canvas canvas, Size size, List<MaskOp> ops, Color color) {
  canvas.saveLayer(Offset.zero & size, Paint());
  final add = Paint()
    ..color = color
    ..isAntiAlias = true;
  final clear = Paint()
    ..blendMode = BlendMode.clear
    ..isAntiAlias = true;
  Offset at(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
  for (final op in ops) {
    final paint = op.erase ? clear : add;
    switch (op.kind) {
      case MaskKind.all:
        canvas.drawRect(Offset.zero & size, paint);
      case MaskKind.invert:
        // Opaque over nothing, nothing over opaque.
        canvas.drawRect(Offset.zero & size, Paint()
          ..color = color
          ..blendMode = BlendMode.xor);
      case MaskKind.trace:
        if (op.points.length < 3) continue;
        final path = Path()..addPolygon([for (final p in op.points) at(p)], true);
        canvas.drawPath(path, paint..style = PaintingStyle.fill);
      case MaskKind.stroke:
        final r = op.radius * size.width;
        if (op.points.isEmpty || r <= 0) continue;
        if (op.points.length == 1) {
          canvas.drawCircle(at(op.points.single), r, paint..style = PaintingStyle.fill);
          continue;
        }
        final path = Path()..moveTo(at(op.points.first).dx, at(op.points.first).dy);
        for (final p in op.points.skip(1)) {
          path.lineTo(at(p).dx, at(p).dy);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = paint.color
            ..blendMode = paint.blendMode
            ..isAntiAlias = true
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 2
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
    }
    // Fill and stroke settings are per use; leave the shared paints plain.
    add.style = PaintingStyle.fill;
    clear.style = PaintingStyle.fill;
  }
  canvas.restore();
}

/// Whether [ops] paint anything at all: some paint left after the erasing.
/// An over-estimate where erasing covered every stroke exactly, which only
/// the pixels could tell.
bool maskPaints(List<MaskOp> ops) {
  var painted = false;
  for (final op in ops) {
    switch (op.kind) {
      case MaskKind.all:
        painted = !op.erase;
      case MaskKind.invert:
        painted = true;
      case MaskKind.stroke || MaskKind.trace:
        if (!op.erase) painted = true;
    }
  }
  return painted;
}

// ---------------------------------------------------------------- rendering

/// The part of a picture of [source] size that fills [width] × [height]
/// without stretching: all of it when the shapes agree, else the middle.
Rect coverRect(Size source, int width, int height) {
  final want = width / height;
  final have = source.width / source.height;
  if ((want - have).abs() < 0.005) return Offset.zero & source;
  if (have > want) {
    final w = source.height * want;
    return Rect.fromLTWH((source.width - w) / 2, 0, w, source.height);
  }
  final h = source.width / want;
  return Rect.fromLTWH(0, (source.height - h) / 2, source.width, h);
}

/// The picture at [path] made ready to start a remix from: [width] ×
/// [height] (the middle of it, if the shape changed), with [ops] as a mask
/// the same size, both as PNGs.
Future<ImageInput> prepareImageInput({
  required String path,
  required int width,
  required int height,
  required double strength,
  required List<MaskOp> ops,
}) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final source = frame.image;
  final full = Size(source.width.toDouble(), source.height.toDouble());
  final crop = coverRect(full, width, height);
  final out = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());

  Future<Uint8List> render(void Function(Canvas canvas) draw) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, out);
    draw(canvas);
    final image = await recorder.endRecording().toImage(width, height);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  // The mask is drawn in the picture's own space, then cropped and scaled
  // exactly as the picture is.
  void maskInto(Canvas canvas, Color background, Color paint) {
    canvas.drawRect(out, Paint()..color = background);
    canvas.save();
    canvas.scale(width / crop.width, height / crop.height);
    canvas.translate(-crop.left, -crop.top);
    paintMask(canvas, full, ops, paint);
    canvas.restore();
  }

  try {
    final image = await render((canvas) {
      canvas.drawImageRect(source, crop, out, Paint()..filterQuality = FilterQuality.high);
    });
    final masked = maskPaints(ops);
    return ImageInput(
      image: image,
      strength: strength,
      mask: masked ? await render((c) => maskInto(c, Colors.black, Colors.white)) : null,
      keepMask: masked ? await render((c) => maskInto(c, Colors.white, Colors.black)) : null,
    );
  } finally {
    source.dispose();
    codec.dispose();
  }
}

// ---------------------------------------------------------------- preview

/// The picture with [ops] over it, small: what the remix will start from.
class MaskPreview extends StatelessWidget {
  const MaskPreview({super.key, required this.path, required this.ops, required this.aspect});
  final String path;
  final List<MaskOp> ops;

  /// The picture's width over its height.
  final double aspect;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspect > 0 ? aspect : 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(File(path), fit: BoxFit.fill, cacheWidth: 480, gaplessPlayback: true),
            CustomPaint(painter: _MaskPainter(ops: ops)),
          ],
        ),
      ),
    );
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter({required this.ops, this.trace, this.traceErase = false});
  final List<MaskOp> ops;

  /// The outline being traced, not yet closed.
  final List<Offset>? trace;
  final bool traceErase;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint()..color = const Color(0x8C000000));
    paintMask(canvas, size, ops, maskTint);
    canvas.restore();
    final t = trace;
    if (t != null && t.length > 1) {
      final points = [for (final p in t) Offset(p.dx * size.width, p.dy * size.height)];
      final path = Path()..addPolygon(points, false);
      final color = traceErase ? Colors.white : maskTint;
      canvas.drawPath(
        Path()..addPolygon(points, true),
        Paint()..color = color.withValues(alpha: 0.18),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
      // The line back to the start that closing it will draw.
      canvas.drawLine(points.last, points.first, Paint()
        ..color = color.withValues(alpha: 0.5)
        ..strokeWidth = 1);
    }
  }

  // The ops and the trace are changed in place, so always.
  @override
  bool shouldRepaint(_MaskPainter old) => true;
}

// ---------------------------------------------------------------- editor

/// Paint where a remix should redraw the picture at [path], over the
/// picture itself. Starts from [ops]; the new mask when Done is pressed,
/// or null when it is left.
Future<List<MaskOp>?> editMask(
  BuildContext context, {
  required String path,
  required String name,
  required double aspect,
  required List<MaskOp> ops,
}) {
  return Navigator.of(context).push<List<MaskOp>>(
    PageRouteBuilder<List<MaskOp>>(
      transitionDuration: const Duration(milliseconds: 140),
      reverseTransitionDuration: const Duration(milliseconds: 100),
      pageBuilder: (_, _, _) => MaskEditor(path: path, name: name, aspect: aspect, ops: ops),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ),
  );
}

enum MaskTool { brush, trace }

/// The picture, fitted, with the mask over it in pink. One finger, a pen
/// or the mouse paints with the brush or traces round a shape (filled when
/// let go); Erase takes paint away instead. Two fingers or the wheel zoom
/// and move; so do the right and middle mouse buttons dragged. The tools
/// sit under the picture, never over it.
class MaskEditor extends StatefulWidget {
  const MaskEditor({super.key, required this.path, required this.name, required this.aspect, required this.ops});
  final String path;
  final String name;
  final double aspect;
  final List<MaskOp> ops;

  @override
  State<MaskEditor> createState() => _MaskEditorState();
}

class _MaskEditorState extends State<MaskEditor> {
  late final List<MaskOp> _ops = [...widget.ops];
  MaskTool _tool = MaskTool.brush;
  bool _erase = false;

  /// The brush's radius on screen, in logical pixels.
  double _brush = 28;
  static const double _brushMin = 3;
  static const double _brushMax = 160;

  // What is being drawn now.
  List<Offset>? _drawing;
  int? _drawingPointer;

  // Zoom and move: the fitted picture is scaled about the view's middle,
  // then moved.
  double _zoom = 1;
  Offset _pan = Offset.zero;
  static const double _maxZoom = 10;

  final Map<int, Offset> _pointers = {};
  bool _panning = false;
  Offset? _lastPan;
  double? _pinchDistance;
  double _pinchZoom = 1;
  Offset? _pinchSpot;

  Offset? _hover;
  Size _view = Size.zero;

  /// Where the picture is drawn in the view.
  Rect get _rect {
    final view = _view;
    if (view.isEmpty) return Rect.zero;
    final a = widget.aspect > 0 ? widget.aspect : 1.0;
    final fitW = math.min(view.width, view.height * a);
    final fit = Size(fitW, fitW / a);
    final c = view.center(Offset.zero) + _pan;
    return Rect.fromCenter(center: c, width: fit.width * _zoom, height: fit.height * _zoom);
  }

  Offset _toPicture(Offset local) {
    final r = _rect;
    return Offset((local.dx - r.left) / r.width, (local.dy - r.top) / r.height);
  }

  /// The mask or what is being drawn changed (in place).
  void _changed() => setState(() {});

  // ------------------------------------------------------------ zooming

  /// Zoom to [zoom], keeping the spot under [focal] where it is.
  void _zoomAt(double zoom, Offset focal) {
    zoom = zoom.clamp(1.0, _maxZoom);
    final c = _view.center(Offset.zero);
    final spot = (focal - c - _pan) / _zoom;
    setState(() {
      _zoom = zoom;
      _pan = _clampPan(focal - c - spot * zoom);
    });
  }

  Offset _clampPan(Offset pan) {
    final r = _rect;
    final reachX = math.max(0.0, (r.width - _view.width) / 2) + 40;
    final reachY = math.max(0.0, (r.height - _view.height) / 2) + 40;
    return Offset(pan.dx.clamp(-reachX, reachX), pan.dy.clamp(-reachY, reachY));
  }

  void _fit() => setState(() {
        _zoom = 1;
        _pan = Offset.zero;
      });

  // ------------------------------------------------------------ drawing

  void _start(int pointer, Offset local) {
    _drawingPointer = pointer;
    _drawing = [_toPicture(local)];
    _changed();
  }

  void _extend(Offset local) {
    final d = _drawing;
    if (d == null) return;
    final p = _toPicture(local);
    // Points closer than a pixel or so add nothing.
    final r = _rect;
    if (d.isNotEmpty) {
      final last = d.last;
      final dx = (p.dx - last.dx) * r.width;
      final dy = (p.dy - last.dy) * r.height;
      if (dx * dx + dy * dy < 2) return;
    }
    d.add(p);
    _changed();
  }

  void _finish() {
    final d = _drawing;
    _drawing = null;
    _drawingPointer = null;
    if (d == null) return;
    if (_tool == MaskTool.trace) {
      if (d.length >= 3) _ops.add(MaskOp(MaskKind.trace, erase: _erase, points: d));
    } else {
      _ops.add(MaskOp(MaskKind.stroke, erase: _erase, points: d, radius: _brush / _rect.width));
    }
    _changed();
  }

  /// Drop what is being drawn: a second finger came down to zoom.
  void _abandon() {
    _drawing = null;
    _drawingPointer = null;
    _changed();
  }

  void _undo() {
    if (_ops.isEmpty) return;
    _ops.removeLast();
    _changed();
  }

  void _clear() {
    if (_ops.isEmpty) return;
    _ops.add(const MaskOp(MaskKind.all, erase: true));
    _changed();
  }

  void _invert() {
    _ops.add(const MaskOp(MaskKind.invert));
    _changed();
  }

  void _done() => Navigator.of(context).pop(_simplified());

  /// [_ops] without whatever a later clear wiped out.
  List<MaskOp> _simplified() {
    final last = _ops.lastIndexWhere((o) => o.kind == MaskKind.all);
    return last < 0 ? [..._ops] : _ops.sublist(last);
  }

  void _resize(double factor) => setState(() => _brush = (_brush * factor).clamp(_brushMin, _brushMax));

  // ------------------------------------------------------------ pointers

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    final mouse = e.kind == PointerDeviceKind.mouse;
    if (mouse && (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton)) != 0) {
      _panning = true;
      _lastPan = e.localPosition;
      return;
    }
    if (_pointers.length == 1) {
      _start(e.pointer, e.localPosition);
    } else if (_pointers.length == 2) {
      // Two fingers: zoom and move, not paint.
      if (_drawing != null) _abandon();
      final pts = _pointers.values.toList();
      _pinchDistance = (pts[0] - pts[1]).distance;
      _pinchZoom = _zoom;
      final mid = (pts[0] + pts[1]) / 2;
      _pinchSpot = (mid - _view.center(Offset.zero) - _pan) / _zoom;
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    _hover = e.localPosition;
    if (_panning) {
      final last = _lastPan ?? e.localPosition;
      setState(() => _pan = _clampPan(_pan + (e.localPosition - last)));
      _lastPan = e.localPosition;
      return;
    }
    if (_pointers.length >= 2 && _pinchDistance != null && _pinchSpot != null) {
      final pts = _pointers.values.take(2).toList();
      final distance = (pts[0] - pts[1]).distance;
      final mid = (pts[0] + pts[1]) / 2;
      final zoom = (_pinchZoom * distance / math.max(1, _pinchDistance!)).clamp(1.0, _maxZoom);
      setState(() {
        _zoom = zoom;
        _pan = _clampPan(mid - _view.center(Offset.zero) - _pinchSpot! * zoom);
      });
      return;
    }
    if (e.pointer == _drawingPointer) _extend(e.localPosition);
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_panning && _pointers.isEmpty) {
      _panning = false;
      _lastPan = null;
      return;
    }
    if (_pointers.length < 2) {
      _pinchDistance = null;
      _pinchSpot = null;
    }
    if (e.pointer == _drawingPointer) {
      if (e is PointerCancelEvent) {
        _abandon();
      } else {
        _finish();
      }
    }
  }

  void _scroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      final dy = e.scrollDelta.dy;
      if (dy == 0) return;
      if (HardwareKeyboard.instance.isShiftPressed) {
        // Shift and the wheel: the brush size.
        _resize(dy < 0 ? 1.12 : 1 / 1.12);
      } else {
        _zoomAt(_zoom * (dy < 0 ? 1.15 : 1 / 1.15), e.localPosition);
      }
    });
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final painted = maskPaints(_ops);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.enter): _done,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyB): () => setState(() => _tool = MaskTool.brush),
        const SingleActivator(LogicalKeyboardKey.keyT): () => setState(() => _tool = MaskTool.trace),
        const SingleActivator(LogicalKeyboardKey.keyE): () => setState(() => _erase = !_erase),
        const SingleActivator(LogicalKeyboardKey.keyI): _invert,
        const SingleActivator(LogicalKeyboardKey.bracketLeft): () => _resize(1 / 1.2),
        const SingleActivator(LogicalKeyboardKey.bracketRight): () => _resize(1.2),
        const SingleActivator(LogicalKeyboardKey.digit0): _fit,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Palette.canvas,
          body: SafeArea(
            child: Column(
              children: [
                _bar(painted),
                Expanded(child: _canvas()),
                _tools(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar(bool painted) {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: Palette.panel,
        border: Border(bottom: BorderSide(color: Palette.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Tooltip(
            message: 'Leave without changing the mask (Esc)',
            child: InkWell(
              key: const ValueKey<String>('mask-cancel'),
              onTap: () => Navigator.of(context).maybePop(),
              borderRadius: BorderRadius.circular(6),
              hoverColor: Palette.hover,
              child: const SizedBox(width: 38, height: 38, child: Icon(Icons.close, size: 19, color: Palette.muted)),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Paint where to redraw', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                Text(
                  painted ? 'Only the pink part is redrawn' : 'Nothing painted: all of it is redrawn',
                  key: const ValueKey<String>('mask-status'),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: Palette.faint),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            key: const ValueKey<String>('mask-done'),
            onPressed: _done,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _canvas() {
    return LayoutBuilder(
      builder: (context, box) {
        _view = Size(box.maxWidth, box.maxHeight);
        final r = _rect;
        final hover = _hover;
        return MouseRegion(
          cursor: _tool == MaskTool.brush ? SystemMouseCursors.none : SystemMouseCursors.precise,
          onHover: (e) => setState(() => _hover = e.localPosition),
          onExit: (_) => setState(() => _hover = null),
          child: Listener(
            key: const ValueKey<String>('mask-canvas'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            onPointerSignal: _scroll,
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: r,
                    child: Image.file(
                      File(widget.path),
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                      filterQuality: _zoom > 2 ? FilterQuality.none : FilterQuality.medium,
                    ),
                  ),
                  Positioned.fromRect(
                    rect: r,
                    child: CustomPaint(
                      painter: _MaskPainter(
                        ops: [
                          ..._ops,
                          // The stroke under the finger, shown as it goes.
                          if (_drawing != null && _tool == MaskTool.brush)
                            MaskOp(MaskKind.stroke, erase: _erase, points: _drawing!, radius: _brush / r.width),
                        ],
                        trace: _tool == MaskTool.trace ? _drawing : null,
                        traceErase: _erase,
                      ),
                    ),
                  ),
                  // Where the brush would paint, under the mouse.
                  if (hover != null && _tool == MaskTool.brush)
                    Positioned(
                      left: hover.dx - _brush,
                      top: hover.dy - _brush,
                      child: IgnorePointer(
                        child: Container(
                          width: _brush * 2,
                          height: _brush * 2,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: _erase ? Colors.white : maskTint, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tools() {
    Widget icon({required Key key, required String tooltip, required IconData icon, VoidCallback? onTap}) => IconButton(
          key: key,
          tooltip: tooltip,
          onPressed: onTap,
          icon: Icon(icon, size: 20),
        );
    return Container(
      decoration: const BoxDecoration(
        color: Palette.panel,
        border: Border(top: BorderSide(color: Palette.line)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<MaskTool>(
            key: const ValueKey<String>('mask-tool'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: MaskTool.brush, icon: Icon(Icons.brush, size: 17), label: Text('Brush'), tooltip: 'Paint with a round brush (B)'),
              ButtonSegment(value: MaskTool.trace, icon: Icon(Icons.gesture, size: 17), label: Text('Trace'), tooltip: 'Trace round a shape; it fills when you let go (T)'),
            ],
            selected: {_tool},
            onSelectionChanged: (s) => setState(() => _tool = s.first),
          ),
          SegmentedButton<bool>(
            key: const ValueKey<String>('mask-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.add, size: 17), label: Text('Paint'), tooltip: 'Add to what is redrawn (E switches)'),
              ButtonSegment(value: true, icon: Icon(Icons.remove, size: 17), label: Text('Erase'), tooltip: 'Take away from what is redrawn (E switches)'),
            ],
            selected: {_erase},
            onSelectionChanged: (s) => setState(() => _erase = s.first),
          ),
          if (_tool == MaskTool.brush)
            SizedBox(
              width: 190,
              child: Row(
                children: [
                  const Tooltip(message: 'Brush size ([ and ], or Shift and the wheel)', child: Icon(Icons.circle_outlined, size: 14, color: Palette.muted)),
                  Expanded(
                    child: Slider(
                      key: const ValueKey<String>('mask-brush'),
                      value: _brush,
                      min: _brushMin,
                      max: _brushMax,
                      onChanged: (v) => setState(() => _brush = v),
                    ),
                  ),
                ],
              ),
            ),
          icon(key: const ValueKey<String>('mask-undo'), tooltip: 'Undo (Ctrl Z)', icon: Icons.undo, onTap: _ops.isEmpty ? null : _undo),
          icon(key: const ValueKey<String>('mask-invert'), tooltip: 'Swap the painted and unpainted parts (I)', icon: Icons.invert_colors, onTap: _invert),
          icon(
            key: const ValueKey<String>('mask-all'),
            tooltip: 'Paint all of it',
            icon: Icons.format_color_fill,
            onTap: () {
              _ops.add(const MaskOp(MaskKind.all));
              _changed();
            },
          ),
          icon(key: const ValueKey<String>('mask-clear'), tooltip: 'Clear the mask', icon: Icons.layers_clear_outlined, onTap: _ops.isEmpty ? null : _clear),
          if (_zoom > 1.001)
            icon(key: const ValueKey<String>('mask-fit'), tooltip: 'Fit the picture again (0)', icon: Icons.fit_screen_outlined, onTap: _fit),
        ],
      ),
    );
  }
}
