// The mask painted for image to image: whether it paints anything, and how
// the picture is cropped to a new shape (the mask is cropped the same way).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:ui' as ui show Image;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/ui/mask_editor.dart';

import 'support.dart';

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

  test('pen pressure runs from 1 up to the radius chosen', () {
    expect(pressureRadius(0, 25), 1);
    expect(pressureRadius(1, 25), 25);
    expect(pressureRadius(0.5, 25), 13);
    expect(pressureRadius(2, 25), 25, reason: 'pressing harder than the most is the most');
  });

  test('hex colors are read and written', () {
    expect(parseHexColor('#54763F'), const Color(0xFF54763F));
    expect(parseHexColor(' 54763f '), const Color(0xFF54763F));
    expect(parseHexColor('#5476'), isNull);
    expect(parseHexColor('nothing'), isNull);
    expect(hexOf(const Color(0xFF04003F)), '#04003F');
  });

  test('a spot on a picture reads its pixel, the nearest one if outside', () {
    final pixels = ByteData(8);
    pixels.setUint8(0, 10);
    pixels.setUint8(4, 200);
    expect(pixelColor(pixels, 2, 1, const Offset(0.1, 0.5)), const Color.fromARGB(255, 10, 0, 0));
    expect(pixelColor(pixels, 2, 1, const Offset(0.9, 0.5)), const Color.fromARGB(255, 200, 0, 0));
    expect(pixelColor(pixels, 2, 1, const Offset(4, -1)), const Color.fromARGB(255, 200, 0, 0));
  });

  testWidgets('a pressure stroke tapers, with no holes where its parts overlap', (tester) async {
    await tester.runAsync(() async {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      paintMask(canvas, const Size(100, 100), const [
        MaskOp(
          MaskKind.stroke,
          points: [Offset(0.1, 0.5), Offset(0.5, 0.5), Offset(0.9, 0.5)],
          radii: [0.01, 0.1, 0.25],
          color: Color(0xFF00FF00),
        ),
      ], Colors.transparent);
      final image = await recorder.endRecording().toImage(100, 100);
      final data = (await image.toByteData())!;
      int green(int x, int y) => data.getUint8((y * 100 + x) * 4 + 1);
      expect(green(50, 50), 255, reason: 'along the middle');
      expect(green(85, 50), 255, reason: 'where a band and a circle overlap');
      expect(green(85, 30), 255, reason: 'wide at the heavy end');
      expect(green(15, 40), 0, reason: 'narrow at the light end');
    });
  });

  testWidgets('color goes into the picture sent, cropped as it is, and not into the mask', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('color_layer');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/picture.png');
      await file.writeAsBytes(pngWithText(64, 64, 0, const {}));
      final input = await prepareImageInput(
        path: file.path,
        width: 64,
        height: 64,
        strength: 0.5,
        ops: const [],
        color: const [
          MaskOp(MaskKind.trace, points: [Offset(0, 0), Offset(0.5, 0), Offset(0.5, 1), Offset(0, 1)], color: Color(0xFFFF0000)),
        ],
      );
      expect(input.mask, isNull, reason: 'color alone is no mask');
      final codec = await instantiateImageCodec(input.image);
      final image = (await codec.getNextFrame()).image;
      final data = (await image.toByteData())!;
      int red(int x, int y) => data.getUint8((y * 64 + x) * 4);
      expect(red(10, 32), 255);
      expect(red(50, 32), lessThan(255));
    });

    test('a smear patch lands where it should, its soft edge keeping its color', () async {
      final done = Completer<ui.Image>();
      // Premultiplied: half covered, full red.
      decodeImageFromPixels(Uint8List.fromList([128, 0, 0, 128]), 1, 1, PixelFormat.rgba8888, done.complete);
      final patch = await done.future;
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 10, 10), Paint()..color = const Color(0xFFFFFFFF));
      paintMask(canvas, const Size(10, 10), [
        MaskOp(MaskKind.patch, image: patch, area: const Rect.fromLTWH(0, 0, 0.5, 1)),
      ], const Color(0x00000000));
      final out = await recorder.endRecording().toImage(10, 10);
      final data = (await out.toByteData())!;
      int channel(int x, int k) => data.getUint8((5 * 10 + x) * 4 + k);
      expect(channel(2, 0), greaterThan(250), reason: 'red over white');
      expect(channel(2, 1), inInclusiveRange(120, 135), reason: 'half of the white still shows');
      expect(channel(8, 1), 255, reason: 'outside the patch nothing changed');
      expect(maskPaints([MaskOp(MaskKind.patch, image: patch, area: Rect.zero)]), isTrue);
    });
  });

  group('the editor', () {
    late MaskEdit? result;
    final canvas = find.byKey(const ValueKey('mask-canvas'));
    var next = 100;

    Future<void> open(WidgetTester tester, String path) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await editMask(context, path: path, name: 'p', aspect: 1, ops: const []),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> done(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('mask-done')));
      await tester.pumpAndSettle();
    }

    /// A pen stroke across the picture, pressing from nothing to all of it.
    Future<void> penStroke(WidgetTester tester, Offset from, {int buttons = kPrimaryButton}) async {
      final pointer = next++;
      await tester.sendEventToBinding(PointerDownEvent(
        pointer: pointer,
        kind: PointerDeviceKind.stylus,
        position: from,
        buttons: buttons,
        pressure: 0,
        pressureMin: 0,
        pressureMax: 1,
      ));
      for (var i = 1; i <= 12; i++) {
        await tester.sendEventToBinding(PointerMoveEvent(
          pointer: pointer,
          kind: PointerDeviceKind.stylus,
          position: from + Offset(i * 8, 0),
          buttons: buttons,
          pressure: 1,
          pressureMin: 0,
          pressureMax: 1,
        ));
      }
      await tester.sendEventToBinding(PointerUpEvent(pointer: pointer, kind: PointerDeviceKind.stylus, position: from + const Offset(96, 0)));
      await tester.pump();
    }

    testWidgets('a pen paints color from 1 up to the brush, and fingers then leave no mark', (tester) async {
      final dir = Directory.systemTemp.createTempSync('color_layer');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/picture.png')..writeAsBytesSync(pngWithText(64, 64, 96, const {}));
      await open(tester, file.path);
      expect(find.byKey(const ValueKey('mask-color-panel')), findsOneWidget, reason: 'the wheel is out on a wide screen');

      await tester.tap(find.byKey(const ValueKey('mask-color-collapse')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mask-color-panel')), findsNothing, reason: 'folded away');
      await tester.tap(find.byKey(const ValueKey('mask-color')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mask-color-panel')), findsOneWidget, reason: 'back from the color button');

      final middle = tester.getCenter(canvas);
      await penStroke(tester, middle);
      await tester.pump();
      expect(find.byKey(const ValueKey('mask-pressure')), findsOneWidget, reason: 'offered once a pen is seen');

      // A finger alone now moves the picture and does not paint.
      await tester.dragFrom(middle, const Offset(40, 0));
      await tester.pump();

      // The side button held erases.
      await penStroke(tester, middle, buttons: kPrimaryButton | kPrimaryStylusButton);

      // A resting hand does not end a stroke.
      final pointer = next++;
      await tester.sendEventToBinding(PointerDownEvent(pointer: pointer, kind: PointerDeviceKind.stylus, position: middle, pressure: 1, pressureMin: 0, pressureMax: 1));
      await tester.sendEventToBinding(PointerDownEvent(pointer: pointer + 1, kind: PointerDeviceKind.touch, position: middle + const Offset(30, 30)));
      await tester.sendEventToBinding(PointerMoveEvent(pointer: pointer, kind: PointerDeviceKind.stylus, position: middle + const Offset(20, 0), pressure: 1, pressureMin: 0, pressureMax: 1));
      await tester.sendEventToBinding(PointerUpEvent(pointer: pointer + 1, kind: PointerDeviceKind.touch, position: middle + const Offset(30, 30)));
      await tester.sendEventToBinding(PointerUpEvent(pointer: pointer, kind: PointerDeviceKind.stylus, position: middle + const Offset(20, 0)));
      await tester.pump();

      await done(tester);
      final color = result!.color;
      expect(result!.ops, isEmpty, reason: 'the mask was not touched');
      expect(color, hasLength(3), reason: 'two strokes and the one with a hand down; nothing from the finger');
      final radii = color.first.radii!;
      final brush = color.first.radius;
      expect(radii.first / brush, closeTo(1 / 28, 0.001), reason: 'radius 1 of a 28 brush at the lightest touch');
      expect(radii.last, greaterThan(brush * 0.9));
      expect(radii.every((r) => r <= brush), isTrue, reason: 'never past the brush');
      expect(color.first.erase, isFalse);
      expect(color[1].erase, isTrue, reason: 'side button');
    });

    testWidgets('a mask painted on its layer stays out of the color, and the eyedropper picks', (tester) async {
      final dir = Directory.systemTemp.createTempSync('color_layer');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/picture.png')..writeAsBytesSync(pngWithText(64, 64, 96, const {}));
      await open(tester, file.path);
      final middle = tester.getCenter(canvas);

      await tester.enterText(find.byKey(const ValueKey('mask-hex')), '#112233');
      await tester.pump();
      await tester.dragFrom(middle, const Offset(40, 0));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('mask-pick')));
      // The picture is decoded and read back a step at a time.
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump();
      }
      final gesture = await tester.startGesture(middle + const Offset(-100, -100));
      await tester.pump();
      expect(find.byKey(const ValueKey('mask-loupe')), findsOneWidget);
      await gesture.up();
      await tester.pump();
      final hex = tester.widget<TextField>(find.byKey(const ValueKey('mask-hex'))).controller!.text;
      expect(hex, isNot('#112233'), reason: 'picked from the picture');

      await tester.tap(find.text('Mask'));
      await tester.pump();
      await tester.dragFrom(middle, const Offset(40, 0));
      await tester.pump();
      await done(tester);
      expect(result!.color.single.color, const Color(0xFF112233));
      expect(result!.ops, hasLength(1));
      expect(result!.ops.single.color, isNull);
    });
  });
}
