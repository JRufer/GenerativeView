// Screenshots of the app showing a folder of real generated images. Skipped
// unless GV_SAMPLE_DIR points at one (CI uses the ComfyUI examples
// repository) and GV_SCREENSHOT_DIR says where to put the pictures.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show debugDisableShadows;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/ui/media_grid.dart';
import 'package:generativeview/src/ui/prompt_editor.dart';

import 'support.dart';

void main() {
  final samples = Platform.environment['GV_SAMPLE_DIR'] ?? '';
  final skip = samples.isEmpty || !Directory(samples).existsSync();

  testWidgets('real images: grid, search, metadata, focus', skip: skip, (
    tester,
  ) async {
    await tester.runAsync(loadAppFonts);
    // Real shadows in the pictures, not the test framework's outlines.
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
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
    final state = AppState(
      core: core,
      thumbs: ThumbCache(core, maxBytes: 256 << 20),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: GenerativeViewApp(state: state),
      ),
    );
    var opened = false;
    state.restore(initialFolder: samples).whenComplete(() => opened = true);
    await pumpUntil(tester, () => opened, what: 'the folder to open');

    int shown() => tester
        .widgetList<RawImage>(
          find.descendant(
            of: find.byType(MediaGrid),
            matching: find.byType(RawImage),
          ),
        )
        .where((w) => w.image != null)
        .length;

    // Indexing and thumbnailing ~130 real 1-2 MB images.
    final started = DateTime.now();
    await pumpUntil(
      tester,
      () =>
          !state.scan.value.running &&
          state.items.length > 100 &&
          shown() >= 30,
      what: 'real thumbnails',
      timeout: const Duration(minutes: 3),
    );
    // Not a benchmark (debug-mode test harness on a CI VM), just a sanity figure.
    debugPrint(
      'GALLERY: ${state.items.length} items, ${shown()} thumbnails on screen after ${DateTime.now().difference(started).inMilliseconds} ms',
    );
    if (state.leftOpen) state.toggleLeft();
    state.setTileSize(210);
    await pumpUntil(
      tester,
      () => shown() >= 35,
      what: 'a full screen of thumbnails',
      timeout: const Duration(minutes: 2),
    );
    await screenshot(tester, boundary, '10-real-grid');

    final search = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'Search prompts, models, names',
    );
    await tester.enterText(search, 'fennec model:flux');
    await pumpUntil(
      tester,
      () =>
          state.items.length < 40 &&
          state.items.isNotEmpty &&
          shown() >= state.items.length.clamp(1, 12),
      what: 'search results',
    );
    debugPrint('GALLERY: "fennec model:flux" -> ${state.items.length} items');
    state.select(0);
    if (!state.rightOpen) state.toggleRight();
    await pumpUntil(
      tester,
      () => find.text('PROMPT').evaluate().isNotEmpty,
      what: 'metadata',
    );
    await pumpUntil(
      tester,
      () => shown() >= state.items.length.clamp(1, 9),
      what: 'results thumbnails',
    );
    await screenshot(tester, boundary, '11-real-search-metadata');

    state.openFocus(0);
    await pumpUntil(
      tester,
      () => tester
          .widgetList<RawImage>(
            find.descendant(
              of: find.byType(Image),
              matching: find.byType(RawImage),
            ),
          )
          .any((w) => w.image != null),
      what: 'the full image',
      timeout: const Duration(minutes: 1),
    );
    await screenshot(tester, boundary, '12-real-focus');
    state.closeFocus();
    await tester.pump();

    // ---- the new features, on real pictures ----------------------------------
    // Rate and flag a spread of them.
    state.applySearch('');
    await pumpUntil(tester, () => state.items.length > 100 && shown() >= 30, what: 'the whole folder again');
    final rate = [5, 4, 0, 5, 3, 0, 4, 2, 0, 5, 1, 0];
    final targets = [for (var i = 0; i < rate.length; i++) state.items[i]];
    for (final (i, item) in targets.indexed) {
      final flag = i == 0 || i == 3 ? Flag.keep : (i == 10 ? Flag.reject : null);
      await tester.runAsync(() => state.changeNotes(targets: [item], rating: rate[i], flag: flag));
    }
    await tester.runAsync(() => state.changeNotes(targets: [targets[0], targets[3], targets[9]], add: ['Favourites']));
    state.select(3);
    await pumpUntil(tester, () => state.items[0].rating == 5 && find.text('Favourites').evaluate().isNotEmpty, what: 'the ratings');
    await pumpUntil(tester, () => shown() >= 30, what: 'thumbnails');
    await settle(tester);
    await screenshot(tester, boundary, '30-real-ratings');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await pumpUntil(tester, () => find.byKey(const ValueKey('filter-stars-4')).evaluate().isNotEmpty, what: 'the filter panel');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('filter-stars-4')));
    await pumpUntil(tester, () => state.items.length == 5, what: '4 stars or more');
    await settle(tester);
    await screenshot(tester, boundary, '31-real-filters');
    await tester.tap(find.byKey(const ValueKey('filters-done')));
    await settle(tester);
    await pumpUntil(tester, () => shown() >= 5, what: 'the filtered grid');
    await screenshot(tester, boundary, '31b-real-filtered');

    // The prompt editor: words selected, weighted with the slider.
    state.select(0);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await pumpUntil(tester, () => find.byKey(const ValueKey('remix-prompt')).evaluate().isNotEmpty, what: 'the remix panel');
    await settle(tester);
    final editor = tester.widget<PromptEditor>(find.byKey(const ValueKey('remix-prompt')));
    final c = editor.controller;
    await tester.tap(find.byKey(const ValueKey('remix-prompt')));
    await tester.pump();
    // The first few words of the prompt.
    final words = RegExp(r'^\W*\w+(\W+\w+){0,2}').firstMatch(c.text);
    c.selection = TextSelection(baseOffset: 0, extentOffset: words?.end ?? 1);
    await tester.pump();
    await tester.pump();
    if (find.byKey(const ValueKey('weight-slider')).evaluate().isNotEmpty) {
      await tester.drag(find.byKey(const ValueKey('weight-slider')), const Offset(45, 0));
      await tester.pump();
    }
    await pumpUntil(tester, () => c.spelling?.ready ?? false, what: 'the dictionary');
    await settle(tester);
    await screenshot(tester, boundary, '32-real-remix');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // The upscale panel.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await pumpUntil(tester, () => find.byKey(const ValueKey('upscale-start')).evaluate().isNotEmpty, what: 'the upscale panel');
    await settle(tester);
    await screenshot(tester, boundary, '33-real-upscale');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // Best rated, on the usage page.
    state.applySearch('');
    await pumpUntil(tester, () => state.items.length > 100, what: 'everything');
    await tester.tap(find.byTooltip('Usage stats'));
    await settle(tester);
    await pumpUntil(tester, () => find.text('Best rated').evaluate().isNotEmpty, what: 'the usage page');
    await tester.tap(find.text('Best rated'));
    await settle(tester);
    await pumpUntil(
      tester,
      () => tester.widgetList<RawImage>(find.byType(RawImage)).where((w) => w.image != null).length >= 4,
      what: 'sample thumbnails',
      timeout: const Duration(minutes: 1),
    );
    await settle(tester);
    await screenshot(tester, boundary, '34-real-best-rated');
    Navigator.of(tester.element(find.text('Best rated'))).pop();
    await settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settle(tester);
    await screenshot(tester, boundary, '35-shortcuts');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump(const Duration(seconds: 5));
  });
}
