import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/backends.dart' show ImageInput;
import '../core/media_image.dart';
import '../core/models.dart' show HeatMap;
import '../theme.dart';
import 'kit.dart';

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
///
/// The same strokes make the color layer: there each carries its [color].
class MaskOp {
  const MaskOp(this.kind, {this.erase = false, this.points = const [], this.radius = 0, this.radii, this.color});
  final MaskKind kind;

  /// Takes paint away rather than adding it.
  final bool erase;
  final List<Offset> points;
  final double radius;

  /// A stroke drawn with pen pressure: the radius at each of [points], in
  /// place of the single [radius].
  final List<double>? radii;

  /// What a stroke of the color layer paints with.
  final Color? color;
}

/// What was painted in the editor: where to redraw ([ops]), and the color
/// painted into the picture first ([color]).
class MaskEdit {
  const MaskEdit(this.ops, this.color);
  final List<MaskOp> ops;
  final List<MaskOp> color;
}

/// The brush radius under pen [pressure] (0 to 1): from 1 at the lightest
/// touch up to the [brush] chosen.
double pressureRadius(double pressure, double brush) => 1 + (brush - 1) * pressure.clamp(0.0, 1.0);

/// The outline of a stroke whose radius changes along it: a circle at each
/// point, and between each two the tapering band that joins them.
Path pressurePath(List<Offset> points, List<double> radii) {
  final path = Path();
  void circle(Offset c, double r) => path.addOval(Rect.fromCircle(center: c, radius: r));
  circle(points.first, radii.first);
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1], b = points[i];
    final ra = radii[i - 1], rb = radii[i];
    circle(b, rb);
    final d = b - a;
    if (d.distance == 0) continue;
    final n = Offset(-d.dy, d.dx) / d.distance;
    // Wound the same way as the circles, or where they overlap they would
    // cancel out and leave holes.
    path.addPolygon([a - n * ra, b - n * rb, b + n * rb, a + n * ra], true);
  }
  return path;
}

/// The color of a picture's raw RGBA [pixels] at [spot], given as fractions
/// of its [width] and [height]; a spot outside it reads the nearest edge.
Color pixelColor(ByteData pixels, int width, int height, Offset spot) {
  final x = (spot.dx * width).floor().clamp(0, width - 1);
  final y = (spot.dy * height).floor().clamp(0, height - 1);
  final at = (y * width + x) * 4;
  return Color.fromARGB(255, pixels.getUint8(at), pixels.getUint8(at + 1), pixels.getUint8(at + 2));
}

/// The color a [text] like `#54763F` or `54763f` names, if it does.
Color? parseHexColor(String text) {
  final hex = text.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex, radix: 16));
}

/// [color] as `#RRGGBB`.
String hexOf(Color color) => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

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
    add.color = op.color ?? color;
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
        if (op.radii case final radii? when op.points.isNotEmpty && radii.length == op.points.length) {
          canvas.drawPath(
            pressurePath([for (final p in op.points) at(p)], [for (final r in radii) r * size.width]),
            paint..style = PaintingStyle.fill,
          );
          continue;
        }
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
/// [height] (the middle of it, if the shape changed), with [color] painted
/// into it and [ops] as a mask the same size, both as PNGs.
Future<ImageInput> prepareImageInput({
  required String path,
  required int width,
  required int height,
  required double strength,
  required List<MaskOp> ops,
  List<MaskOp> color = const [],
}) async {
  final codec = await pictureCodec(path);
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
      if (color.isEmpty) return;
      canvas.save();
      canvas.scale(width / crop.width, height / crop.height);
      canvas.translate(-crop.left, -crop.top);
      paintMask(canvas, full, color, Colors.transparent);
      canvas.restore();
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

/// The picture with [color] and [ops] over it, small: what the remix will
/// start from.
class MaskPreview extends StatelessWidget {
  const MaskPreview({super.key, required this.path, required this.ops, required this.aspect, this.version, this.color = const []});
  final String path;

  /// The picture's `MediaItem.version`, when known; read from the file
  /// otherwise. Keeps a new file of the same name from showing the old one.
  final String? version;
  final List<MaskOp> ops;

  /// What is painted into the picture, under the mask.
  final List<MaskOp> color;

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
            Image(
              image: ResizeImage.resizeIfNeeded(
                480,
                null,
                version == null ? pathImage(path) : VersionedFileImage(File(path), version: version!),
              ),
              fit: BoxFit.fill,
              gaplessPlayback: true,
            ),
            CustomPaint(painter: _MaskPainter(ops: ops, color: color)),
          ],
        ),
      ),
    );
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter({required this.ops, this.color = const [], this.showMask = true, this.trace, this.traceErase = false});
  final List<MaskOp> ops;

  /// The color layer, under the mask.
  final List<MaskOp> color;
  final bool showMask;

  /// The outline being traced, not yet closed.
  final List<Offset>? trace;
  final bool traceErase;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.isNotEmpty) paintMask(canvas, size, color, Colors.transparent);
    if (showMask) {
      canvas.saveLayer(Offset.zero & size, Paint()..color = const Color(0x8C000000));
      paintMask(canvas, size, ops, maskTint);
      canvas.restore();
    }
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

