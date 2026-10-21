// The mask painted for image to image: whether it paints anything, and how
// the picture is cropped to a new shape (the mask is cropped the same way).
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/ui/mask_editor.dart';

void main() {
  const dot = MaskOp(MaskKind.stroke, points: [Offset(0.5, 0.5)], radius: 0.1);

  test('a mask paints when something is left painted', () {
    expect(maskPaints(const []), isFalse);
    expect(maskPaints(const [dot]), isTrue);
    expect(maskPaints(const [MaskOp(MaskKind.stroke, erase: true, points: [Offset(0.5, 0.5)], radius: 0.1)]), isFalse,
        reason: 'erasing nothing paints nothing');
    expect(maskPaints(const [dot, MaskOp(MaskKind.all, erase: true)]), isFalse, reason: 'cleared');
    expect(maskPaints(const [MaskOp(MaskKind.all, erase: true), MaskOp(MaskKind.invert)]), isTrue,
        reason: 'nothing, swapped, is everything');
  });

  test('a new shape takes the middle of the picture', () {
    const square = Size(1024, 1024);
    expect(coverRect(square, 512, 512), const Rect.fromLTWH(0, 0, 1024, 1024));
    expect(coverRect(square, 1024, 512), const Rect.fromLTWH(0, 256, 1024, 512));
    expect(coverRect(square, 512, 1024), const Rect.fromLTWH(256, 0, 512, 1024));
    // The same shape a few pixels out (rounded to eights) is all of it.
    expect(coverRect(const Size(832, 1216), 832, 1216), const Rect.fromLTWH(0, 0, 832, 1216));
  });

  testWidgets('the mask is drawn as the picture is: white where it is redrawn', (tester) async {
    await tester.runAsync(() async {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 10, 10), Paint()..color = const Color(0xFF000000));
      paintMask(canvas, const Size(10, 10), const [
        MaskOp(MaskKind.trace, points: [Offset(0, 0), Offset(0.5, 0), Offset(0.5, 1), Offset(0, 1)]),
      ], const Color(0xFFFFFFFF));
      final image = await recorder.endRecording().toImage(10, 10);
      final data = (await image.toByteData())!;
      int red(int x, int y) => data.getUint8((y * 10 + x) * 4);
      expect(red(1, 5), 255, reason: 'inside the traced half');
      expect(red(8, 5), 0, reason: 'outside it');
    });
  });
}
