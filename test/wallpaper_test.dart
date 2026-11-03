// Setting a picture as wallpaper: the crop for each screen, the value that
// names a screen on One UI, and the positioning screen itself.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/wallpaper.dart';
import 'package:generativeview/src/theme.dart';
import 'package:generativeview/src/ui/wallpaper_view.dart';

import 'support.dart';

const _cover = WallpaperScreen(coverScreen, 'Cover', 1248, 1972);
const _main = WallpaperScreen(mainScreen, 'Main', 1848, 2448);
const _fold = WallpaperDevice([_main, _cover], coverScreen);
const _tablet = WallpaperDevice([WallpaperScreen(onlyScreen, 'Screen', 2960, 1848)], onlyScreen);

MediaItem _picture(String path) {
  final file = File(path);
  return MediaItem(
    id: 1,
    dir: file.parent.path,
    name: file.uri.pathSegments.last,
    isVideo: false,
    width: 1024,
    height: 1536,
    mtime: 1,
    size: file.lengthSync(),
    durationMs: 0,
  );
}

Future<String> _writePicture() async {
  final dir = Directory.systemTemp.createTempSync('gv-wallpaper');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a file open while its picture is decoded; the system
      // clears its temp folder itself.
    }
  });
  const w = 64, h = 96;
  final rows = Uint8List((w * 3 + 1) * h);
  for (var y = 0; y < h; y++) {
    final row = y * (w * 3 + 1);
    for (var x = 0; x < w; x++) {
      rows[row + 1 + x * 3] = 40 + y * 2;
      rows[row + 2 + x * 3] = 30 + x;
      rows[row + 3 + x * 3] = 110;
    }
  }
  final file = File('${dir.path}/ridge.png')..writeAsBytesSync(pngFromRows(w, h, rows));
  return file.path;
}

void main() {
  setUpAll(loadAppFonts);

  group('crop', () {
    test('a narrower screen takes the whole height', () {
      final crop = wallpaperCrop(1024, 1536, _cover, const WallpaperView());
      expect(crop.height, 1536);
      expect(crop.width, closeTo(972, 1));
      expect(crop.center.dx, closeTo(512, 0.01));
    });

    test('a wider screen takes the whole width', () {
      final crop = wallpaperCrop(1024, 1536, _main, const WallpaperView());
      expect(crop.width, 1024);
      expect(crop.height, closeTo(1356, 1));
    });

    test('stays inside the picture however far it is dragged', () {
      final crop = wallpaperCrop(1024, 1536, _main, const WallpaperView(cx: 5, cy: 5, zoom: 2));
      expect(crop.right, closeTo(1024, 0.01));
      expect(crop.bottom, closeTo(1536, 0.01));
      expect(crop.width, 512);
    });
  });

  test('which names the screen with the values the Fold 8 records', () {
    expect(wallpaperWhich(WallpaperUse.home, mainScreen), 5);
    expect(wallpaperWhich(WallpaperUse.lock, mainScreen), 6);
    expect(wallpaperWhich(WallpaperUse.both, mainScreen), 7);
    expect(wallpaperWhich(WallpaperUse.home, coverScreen), 17);
    expect(wallpaperWhich(WallpaperUse.lock, coverScreen), 18);
    expect(wallpaperWhich(WallpaperUse.both, coverScreen), 19);
    expect(wallpaperWhich(WallpaperUse.both, onlyScreen), 3);
  });

  test('device reports are read, and nonsense is not', () {
    final fold = WallpaperDevice.fromMap({
      'current': 'cover', 'mainWidth': 1848, 'mainHeight': 2448, 'coverWidth': 1248, 'coverHeight': 1972,
    })!;
    expect(fold.hasCover, isTrue);
    expect(fold.current, coverScreen);
    final tablet = WallpaperDevice.fromMap({'current': 'screen', 'width': 2960, 'height': 1848})!;
    expect(tablet.hasCover, isFalse);
    expect(WallpaperDevice.fromMap({'current': 'cover'}), isNull);
  });

  Future<List<WallpaperWrite>> pumpPage(
    WidgetTester tester, {
    required WallpaperDevice device,
    required Size size,
    required String shot,
    List<bool> Function(int count)? answer,
    Future<void> Function()? act,
  }) async {
    final path = await tester.runAsync(_writePicture);
    final item = _picture(path!);
    final written = <WallpaperWrite>[];
    final boundary = GlobalKey();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: WallpaperPage(
            item: item,
            device: device,
            onUpscale: (_) {},
            write: (_, writes) async {
              written.addAll(writes);
              return answer?.call(writes.length) ?? List.filled(writes.length, true);
            },
          ),
        ),
      ),
    );
    // The picture decodes on real time but its steps run on the test's
    // clock, so the two take turns.
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    await act?.call();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await screenshot(tester, boundary, shot);
    return written;
  }

  testWidgets('starts on the screen in use and writes only that one', (tester) async {
    final written = await pumpPage(
      tester,
      device: _fold,
      size: const Size(416, 658),
      shot: '60-wallpaper-cover',
    );
    expect(find.text('Screen'), findsOneWidget);
    expect(find.textContaining('Cover: uses 972 × 1536'), findsOneWidget);
    expect(written, isEmpty);
    await tester.tap(find.text('Set wallpaper'));
    await tester.pump();
    expect(written.single.which, 19);
    expect(written.single.active, isTrue);
  });

  testWidgets('both screens get a crop each', (tester) async {
    final written = await pumpPage(
      tester,
      device: _fold,
      size: const Size(416, 658),
      shot: '61-wallpaper-both',
      act: () async {
        await tester.tap(find.text('Both').first);
        await tester.pump();
      },
    );
    expect(find.text('Main screen'), findsOneWidget);
    expect(find.text('Cover screen'), findsOneWidget);
    await tester.tap(find.text('Set wallpaper'));
    await tester.pump();
    expect([for (final w in written) w.which], [7, 19]);
    expect(written[0].crop.width, isNot(closeTo(written[1].crop.width, 1)));
  });

  testWidgets('dragging moves only the crop of the screen dragged', (tester) async {
    final written = await pumpPage(
      tester,
      device: _fold,
      size: const Size(616, 816),
      shot: '62-wallpaper-unfolded',
      act: () async {
        await tester.tap(find.text('Lock'));
        await tester.pump();
        await tester.tap(find.text('Main'));
        await tester.pump();
        await tester.drag(find.byType(Image).last, const Offset(0, -60));
        await tester.pump();
      },
    );
    await tester.tap(find.text('Set wallpaper'));
    await tester.pump();
    expect(written.single.which, 6);
    expect(written.single.crop.top, greaterThan(90));
  });

  testWidgets('a tablet has no screen choice, and a sideways side panel', (tester) async {
    await pumpPage(tester, device: _tablet, size: const Size(1280, 800), shot: '63-wallpaper-tablet');
    expect(find.text('Screen'), findsNothing);
    expect(find.textContaining('This screen is 2960 × 1848'), findsOneWidget);
    expect(find.text('Upscale…'), findsOneWidget);
  });

  testWidgets('a failed write keeps the screen open and says so', (tester) async {
    await pumpPage(
      tester,
      device: _tablet,
      size: const Size(1280, 800),
      shot: '64-wallpaper-failed',
      answer: (count) => List.filled(count, false),
    );
    await tester.tap(find.text('Set wallpaper'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Could not set the wallpaper'), findsOneWidget);
    expect(find.text('Set as wallpaper'), findsOneWidget);
  });
}