// ---------------------------------------------------------------- find

/// How finely a heat map is smoothed before it is drawn or made a mask.
const int heatSmooth = 48;

/// [heat] smoothed to [n] × [n] (bilinear), row by row from the top.
List<double> smoothHeat(HeatMap heat, [int n = heatSmooth]) {
  final g = heat.grid;
  if (g <= 0 || heat.values.length != g * g) return List<double>.filled(n * n, 0);
  double sample(double x, double y) {
    // Cell centres sit at (i + 0.5) / g.
    final fx = (x * g - 0.5).clamp(0.0, g - 1.0).toDouble();
    final fy = (y * g - 0.5).clamp(0.0, g - 1.0).toDouble();
    final x0 = fx.floor(), y0 = fy.floor();
    final x1 = math.min(x0 + 1, g - 1), y1 = math.min(y0 + 1, g - 1);
    final tx = fx - x0, ty = fy - y0;
    final top = heat.at(x0, y0) * (1 - tx) + heat.at(x1, y0) * tx;
    final bottom = heat.at(x0, y1) * (1 - tx) + heat.at(x1, y1) * tx;
    return top * (1 - ty) + bottom * ty;
  }

  return [
    for (var y = 0; y < n; y++)
      for (var x = 0; x < n; x++) sample((x + 0.5) / n, (y + 0.5) / n),
  ];
}

/// The part of the picture where [heat] reaches [threshold] (0 to 1), as
/// filled shapes for the mask: each row's runs of cells, one rectangle a
/// run, after smoothing.
List<MaskOp> heatToMask(HeatMap heat, double threshold, {bool erase = false}) {
  const n = heatSmooth;
  final smooth = smoothHeat(heat, n);
  final out = <MaskOp>[];
  for (var y = 0; y < n; y++) {
    var x = 0;
    while (x < n) {
      if (smooth[y * n + x] < threshold) {
        x++;
        continue;
      }
      final from = x;
      while (x < n && smooth[y * n + x] >= threshold) {
        x++;
      }
      final l = from / n, r = x / n, t = y / n, b = (y + 1) / n;
      out.add(MaskOp(MaskKind.trace, erase: erase, points: [Offset(l, t), Offset(r, t), Offset(r, b), Offset(l, b)]));
    }
  }
  return out;
}

/// [heat] drawn warm where a phrase fits, clear where it does not; the
/// part at or above [threshold] (what would go in the mask) outlined.
class _HeatPainter extends CustomPainter {
  _HeatPainter(this.heat, this.threshold);
  final HeatMap heat;
  final double threshold;

  @override
  void paint(Canvas canvas, Size size) {
    const n = heatSmooth;
    final smooth = smoothHeat(heat, n);
    final w = size.width / n, h = size.height / n;
    // Cells meet edge to edge; anti-aliased, their shared edges would show.
    final cell = Paint()..isAntiAlias = false;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final v = smooth[y * n + x];
        if (v < 0.05) continue;
        final color = Color.lerp(const Color(0xFFFFB04F), maskTint, v)!.withValues(alpha: 0.15 + 0.5 * v);
        canvas.drawRect(Rect.fromLTRB((x * w).floorToDouble(), (y * h).floorToDouble(), ((x + 1) * w).floorToDouble(), ((y + 1) * h).floorToDouble()), cell..color = color);
      }
    }
    final edge = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 1.5;
    bool on(int x, int y) => x >= 0 && y >= 0 && x < n && y < n && smooth[y * n + x] >= threshold;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (!on(x, y)) continue;
        final l = x * w, t = y * h;
        if (!on(x - 1, y)) canvas.drawLine(Offset(l, t), Offset(l, t + h), edge);
        if (!on(x + 1, y)) canvas.drawLine(Offset(l + w, t), Offset(l + w, t + h), edge);
        if (!on(x, y - 1)) canvas.drawLine(Offset(l, t), Offset(l + w, t), edge);
        if (!on(x, y + 1)) canvas.drawLine(Offset(l, t + h), Offset(l + w, t + h), edge);
      }
    }
  }

  @override
  bool shouldRepaint(_HeatPainter old) => old.heat != heat || old.threshold != threshold;
}

// ---------------------------------------------------------------- editor

/// Paint color into the picture at [path] and where a remix should redraw
/// it, over the picture itself. Starts from [color] and [ops]; what was
/// painted when Done is pressed, or null when it is left.
Future<MaskEdit?> editMask(
  BuildContext context, {
  required String path,
  required String name,
  required double aspect,
  required List<MaskOp> ops,
  List<MaskOp> color = const [],
  AppState? state,
  List<String> phrases = const [],
  String? find,
}) {
  return Navigator.of(context).push<MaskEdit>(
    PageRouteBuilder<MaskEdit>(
      transitionDuration: const Duration(milliseconds: 140),
      reverseTransitionDuration: const Duration(milliseconds: 100),
      pageBuilder: (_, _, _) => MaskEditor(path: path, name: name, aspect: aspect, ops: ops, color: color, state: state, phrases: phrases, find: find),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ),
  );
}

enum MaskTool { brush, trace, find }

/// Which layer is being painted: the color goes into the picture the remix
/// starts from; the mask, above it, says where to redraw.
enum MaskLayer { color, mask }

