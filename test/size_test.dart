// Remix sizes: only multiples of 16 (what Krea 2 and FLUX insist on, and
// SD takes), in the picture's shape.
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/ui/remix_dialog.dart';

void main() {
  test('a size is rounded to a multiple of 16', () {
    expect(snapSize(194), 192);
    expect(snapSize(1497), 1504);
    expect(snapSize(1216), 1216);
    expect(snapSize(3), 16, reason: 'never nothing');
  });

  test('the slider stops only at sizes every server takes, in the shape asked', () {
    final stops = sizeStops(832 / 1216);
    expect(stops, isNotEmpty);
    for (final (w, h) in stops) {
      expect(w % 16, 0);
      expect(h % 16, 0);
      expect(h, greaterThan(w), reason: 'upright, as the picture is');
      expect(w / h, closeTo(832 / 1216, 0.05));
    }
    expect(stops.toSet(), hasLength(stops.length), reason: 'each size once');
    expect(stops, contains((832, 1216)), reason: 'the picture\'s own size is a stop');
    expect(stops.first.$2, 256);
    expect(stops.last.$2, 2048);
  });

  test('a picture bigger than the usual range is still in reach', () {
    final stops = sizeStops(1, keep: (3072, 3072));
    expect(stops.last, (3072, 3072));
  });
}
