// Screenshots of the app showing a folder of real generated images. Skipped
// unless GV_SAMPLE_DIR points at one (CI uses the ComfyUI examples
// repository) and GV_SCREENSHOT_DIR says where to put the pictures.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/ui/media_grid.dart';

import 'support.dart';

void main() {
  final samples = Platform.environment['GV_SAMPLE_DIR'] ?? '';
  final skip = samples.isEmpty || !Directory(samples).existsSync();

  testWidgets('real images: grid, search, metadata, focus', skip: skip, (tester) async {
    await tester.runAsync(loadAppFonts);
    final scratch = Directory.systemTemp.createTempSync('gv-gallery-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final core = NativeCore.start(
      dataDir: '${scratch.path}/data',
      cacheDir: '${scratch.path}/cache',
      libraryPath: coreLibraryPath(),
    );
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boundary = GlobalKey();
    final state = AppState(core: core, thumbs: ThumbCache(core, maxBytes: 256 << 20));
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: GenerativeViewApp(state: state)));
    var opened = false;
    state.restore(initialFolder: samples).whenComplete(() => opened = true);
    await pumpUntil(tester, () => opened, what: 'the folder to open');

    int shown() => tester
        .widgetList<RawImage>(find.descendant(of: find.byType(MediaGrid), matching: find.byType(RawImage)))
        .where((w) => w.image != null)
        .length;
    int tiles() => find.descendant(of: find.byType(MediaGrid), matching: find.byType(RawImage)).evaluate().length +
        0;

    // Indexing and thumbnailing ~130 real 1-2 MB images.
    final started = DateTime.now();
    await pumpUntil(
      tester,
      () => !state.scan.value.running && state.items.length > 100 && shown() >= 30,
      what: 'real thumbnails',
      timeout: const Duration(minutes: 3),
    );
    // Not a benchmark (debug-mode test harness on a CI VM), just a sanity figure.
    debugPrint('GALLERY: ${state.items.length} items, $shown() first thumbnails after ${DateTime.now().difference(started).inMilliseconds} ms; tiles=${tiles()}');
    if (state.leftOpen) state.toggleLeft();
    state.setTileSize(210);
    await pumpUntil(tester, () => shown() >= 35, what: 'a full screen of thumbnails', timeout: const Duration(minutes: 2));
    await screenshot(tester, boundary, '10-real-grid');

    final search = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search prompts, models, names');
    await tester.enterText(search, 'fennec model:flux');
    await pumpUntil(tester, () => state.items.length < 40 && state.items.isNotEmpty && shown() >= state.items.length.clamp(1, 12), what: 'search results');
    debugPrint('GALLERY: "fennec model:flux" -> ${state.items.length} items');
    state.select(0);
    if (!state.rightOpen) state.toggleRight();
    await pumpUntil(tester, () => find.text('PROMPT').evaluate().isNotEmpty, what: 'metadata');
    await pumpUntil(tester, () => shown() >= state.items.length.clamp(1, 9), what: 'results thumbnails');
    await screenshot(tester, boundary, '11-real-search-metadata');

    state.openFocus(0);
    await pumpUntil(
      tester,
      () => tester.widgetList<RawImage>(find.descendant(of: find.byType(Image), matching: find.byType(RawImage))).any((w) => w.image != null),
      what: 'the full image',
      timeout: const Duration(minutes: 1),
    );
    await screenshot(tester, boundary, '12-real-focus');

    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump(const Duration(seconds: 5));
  });
}