/// The picture, fitted, with the color painted on it and the mask over that
/// in pink. One finger, a pen or the mouse paints with the brush or traces
/// round a shape (filled when let go); Erase takes paint away instead. Two
/// fingers or the wheel zoom and move; so do the right and middle mouse
/// buttons dragged. The tools sit under the picture, never over it.
///
/// A pen paints with its pressure (see [pressureRadius]), and erases with
/// its side button held or its eraser. Once a pen is in use, fingers only
/// zoom and move, so a hand resting on the screen leaves no marks.
class MaskEditor extends StatefulWidget {
  const MaskEditor({
    super.key,
    required this.path,
    required this.name,
    required this.aspect,
    required this.ops,
    this.color = const [],
    this.state,
    this.phrases = const [],
    this.find,
  });
  final String path;
  final String name;
  final double aspect;
  final List<MaskOp> ops;

  /// The color layer as it was left.
  final List<MaskOp> color;

  /// For Find: what looks for a phrase in the picture. Without it there is
  /// no Find tool.
  final AppState? state;

  /// The prompt's phrases, offered to Find.
  final List<String> phrases;

  /// A phrase to start on Find with.
  final String? find;

  @override
  State<MaskEditor> createState() => _MaskEditorState();
}

class _MaskEditorState extends State<MaskEditor> {
  late final List<MaskOp> _ops = [...widget.ops];
  late final List<MaskOp> _colorOps = [...widget.color];

  /// Color comes first, unless there is a mask to go on with or a phrase to
  /// find for one.
  late MaskLayer _layer = widget.find != null || maskPaints(_ops) ? MaskLayer.mask : MaskLayer.color;

  /// The layer being painted.
  List<MaskOp> get _list => _layer == MaskLayer.color ? _colorOps : _ops;

  /// The tool in use: the color layer has only the brush.
  MaskTool get _active => _layer == MaskLayer.color ? MaskTool.brush : _tool;

  /// The last color used and those before it, kept while the app runs.
  static Color _lastColor = Colors.white;
  static final List<Color> _recent = [];
  late Color _color = _lastColor;
  late final TextEditingController _hex = TextEditingController(text: hexOf(_color));
  final FocusNode _hexFocus = FocusNode();

  /// Whether the color wheel is out, rather than folded down to the recent
  /// colors. Until chosen, it is on a wide screen.
  bool? _wheelChosen;

  void _showWheel(bool open) => setState(() => _wheelChosen = open);

  void _setColor(Color color, {bool typed = false}) {
    setState(() => _color = color);
    _lastColor = color;
    if (!typed) _hex.text = hexOf(color);
  }

  void _remember(Color color) {
    _recent
      ..remove(color)
      ..insert(0, color);
    if (_recent.length > 8) _recent.removeLast();
  }

  // The eyedropper: the picture and the paint on it, as what is picked from.
  bool _picking = false;
  ui.Image? _sample;
  ByteData? _samplePixels;
  int? _pickPointer;
  Offset? _pickAt;
  Color? _picked;

