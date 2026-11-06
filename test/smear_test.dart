import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/smear.dart';

/// A picture red on the left half, blue on the right.
Uint8List halves(int width, int height) {
  final out = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    final left = i % width < width / 2;
    out[i * 4] = left ? 255 : 0;
    out[i * 4 + 2] = left ? 0 : 255;
    out[i * 4 + 3] = 255;
  }
  return out;
}

int red(Uint8List pixels, int width, int x, int y) => pixels[(y * width + x) * 4];

void main() {
  test('a stroke drags color over the edge and blurs it, and nothing else moves', () {
    final pixels = halves(100, 100);
    final smear = SmearCanvas(pixels, 100, 100)..begin(30, 50, 12, 0.9);
    smear.to(70, 50, 12, 0.9);

    expect(red(pixels, 100, 60, 50), greaterThan(40), reason: 'red carried into the blue');
    expect(red(pixels, 100, 60, 50), lessThan(255), reason: 'and mixed with it');
    expect(red(pixels, 100, 60, 10), 0, reason: 'blue out of reach is left alone');
    expect(red(pixels, 100, 10, 50), 255, reason: 'red behind the stroke is left alone');
  });

  test('pressing harder drags further', () {
    int after(double strength) {
      final pixels = halves(100, 100);
      SmearCanvas(pixels, 100, 100)
        ..begin(30, 50, 12, strength)
        ..to(70, 50, 12, strength);
      return red(pixels, 100, 60, 50);
    }

    expect(after(0.9), greaterThan(after(0.3)));
  });

  test('the patch covers only what the stroke touched, and a new stroke starts it over', () {
    final pixels = halves(100, 100);
    final smear = SmearCanvas(pixels, 100, 100)..begin(50, 50, 5, 0.8);
    expect(smear.patch(), isNull, reason: 'nothing moved yet');

    smear.to(60, 50, 5, 0.8);
    final patch = smear.patch()!;
    expect(patch.left, lessThanOrEqualTo(46));
    expect(patch.width, lessThan(30));
    expect(patch.height, lessThan(15));
    expect(patch.pixels[3], 0, reason: 'the corner of the box was never reached');

    smear.begin(10, 10, 5, 0.8);
    expect(smear.patch(), isNull);
  });

  test('a stroke off the edge of the picture is safe and brings no black in', () {
    final pixels = halves(40, 40);
    SmearCanvas(pixels, 40, 40)
      ..begin(-5, 20, 8, 1)
      ..to(10, 20, 8, 1);
    expect(red(pixels, 40, 5, 20), greaterThan(200));
  });
}
