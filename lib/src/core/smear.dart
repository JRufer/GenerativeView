import 'dart:math' as math;
import 'dart:typed_data';

/// The part of a picture a smear changed, as premultiplied RGBA: clear
/// wherever the brush never went.
class SmearPatch {
  const SmearPatch(this.pixels, this.left, this.top, this.width, this.height);
  final Uint8List pixels;
  final int left;
  final int top;
  final int width;
  final int height;
}

/// Drags color across [pixels] (RGBA, [width] × [height]) in place.
///
/// The brush carries a small soft copy of what is under it, lays that down
/// as it moves, and picks up a little of what it crosses, so colors pull
/// along the stroke and blur together. Strength (0 to 1) says how much of
/// what is carried goes down and how far it travels.
class SmearCanvas {
  SmearCanvas(this.pixels, this.width, this.height) : _touched = Uint8List(width * height);

  final Uint8List pixels;
  final int width;
  final int height;

  /// How much of each pixel the stroke reached.
  final Uint8List _touched;

  /// Cells to a side of what the brush carries. Fixed, so a big brush costs
  /// no more here, and is softer for it.
  static const int _cells = 48;
  final Float32List _carried = Float32List(_cells * _cells * 3);
  final Float32List _blurred = Float32List(_cells * _cells * 3);

  double _x = 0;
  double _y = 0;
  double _radius = 1;
  double _strength = 0;

  // What the stroke has touched: inclusive, empty while right is below left.
  int _left = 0;
  int _top = 0;
  int _right = -1;
  int _bottom = -1;

  /// Start a stroke at ([x], [y]): the brush fills with what is there.
  void begin(double x, double y, double radius, double strength) {
    _clearTouched();
    _x = x;
    _y = y;
    _radius = math.max(1, radius);
    _strength = strength;
    _load(x, y, _radius, 1);
  }

  /// Carry the stroke on to ([x], [y]), easing to [radius] and [strength].
  void to(double x, double y, double radius, double strength) {
    radius = math.max(1, radius);
    final dx = x - _x;
    final dy = y - _y;
    final spacing = math.max(1.0, math.min(_radius, radius) / 4);
    final steps = math.max(1, (math.sqrt(dx * dx + dy * dy) / spacing).ceil());
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      _dab(_x + dx * t, _y + dy * t, _radius + (radius - _radius) * t, _strength + (strength - _strength) * t);
    }
    _x = x;
    _y = y;
    _radius = radius;
    _strength = strength;
  }

  /// What this stroke changed so far, or null if nothing yet.
  SmearPatch? patch() {
    if (_right < _left || _bottom < _top) return null;
    final w = _right - _left + 1;
    final h = _bottom - _top + 1;
    final out = Uint8List(w * h * 4);
    var o = 0;
    for (var y = _top; y <= _bottom; y++) {
      var from = (y * width + _left) * 4;
      var touched = y * width + _left;
      for (var x = 0; x < w; x++, from += 4, touched++, o += 4) {
        final alpha = _touched[touched];
        if (alpha == 0) continue;
        out[o] = pixels[from] * alpha ~/ 255;
        out[o + 1] = pixels[from + 1] * alpha ~/ 255;
        out[o + 2] = pixels[from + 2] * alpha ~/ 255;
        out[o + 3] = alpha;
      }
    }
    return SmearPatch(out, _left, _top, w, h);
  }

  void _clearTouched() {
    if (_right >= _left && _bottom >= _top) {
      for (var y = _top; y <= _bottom; y++) {
        _touched.fillRange(y * width + _left, y * width + _right + 1, 0);
      }
    }
    _left = width;
    _top = height;
    _right = -1;
    _bottom = -1;
  }

  /// Pick up from around ([x], [y]), and lay down what is carried.
  void _dab(double x, double y, double radius, double strength) {
    final left = math.max(0, (x - radius).floor());
    final right = math.min(width - 1, (x + radius).ceil());
    final top = math.max(0, (y - radius).floor());
    final bottom = math.min(height - 1, (y + radius).ceil());
    if (right < left || bottom < top) return;

    // Picked up before laying down, or the brush only ever meets its own
    // paint and pushes a color along without mixing it. A firm stroke holds
    // on to what it carries and takes it further.
    _load(x, y, radius, 0.16 + 0.2 * (1 - strength));
    _soften();

    final reach = radius * radius;
    final scale = (_cells - 1) / (2 * radius);
    final carried = _carried;
    for (var py = top; py <= bottom; py++) {
      final dy = py - y;
      for (var px = left; px <= right; px++) {
        final dx = px - x;
        final d = (dx * dx + dy * dy) / reach;
        if (d >= 1) continue;
        final soft = 1 - d;
        final amount = soft * strength;

        final u = ((dx + radius) * scale).clamp(0.0, _cells - 1.001);
        final v = ((dy + radius) * scale).clamp(0.0, _cells - 1.001);
        final cu = u.toInt();
        final cv = v.toInt();
        final fu = u - cu;
        final fv = v - cv;
        final a = (cv * _cells + cu) * 3;
        final b = a + 3;
        final c = a + _cells * 3;
        final e = c + 3;
        final o = (py * width + px) * 4;
        for (var k = 0; k < 3; k++) {
          final near = carried[a + k] + (carried[b + k] - carried[a + k]) * fu;
          final far = carried[c + k] + (carried[e + k] - carried[c + k]) * fu;
          final color = near + (far - near) * fv;
          final was = pixels[o + k];
          pixels[o + k] = (was + (color - was) * amount + 0.5).toInt();
        }

        final at = py * width + px;
        // A soft rim, so the patch melts into a sharper picture beneath it.
        final reached = math.min(255, (soft * 1020).toInt());
        if (reached > _touched[at]) _touched[at] = reached;
      }
    }
    _left = math.min(_left, left);
    _top = math.min(_top, top);
    _right = math.max(_right, right);
    _bottom = math.max(_bottom, bottom);
  }

  /// Blend [amount] of the picture around ([x], [y]) into what is carried.
  void _load(double x, double y, double radius, double amount) {
    final step = 2 * radius / (_cells - 1);
    var i = 0;
    for (var cv = 0; cv < _cells; cv++) {
      final py = (y - radius + cv * step).round().clamp(0, height - 1);
      for (var cu = 0; cu < _cells; cu++, i += 3) {
        final px = (x - radius + cu * step).round().clamp(0, width - 1);
        final o = (py * width + px) * 4;
        for (var k = 0; k < 3; k++) {
          _carried[i + k] += (pixels[o + k] - _carried[i + k]) * amount;
        }
      }
    }
  }

  /// A little blur of what is carried, which is what melts colors together.
  void _soften() {
    void pass(Float32List from, Float32List to, int step, int line) {
      for (var i = 0; i < from.length; i += 3) {
        final cell = i ~/ 3;
        final along = step == 3 ? cell % _cells : cell ~/ _cells;
        final before = along == 0 ? i : i - step;
        final after = along == line ? i : i + step;
        for (var k = 0; k < 3; k++) {
          to[i + k] = (from[before + k] + 2 * from[i + k] + from[after + k]) / 4;
        }
      }
    }

    pass(_carried, _blurred, 3, _cells - 1);
    pass(_blurred, _carried, _cells * 3, _cells - 1);
  }
}