  Future<void> _startPicking() async {
    setState(() {
      _picking = true;
      _picked = null;
      _pickAt = null;
    });
    final codec = await pictureCodec(widget.path);
    final frame = await codec.getNextFrame();
    final source = frame.image;
    final width = math.min(source.width, 1024);
    final height = math.max(1, (source.height * width / source.width).round());
    final size = Size(width.toDouble(), height.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    paintMask(canvas, size, _colorOps, Colors.transparent);
    final image = await recorder.endRecording().toImage(width, height);
    final pixels = await image.toByteData();
    source.dispose();
    codec.dispose();
    if (!mounted || !_picking || pixels == null) {
      image.dispose();
      return;
    }
    _sample?.dispose();
    setState(() {
      _sample = image;
      _samplePixels = pixels;
    });
  }

  void _stopPicking() => setState(() {
        _picking = false;
        _pickPointer = null;
        _pickAt = null;
        _picked = null;
      });

  void _pick(Offset local) {
    final sample = _sample;
    final pixels = _samplePixels;
    if (sample == null || pixels == null) return;
    setState(() {
      _pickAt = local;
      _picked = pixelColor(pixels, sample.width, sample.height, _toPicture(local));
    });
  }

  void _pickDone() {
    final picked = _picked;
    if (picked == null) {
      _pickPointer = null;
      return;
    }
    _setColor(picked);
    _remember(picked);
    _stopPicking();
  }

  @override
  void dispose() {
    _hex.dispose();
    _hexFocus.dispose();
    _sample?.dispose();
    super.dispose();
  }

  // The pen.
  bool _penSeen = false;
  bool _pressure = true;
  int? _penDown;

  static bool _isPen(PointerDeviceKind kind) => kind == PointerDeviceKind.stylus || kind == PointerDeviceKind.invertedStylus;

  /// The radius [e]'s pressure asks for, or null if it has none to give.
  double? _pressed(PointerEvent e) {
    if (!_pressure || !_isPen(e.kind) || e.pressureMax <= e.pressureMin) return null;
    return pressureRadius((e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin), _brush);
  }

  /// The picture, as it is now on disk (not an older file of the same name
  /// still in the image cache).
  late final ImageProvider _picture = pathImage(widget.path);
  late MaskTool _tool = widget.find != null && widget.state != null ? MaskTool.find : MaskTool.brush;

  /// Find: the phrase looked for, where it fits, and how far out from the
  /// best spot the mask spreads (0 to 1).
  late String? _phrase = widget.find;
  HeatMap? _heat;
  String? _heatFor;
  bool _finding = false;
  String? _findError;
  double _spread = 0.45;

  double get _threshold => 1 - _spread;

  bool get _canFind => widget.state != null && widget.phrases.isNotEmpty;

  Future<void> _look(String phrase) async {
    final state = widget.state;
    if (state == null) return;
    setState(() {
      _phrase = phrase;
      _finding = true;
      _findError = null;
    });
    try {
      final heat = await state.heat(widget.path, phrase);
      if (!mounted || _phrase != phrase) return;
      setState(() {
        _heat = heat;
        _heatFor = phrase;
      });
    } catch (e) {
      if (mounted && _phrase == phrase) setState(() => _findError = '$e');
    } finally {
      if (mounted && _phrase == phrase) setState(() => _finding = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _hexFocus.addListener(() => setState(() {}));
    final find = widget.find;
    if (find != null && widget.state != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _look(find);
      });
    }
  }

  void _useHeat() {
    final heat = _heat;
    if (heat == null) return;
    final ops = heatToMask(heat, _threshold, erase: _erase);
    if (ops.isEmpty) return;
    _ops.addAll(ops);
    _changed();
  }
  bool _erase = false;

  /// The brush's radius on screen, in logical pixels.
  double _brush = 28;
  static const double _brushMin = 3;
  static const double _brushMax = 160;

  // What is being drawn now.
  List<Offset>? _drawing;
  List<double>? _drawingRadii;
  bool _drawingErase = false;
  double _drawingRadius = 0;
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

  void _start(PointerDownEvent e) {
    final radius = _pressed(e);
    _drawingPointer = e.pointer;
    _drawing = [_toPicture(e.localPosition)];
    _drawingRadii = radius == null ? null : [radius / _rect.width];
    _drawingRadius = radius ?? _brush;
    _drawingErase = _erase ||
        e.kind == PointerDeviceKind.invertedStylus ||
        (_isPen(e.kind) && (e.buttons & kPrimaryStylusButton) != 0);
    _changed();
  }

  void _extend(PointerEvent e) {
    final local = e.localPosition;
    final radius = _pressed(e);
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
    if (radius != null) {
      // Eased, so a jitter of the pen does not show as lumps in the line.
      _drawingRadius += (radius - _drawingRadius) * 0.5;
      _drawingRadii?.add(_drawingRadius / r.width);
    }
    _changed();
  }

  /// The stroke being drawn, or finished.
  MaskOp _stroke(List<Offset> points) => MaskOp(
        MaskKind.stroke,
        erase: _drawingErase,
        points: points,
        radius: _brush / _rect.width,
        radii: _drawingRadii,
        color: _layer == MaskLayer.color ? _color : null,
      );

  void _finish() {
    final d = _drawing;
    _drawing = null;
    _drawingPointer = null;
    if (d == null) return;
    if (_active == MaskTool.trace) {
      if (d.length >= 3) _ops.add(MaskOp(MaskKind.trace, erase: _drawingErase, points: d));
    } else {
      _list.add(_stroke(d));
      if (_layer == MaskLayer.color && !_drawingErase) _remember(_color);
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
    if (_list.isEmpty) return;
    _list.removeLast();
    _changed();
  }

  void _clear() {
    if (_list.isEmpty) return;
    _list.add(const MaskOp(MaskKind.all, erase: true));
    _changed();
  }

  void _invert() {
    _ops.add(const MaskOp(MaskKind.invert));
    _changed();
  }

  void _done() => Navigator.of(context).pop(MaskEdit(_simplified(_ops), _simplified(_colorOps)));

  /// [ops] without whatever a later clear wiped out.
  List<MaskOp> _simplified(List<MaskOp> ops) {
    final last = ops.lastIndexWhere((o) => o.kind == MaskKind.all);
    return last < 0 ? [...ops] : ops.sublist(last);
  }

  void _resize(double factor) => setState(() => _brush = (_brush * factor).clamp(_brushMin, _brushMax));

  // ------------------------------------------------------------ pointers

  void _down(PointerDownEvent e) {
    if (_isPen(e.kind)) {
      // The pen wins: whatever a resting hand began is dropped.
      if (!_penSeen) setState(() => _penSeen = true);
      if (_drawing != null) _abandon();
      _pointers.clear();
      _panning = false;
      _lastPan = null;
      _pinchDistance = null;
      _pinchSpot = null;
      _penDown = e.pointer;
      if (_picking) {
        _pickPointer = e.pointer;
        _pick(e.localPosition);
      } else if (_active != MaskTool.find) {
        _hover = e.localPosition;
        _start(e);
      }
      return;
    }
    // A hand on the screen while the pen draws.
    if (_penDown != null) return;
    if (_picking) {
      _pickPointer = e.pointer;
      _pick(e.localPosition);
      return;
    }
    _pointers[e.pointer] = e.localPosition;
    final mouse = e.kind == PointerDeviceKind.mouse;
    if (mouse && (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton)) != 0) {
      _panning = true;
      _lastPan = e.localPosition;
      return;
    }
    if (_pointers.length == 1) {
      if (_penSeen && e.kind == PointerDeviceKind.touch) {
        // The pen paints: a finger only moves the picture.
        _panning = true;
        _lastPan = e.localPosition;
        return;
      }
      // Find marks by its button, not by drawing.
      if (_active != MaskTool.find) _start(e);
    } else if (_pointers.length == 2) {
      // Two fingers: zoom and move, not paint.
      _panning = false;
      _lastPan = null;
      if (_drawing != null) _abandon();
      final pts = _pointers.values.toList();
      _pinchDistance = (pts[0] - pts[1]).distance;
      _pinchZoom = _zoom;
      final mid = (pts[0] + pts[1]) / 2;
      _pinchSpot = (mid - _view.center(Offset.zero) - _pan) / _zoom;
    }
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer == _pickPointer) {
      _pick(e.localPosition);
      return;
    }
    if (e.pointer == _penDown) {
      _hover = e.localPosition;
      _extend(e);
      return;
    }
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
    if (e.pointer == _drawingPointer) _extend(e);
  }

  void _up(PointerEvent e) {
    if (e.pointer == _penDown) _penDown = null;
    if (e.pointer == _pickPointer) {
      if (e is PointerCancelEvent) {
        _pickPointer = null;
      } else {
        _pickDone();
      }
      return;
    }
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
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final colors = _layer == MaskLayer.color && !_picking;
    final wheel = colors && (_wheelChosen ?? wide);
    final panel = _Unfold(
      open: wheel,
      axis: wide ? Axis.horizontal : Axis.vertical,
      alignment: wide ? Alignment.centerLeft : Alignment.topCenter,
      child: _colorPanel(wide: wide),
    );
    final rail = _Unfold(
      open: colors && !wheel && _recent.isNotEmpty,
      axis: wide ? Axis.horizontal : Axis.vertical,
      alignment: wide ? Alignment.topLeft : Alignment.topCenter,
      child: _colorRail(wide: wide),
    );
    return CallbackShortcuts(
      // Letters typed into the color's hex box are for the box.
      bindings: _hexFocus.hasFocus ? const {} : {
        const SingleActivator(LogicalKeyboardKey.escape): () => _picking ? _stopPicking() : Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.enter): _done,
        const SingleActivator(LogicalKeyboardKey.keyC): () => setState(() => _layer = MaskLayer.color),
        const SingleActivator(LogicalKeyboardKey.keyM): () => setState(() => _layer = MaskLayer.mask),
        const SingleActivator(LogicalKeyboardKey.keyP): () {
          if (_layer == MaskLayer.color && !_picking) _startPicking();
        },
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyB): () => setState(() => _tool = MaskTool.brush),
        const SingleActivator(LogicalKeyboardKey.keyT): () => setState(() => _tool = MaskTool.trace),
        const SingleActivator(LogicalKeyboardKey.keyF): () {
          if (_canFind) setState(() => _tool = MaskTool.find);
        },
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
                Expanded(
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [Expanded(child: _canvas()), rail, panel],
                        )
                      : Column(children: [Expanded(child: _canvas()), rail, panel]),
                ),
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
            message: 'Leave without changing anything (Esc)',
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
                Text(_picking ? 'Pick a color' : 'Fix the picture', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                Text(
                  _picking
                      ? 'Touch the picture, slide, and let go'
                      : _layer == MaskLayer.color
                      ? 'Color: painted into the picture the remix starts from'
                      : _tool == MaskTool.find && _phrase != null
                      ? (_finding ? 'Finding “$_phrase”…' : (_findError ?? 'Found: where “$_phrase” fits best'))
                      : (painted ? 'Mask: only the pink part is redrawn' : 'Mask: nothing painted, so all of it is redrawn'),
                  key: const ValueKey<String>('mask-status'),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: Palette.faint),
                ),
              ],
            ),
          ),
          if (_picking)
            OutlinedButton(
              key: const ValueKey<String>('mask-pick-cancel'),
              onPressed: _stopPicking,
              child: const Text('Cancel'),
            )
          else
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
        final hover = _picking ? null : _hover;
        final brushing = _active == MaskTool.brush;
        final ring = _drawing != null && _drawingRadii != null ? _drawingRadius : _brush;
        final pickAt = _pickAt;
        final sample = _sample;
        return MouseRegion(
          cursor: brushing && !_picking ? SystemMouseCursors.none : SystemMouseCursors.precise,
          onHover: (e) => setState(() => _hover = e.localPosition),
          onExit: (_) => setState(() => _hover = null),
          child: Listener(
            key: const ValueKey<String>('mask-canvas'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            // Mice are seen by the region above; a pen held over the screen
            // only by this.
            onPointerHover: (e) {
              if (_isPen(e.kind)) setState(() => _hover = e.localPosition);
            },
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            onPointerSignal: _scroll,
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: r,
                    child: Image(
                      image: _picture,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                      filterQuality: _zoom > 2 ? FilterQuality.none : FilterQuality.medium,
                    ),
                  ),
                  Positioned.fromRect(
                    rect: r,
                    child: CustomPaint(
                      painter: _MaskPainter(
                        // The stroke under the finger, shown as it goes.
                        ops: [
                          ..._ops,
                          if (_drawing != null && brushing && _layer == MaskLayer.mask) _stroke(_drawing!),
                        ],
                        color: [
                          ..._colorOps,
                          if (_drawing != null && _layer == MaskLayer.color) _stroke(_drawing!),
                        ],
                        showMask: _layer == MaskLayer.mask,
                        trace: _active == MaskTool.trace ? _drawing : null,
                        traceErase: _drawingErase,
                      ),
                    ),
                  ),
                  if (_active == MaskTool.find && _heat != null && _heatFor == _phrase)
                    Positioned.fromRect(
                      rect: r,
                      child: IgnorePointer(child: CustomPaint(painter: _HeatPainter(_heat!, _threshold))),
                    ),
                  // Where the brush would paint, under the mouse.
                  if (hover != null && brushing)
                    Positioned(
                      left: hover.dx - ring,
                      top: hover.dy - ring,
                      child: IgnorePointer(
                        child: Container(
                          width: ring * 2,
                          height: ring * 2,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _erase ? Colors.white : (_layer == MaskLayer.color ? _color : maskTint),
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // The eyedropper's loupe, above the finger so it can be
                  // seen, or below it at the top of the screen.
                  if (pickAt != null && sample != null)
                    Positioned(
                      left: pickAt.dx - 48,
                      top: pickAt.dy < 150 ? pickAt.dy + 40 : pickAt.dy - 136,
                      child: IgnorePointer(
                        child: CustomPaint(
                          key: const ValueKey<String>('mask-loupe'),
                          size: const Size.square(96),
                          painter: _LoupePainter(sample, _toPicture(pickAt), _picked ?? Colors.white),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_active == MaskTool.find) ...[_findRow(), const SizedBox(height: 8)],
          Wrap(
        spacing: 10,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<MaskLayer>(
            key: const ValueKey<String>('mask-layer'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: MaskLayer.color, icon: Icon(Icons.palette_outlined, size: 17), label: Text('Color'), tooltip: 'Paint color into the picture (C)'),
              ButtonSegment(value: MaskLayer.mask, icon: Icon(Icons.brush, size: 17), label: Text('Mask'), tooltip: 'Paint where to redraw (M)'),
            ],
            selected: {_layer},
            onSelectionChanged: (s) => setState(() {
              _layer = s.first;
              _picking = false;
            }),
          ),
          if (_layer == MaskLayer.color) ...[
            Tooltip(
              message: 'The color: tap for the wheel',
              child: InkWell(
                key: const ValueKey<String>('mask-color'),
                customBorder: const CircleBorder(),
                onTap: () => _showWheel(!(_wheelChosen ?? MediaQuery.sizeOf(context).width >= 800)),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: _color, shape: BoxShape.circle, border: Border.all(color: Palette.text, width: 2)),
                ),
              ),
            ),
            icon(key: const ValueKey<String>('mask-pick'), tooltip: 'Pick a color from the picture (P)', icon: Icons.colorize, onTap: _picking ? null : _startPicking),
          ] else SegmentedButton<MaskTool>(
            key: const ValueKey<String>('mask-tool'),
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: MaskTool.brush, icon: Icon(Icons.circle, size: 13), label: Text('Brush'), tooltip: 'Paint with a round brush (B)'),
              const ButtonSegment(value: MaskTool.trace, icon: Icon(Icons.gesture, size: 17), label: Text('Trace'), tooltip: 'Trace round a shape; it fills when you let go (T)'),
              if (_canFind)
                const ButtonSegment(
                  value: MaskTool.find,
                  icon: Icon(Icons.center_focus_strong_outlined, size: 17),
                  label: Text('Find'),
                  tooltip: 'Find where a phrase of the prompt is, or would fit (F)',
                ),
            ],
            selected: {_tool},
            onSelectionChanged: (s) {
              setState(() => _tool = s.first);
              if (s.first == MaskTool.find && _heat == null && !_finding) {
                final first = _phrase ?? (widget.phrases.isEmpty ? null : widget.phrases.first);
                if (first != null) _look(first);
              }
            },
          ),
          SegmentedButton<bool>(
            key: const ValueKey<String>('mask-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.add, size: 17), label: Text('Paint'), tooltip: 'Add paint (E switches)'),
              ButtonSegment(value: true, icon: Icon(Icons.remove, size: 17), label: Text('Erase'), tooltip: 'Take paint away (E switches)'),
            ],
            selected: {_erase},
            onSelectionChanged: (s) => setState(() => _erase = s.first),
          ),
          if (_active == MaskTool.brush)
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
          if (_penSeen && _active == MaskTool.brush)
            OutlinedButton.icon(
              key: const ValueKey<String>('mask-pressure'),
              onPressed: () => setState(() => _pressure = !_pressure),
              icon: const Icon(Icons.draw_outlined, size: 16),
              label: Text(_pressure ? 'Pen pressure: on' : 'Pen pressure: off'),
            ),
          icon(key: const ValueKey<String>('mask-undo'), tooltip: 'Undo (Ctrl Z)', icon: Icons.undo, onTap: _list.isEmpty ? null : _undo),
          if (_layer == MaskLayer.mask) ...[
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
          ],
          icon(
            key: const ValueKey<String>('mask-clear'),
            tooltip: _layer == MaskLayer.color ? 'Clear the color' : 'Clear the mask',
            icon: Icons.layers_clear_outlined,
            onTap: _list.isEmpty ? null : _clear,
          ),
          if (_zoom > 1.001)
            icon(key: const ValueKey<String>('mask-fit'), tooltip: 'Fit the picture again (0)', icon: Icons.fit_screen_outlined, onTap: _fit),
        ],
          ),
        ],
      ),
    );
  }

  /// One of the colors used lately, ringed if it is the color in use.
  Widget _recentColor(Color c) {
    return InkWell(
      key: ValueKey<String>('mask-recent-${hexOf(c)}'),
      customBorder: const CircleBorder(),
      onTap: () => _setColor(c),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: c == _color ? Border.all(color: Palette.text, width: 2) : null,
        ),
      ),
    );
  }

  /// The colors used lately, in a strip: what is left of the color panel
  /// when it is folded away. A column beside the picture on a wide screen, a
  /// row under it on a narrow one.
  Widget _colorRail({required bool wide}) {
    final colors = [
      for (final (i, c) in _recent.indexed) ...[
        if (i > 0) const SizedBox(width: 8, height: 8),
        _recentColor(c),
      ],
    ];
    return Container(
      key: const ValueKey<String>('mask-color-rail'),
      width: wide ? 52 : double.infinity,
      height: wide ? double.infinity : 52,
      decoration: BoxDecoration(
        color: Palette.panel,
        border: wide ? const Border(left: BorderSide(color: Palette.line)) : const Border(top: BorderSide(color: Palette.line)),
      ),
      child: SingleChildScrollView(
        scrollDirection: wide ? Axis.vertical : Axis.horizontal,
        padding: const EdgeInsets.all(10),
        child: wide
            ? Column(mainAxisSize: MainAxisSize.min, children: colors)
            : Row(mainAxisSize: MainAxisSize.min, children: colors),
      ),
    );
  }

  /// The color wheel, its hex value, and the colors used lately: beside the
  /// picture on a wide screen, under it on a narrow one, never over it.
  Widget _colorPanel({required bool wide}) {
    final recent = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final c in _recent) _recentColor(c)],
    );
    final collapse = Tooltip(
      message: 'Fold the wheel away',
      child: InkWell(
        key: const ValueKey<String>('mask-color-collapse'),
        customBorder: const CircleBorder(),
        onTap: () => _showWheel(false),
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(wide ? Icons.chevron_right : Icons.expand_more, size: 22, color: Palette.muted),
        ),
      ),
    );
    final hex = TextField(
      key: const ValueKey<String>('mask-hex'),
      controller: _hex,
      focusNode: _hexFocus,
      decoration: const InputDecoration(labelText: 'Hex', isDense: true, border: OutlineInputBorder()),
      onChanged: (text) {
        final color = parseHexColor(text);
        if (color != null) _setColor(color, typed: true);
      },
    );
    final disc = ColorWheel(color: _color, size: wide ? 248 : 168, onChanged: _setColor);
    return Container(
      key: const ValueKey<String>('mask-color-panel'),
      width: wide ? 280 : null,
      height: wide ? double.infinity : null,
      padding: wide ? null : const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Palette.panel,
        border: wide ? const Border(left: BorderSide(color: Palette.line)) : const Border(top: BorderSide(color: Palette.line)),
      ),
      child: wide
          ? SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(alignment: Alignment.centerRight, child: collapse),
                  Center(child: disc),
                  const SizedBox(height: 14),
                  hex,
                  const SizedBox(height: 14),
                  recent,
                ],
              ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                disc,
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [hex, const SizedBox(height: 12), recent])),
                const SizedBox(width: 4),
                collapse,
              ],
            ),
    );
  }

  /// Find: the prompt's phrases to look for, how far the mask spreads from
  /// the best spot, and the button that puts it in the mask.
  Widget _findRow() {
    final ready = _heat != null && _heatFor == _phrase && !_finding;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 34,
          child: ListView(
            key: const ValueKey<String>('mask-find-phrases'),
            scrollDirection: Axis.horizontal,
            children: [
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Center(child: Text('Find', style: TextStyle(fontSize: 12.5, color: Palette.muted))),
              ),
              for (final p in widget.phrases)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Center(
                    child: PhraseChip(
                      key: ValueKey<String>('mask-find-$p'),
                      text: p,
                      look: PhraseLook.seen,
                      selected: p == _phrase,
                      onTap: () => _look(p),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Text('Spread', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
            Expanded(
              child: Slider(
                key: const ValueKey<String>('mask-find-spread'),
                value: _spread,
                min: 0.05,
                max: 0.95,
                onChanged: (v) => setState(() => _spread = v),
              ),
            ),
            if (_finding) const Padding(padding: EdgeInsets.only(right: 10), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            OutlinedButton.icon(
              key: const ValueKey<String>('mask-find-use'),
              onPressed: ready ? _useHeat : null,
              icon: Icon(_erase ? Icons.remove : Icons.add, size: 16),
              label: Text(_erase ? 'Take from the mask' : 'Add to the mask'),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- color

/// Slides [child] out along [axis] and back, quickly, keeping it whole on
/// the way so it is seen going rather than vanishing first.
class _Unfold extends StatelessWidget {
  const _Unfold({required this.open, required this.axis, required this.alignment, required this.child});

  final bool open;
  final Axis axis;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: open ? 1 : 0),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, amount, child) {
        if (amount == 0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: alignment,
            widthFactor: axis == Axis.horizontal ? amount : null,
            heightFactor: axis == Axis.vertical ? amount : null,
            child: IgnorePointer(ignoring: !open, child: child),
          ),
        );
      },
    );
  }
}

/// The picture close up around [spot] (fractions of it), in a circle ringed
/// with the color under it.
class _LoupePainter extends CustomPainter {
  _LoupePainter(this.image, this.spot, this.color);
  final ui.Image image;
  final Offset spot;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final circle = Offset.zero & size;
    canvas.save();
    canvas.clipPath(Path()..addOval(circle));
    canvas.drawImageRect(
      image,
      Rect.fromCenter(center: Offset(spot.dx * image.width, spot.dy * image.height), width: 13, height: 13),
      circle,
      Paint()..filterQuality = FilterQuality.none,
    );
    canvas.restore();
    final middle = size.center(Offset.zero);
    canvas.drawCircle(middle, size.width / 2 - 4, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8);
    canvas.drawCircle(middle, size.width / 2 - 0.5, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke);
    canvas.drawRect(Rect.fromCenter(center: middle, width: size.width / 13, height: size.width / 13), Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_LoupePainter old) => old.image != image || old.spot != spot || old.color != color;
}

/// A hue ring round a square of saturation (across) and value (down).
class ColorWheel extends StatefulWidget {
  const ColorWheel({super.key, required this.color, required this.size, required this.onChanged});
  final Color color;
  final double size;
  final ValueChanged<Color> onChanged;

  @override
  State<ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<ColorWheel> {
  late HSVColor _hsv = HSVColor.fromColor(widget.color);

  /// Which part the drag began on: it stays there.
  bool _onRing = false;

  @override
  void didUpdateWidget(ColorWheel old) {
    super.didUpdateWidget(old);
    // Black and white have no hue of their own: keep the one chosen.
    if (widget.color != _hsv.toColor()) {
      final next = HSVColor.fromColor(widget.color);
      _hsv = next.saturation == 0 || next.value == 0 ? next.withHue(_hsv.hue) : next;
    }
  }

  void _touch(Offset local, {bool first = false}) {
    final middle = Offset(widget.size, widget.size) / 2;
    final from = local - middle;
    final geometry = _WheelGeometry(widget.size);
    if (first) _onRing = from.distance >= geometry.inner;
    if (_onRing) {
      final degrees = math.atan2(from.dy, from.dx) * 180 / math.pi;
      _hsv = _hsv.withHue((degrees + 360) % 360);
    } else {
      final side = geometry.side;
      final x = ((from.dx + side / 2) / side).clamp(0.0, 1.0);
      final y = ((from.dy + side / 2) / side).clamp(0.0, 1.0);
      _hsv = _hsv.withSaturation(x).withValue(1 - y);
    }
    setState(() {});
    widget.onChanged(_hsv.toColor());
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey<String>('mask-wheel'),
      onPanDown: (d) => _touch(d.localPosition, first: true),
      onPanUpdate: (d) => _touch(d.localPosition),
      child: CustomPaint(size: Size.square(widget.size), painter: _WheelPainter(_hsv)),
    );
  }
}

class _WheelGeometry {
  _WheelGeometry(double size)
      : outer = size / 2,
        inner = size / 2 - 22,
        side = (size / 2 - 22) * math.sqrt2 * 0.9;
  final double outer;
  final double inner;
  final double side;
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.hsv);
  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final g = _WheelGeometry(size.width);
    final middle = size.center(Offset.zero);
    final disc = Rect.fromCircle(center: middle, radius: g.outer);
    canvas.drawCircle(
      middle,
      (g.outer + g.inner) / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = g.outer - g.inner
        ..shader = SweepGradient(
          colors: [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h % 360, 1, 1).toColor()],
        ).createShader(disc),
    );
    final square = Rect.fromCenter(center: middle, width: g.side, height: g.side);
    canvas.drawRect(square, Paint()
      ..shader = LinearGradient(colors: [Colors.white, hsv.withSaturation(1).withValue(1).toColor()]).createShader(square));
    canvas.drawRect(square, Paint()
      ..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black]).createShader(square));
    final knob = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final angle = hsv.hue * math.pi / 180;
    canvas.drawCircle(middle + Offset(math.cos(angle), math.sin(angle)) * ((g.outer + g.inner) / 2), 9, knob);
    canvas.drawCircle(square.topLeft + Offset(hsv.saturation * g.side, (1 - hsv.value) * g.side), 7, knob);
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.hsv != hsv;
}
