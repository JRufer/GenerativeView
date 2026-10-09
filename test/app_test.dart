// Drives the real app against the real Rust core on a folder of generated
// test images. Needs a host build of the core:
//
//     (cd core && cargo build --release) && flutter test
//
// Set GV_SCREENSHOT_DIR to save a PNG of each stage.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/ui/focus_view.dart';
import 'package:generativeview/src/ui/media_grid.dart';
import 'package:generativeview/src/ui/meta_panel.dart';
import 'package:generativeview/src/ui/thumb_image.dart';
import 'package:generativeview/src/ui/top_bar.dart';

import 'support.dart';

const lighthouse = 'cinematic photo of a lighthouse on a cliff, stormy sea, volumetric light';

void main() {
  late Directory scratch;
  late Directory library;
  late NativeCore core;
  final boundary = GlobalKey();

  setUpAll(() async {
    await loadAppFonts();
    scratch = Directory.systemTemp.createTempSync('gv-test-');
    library = Directory('${scratch.path}/library')..createSync();
    Directory('${library.path}/portraits').createSync();

    var n = 0;
    void write(String relative, Map<String, String> texts, {int w = 384, int h = 384}) {
      final file = File('${library.path}/$relative');
      file.writeAsBytesSync(pngWithText(w, h, ++n, texts));
      // Distinct, ordered modification times make "newest first" predictable.
      file.setLastModifiedSync(DateTime(2026, 10, 1, 12).add(Duration(minutes: n)));
    }

    write('ComfyUI_00001_.png', {'prompt': comfyGraph(prompt: lighthouse, seed: 219670278747233, lora: 'style/inkwash_v2.safetensors')});
    write('ComfyUI_00002_.png', {'prompt': comfyGraph(prompt: 'a red fox asleep in fresh snow, macro', seed: 22)});
    write('ComfyUI_00003_.png', {'prompt': comfyGraph(prompt: 'isometric cutaway of a clockwork owl', seed: 33, checkpoint: 'sd_xl_base_1.0.safetensors')}, w: 512, h: 320);
    write('ComfyUI_00004_.png', {'prompt': comfyGraph(prompt: 'a glass violin on a velvet cloth', seed: 44)}, w: 320, h: 512);
    write('00012-3958203417.png', {'parameters': a1111Parameters('oil painting of a lighthouse at dusk <lora:impasto:0.7>', seed: 3958203417)}, w: 320, h: 448);
    write('00013-1.png', {'parameters': a1111Parameters('a brass heron, studio light', seed: 1)});
    write('portraits/a1b2c3.png', {'invokeai_metadata': invokeMetadata('an isometric cutaway of a cozy submarine cabin', seed: 2718281828)}, w: 448, h: 320);
    write('portraits/d4e5f6.png', {'invokeai_metadata': invokeMetadata('portrait of an old sailor, weathered face', seed: 31)});
    write('plain-photo.png', const {});

    core = NativeCore.start(
      dataDir: '${scratch.path}/data',
      cacheDir: '${scratch.path}/cache',
      libraryPath: coreLibraryPath(),
    );
  });

  tearDownAll(() {
    try {
      scratch.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> launch(WidgetTester tester, {Size size = const Size(1440, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(core: core, thumbs: ThumbCache(core, maxBytes: 64 << 20));
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: GenerativeViewApp(state: state)));
    // `restore` awaits the core, which answers in real time.
    final restored = state.restore(initialFolder: library.path);
    var done = false;
    restored.whenComplete(() => done = true);
    await pumpUntil(tester, () => done, what: 'the folder to open');
    return state;
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump(const Duration(seconds: 5));
  }

  int tilesWithImages(WidgetTester tester) => tester
      .widgetList<RawImage>(find.descendant(of: find.byType(MediaGrid), matching: find.byType(RawImage)))
      .where((w) => w.image != null)
      .length;

  Finder tiles() => find.descendant(of: find.byType(MediaGrid), matching: find.byType(ThumbImage));

  final search = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == 'Search prompts, models, names',
    description: 'the search box',
  );

  Finder inBar(String text) => find.descendant(of: find.byType(TopBar), matching: find.text(text));

  bool fullImageShown(WidgetTester tester) => tester
      .widgetList<RawImage>(find.descendant(of: find.byType(Image), matching: find.byType(RawImage)))
      .any((w) => w.image != null);

  testWidgets('browse, search, inspect, copy, and step through a folder', (tester) async {
    final copied = captureClipboard(tester);
    final state = await launch(tester);

    // ---- the grid fills with every image in the folder tree ---------------
    await pumpUntil(tester, () => state.items.length == 9 && tilesWithImages(tester) == 9, what: '9 thumbnails');
    expect(inBar('library'), findsOneWidget);
    expect(inBar('9 items'), findsOneWidget);
    // Newest first.
    expect(state.items[0].name, 'plain-photo.png');
    expect(state.items[8].name, 'ComfyUI_00001_.png');
    await screenshot(tester, boundary, '01-grid');

    // ---- the folder tree shows where we are --------------------------------
    await tester.pump(const Duration(milliseconds: 200));
    expect(state.leftOpen, isTrue);

    // ---- search by prompt contents, across all three tools -----------------
    await tester.enterText(search, 'lighthouse');
    await pumpUntil(tester, () => state.items.length == 2 && tiles().evaluate().length == 2, what: 'search results');
    expect(state.items[0].name, '00012-3958203417.png');
    expect(state.items[1].name, 'ComfyUI_00001_.png');
    expect(inBar('2 matches'), findsOneWidget);
    await screenshot(tester, boundary, '02-search');

    await tester.enterText(search, 'model:juggernaut');
    await pumpUntil(tester, () => state.items.length == 2 && state.items[0].dir.endsWith('portraits'), what: 'model search');

    await tester.enterText(search, 'no such prompt anywhere');
    await pumpUntil(tester, () => state.items.isEmpty && find.textContaining('Nothing matches').evaluate().isNotEmpty, what: 'empty result');

    await tester.enterText(search, '');
    await pumpUntil(tester, () => state.items.length == 9 && tilesWithImages(tester) == 9, what: 'full list again');

    // ---- select an image and read how it was made --------------------------
    await tester.tap(tiles().last); // ComfyUI_00001_.png
    await tester.pump();
    expect(state.selected?.name, 'ComfyUI_00001_.png');
    expect(state.mode, ViewMode.grid);

    await tester.tap(find.byTooltip('Generation data (I)'));
    await pumpUntil(tester, () => find.text(lighthouse).evaluate().isNotEmpty, what: 'the prompt in the panel');
    final panel = find.byType(MetaPanel);
    Finder inPanel(String text) => find.descendant(of: panel, matching: find.text(text));
    expect(inPanel('ComfyUI'), findsOneWidget);
    expect(inPanel('watermark, text'), findsOneWidget);
    expect(inPanel('219670278747233'), findsOneWidget);
    expect(inPanel('flux1-dev.safetensors'), findsOneWidget);
    expect(inPanel('style/inkwash_v2.safetensors'), findsOneWidget);
    expect(inPanel('0.8'), findsOneWidget);
    expect(inPanel('dpmpp_2m'), findsOneWidget);
    expect(inPanel('1024x1024'), findsOneWidget);
    await screenshot(tester, boundary, '03-metadata');

    // ---- tap to copy -------------------------------------------------------
    await tester.tap(inPanel(lighthouse));
    await tester.pump();
    expect(copied.last, lighthouse);
    expect(find.text('Copied prompt'), findsOneWidget);

    await tester.tap(inPanel('219670278747233'));
    await tester.pump();
    expect(copied.last, '219670278747233');

    await tester.tap(inPanel('Copy as tags'));
    await tester.pump();
    expect(copied.last, '<lora:inkwash_v2:0.8>');

    await tester.tap(inPanel('Copy all'));
    await tester.pump();
    expect(copied.last, contains('Prompt: $lighthouse'));
    expect(copied.last, contains('Seed: 219670278747233'));
    expect(copied.last, contains('Sampler: dpmpp_2m'));

    // The raw graph is one tap away too.
    await tester.dragUntilVisible(find.textContaining('prompt · '), find.descendant(of: panel, matching: find.byType(Scrollable)), const Offset(0, -200));
    await tester.tap(find.textContaining('prompt · '));
    await tester.pump();
    expect(copied.last, startsWith('{"3":{"class_type":"KSampler"'));

    // The workflow section lists every node.
    await tester.ensureVisible(find.textContaining('WORKFLOW'));
    await tester.pump();
    await tester.tap(find.textContaining('WORKFLOW'));
    await tester.pump();
    expect(find.descendant(of: panel, matching: find.text('CheckpointLoaderSimple')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2)); // let the toast go

    // ---- double tap opens the image; keys and swipes move through ----------
    expect(tiles(), findsNWidgets(9));
    final last = tiles().last;
    await tester.tap(last);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(last);
    await tester.pump();
    expect(state.mode, ViewMode.focus);
    expect(find.byType(FocusView), findsOneWidget);
    expect(inBar('9 of 9'), findsOneWidget);
    await pumpUntil(tester, () => fullImageShown(tester), what: 'the full-size image');
    await screenshot(tester, boundary, '04-focus');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await pumpUntil(tester, () => inBar('8 of 9').evaluate().isNotEmpty, what: 'previous image');
    expect(state.selected?.name, 'ComfyUI_00002_.png');
    // The panel follows the image.
    await pumpUntil(tester, () => find.text('a red fox asleep in fresh snow, macro').evaluate().isNotEmpty, what: 'metadata of the new image');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await pumpUntil(tester, () => inBar('9 of 9').evaluate().isNotEmpty, what: 'next image');

    // Swipe right-to-left goes forward; we are at the end, so swipe back.
    await tester.fling(find.byType(FocusView), const Offset(500, 0), 2000);
    await pumpUntil(tester, () => state.selectedIndex == 7, what: 'swipe to the previous image');
    // Let the page settle: while a pager is still gliding, taps stop it
    // rather than reaching the page.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // ---- double tap returns to the grid ------------------------------------
    await tester.tap(find.byType(FocusView));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(FocusView));
    await pumpUntil(tester, () => state.mode == ViewMode.grid, what: 'the grid to return');
    expect(find.byType(FocusView), findsNothing);
    expect(state.selected?.name, 'ComfyUI_00002_.png');

    // ---- keyboard in the grid ----------------------------------------------
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(state.selectedIndex, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(state.selectedIndex, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(state.mode, ViewMode.focus);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state.mode, ViewMode.grid);

    // ---- resizing the grid changes how many columns fit ---------------------
    final before = state.gridColumns;
    state.setTileSize(120);
    await tester.pump();
    await tester.pump();
    expect(state.gridColumns, greaterThan(before));
    state.setTileSize(360);
    await pumpUntil(tester, () => tilesWithImages(tester) >= 4, what: 'larger thumbnails');
    expect(state.gridColumns, lessThan(before));
    await screenshot(tester, boundary, '05-large-tiles');

    // ---- panels collapse ----------------------------------------------------
    await tester.tap(find.byTooltip('Folders ([)'));
    await tester.tap(find.byTooltip('Generation data (I)'));
    await tester.pump();
    expect(state.leftOpen, isFalse);
    expect(state.rightOpen, isFalse);
    expect(find.byType(MetaPanel), findsNothing);
    await screenshot(tester, boundary, '06-panels-closed');

    await close(tester, state);
  });

  testWidgets('the grid follows files being added and removed', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 9, what: 'the initial listing');

    final added = File('${library.path}/ComfyUI_00099_.png')
      ..writeAsBytesSync(pngWithText(384, 384, 99, {'prompt': comfyGraph(prompt: 'a paper boat in a storm drain', seed: 99)}));
    await pumpUntil(tester, () => state.items.length == 10, what: 'the new file to appear');
    expect(state.items[0].name, 'ComfyUI_00099_.png');

    await tester.enterText(search, 'paper boat');
    await pumpUntil(tester, () => state.items.length == 1, what: 'the new file to be searchable');

    added.deleteSync();
    await pumpUntil(tester, () => state.items.isEmpty, what: 'the deleted file to disappear');

    await tester.enterText(search, '');
    await pumpUntil(tester, () => state.items.length == 9, what: 'the original listing');

    // Leaving sub-folders out narrows the view.
    await tester.tap(find.byTooltip('Sub-folders are included'));
    await pumpUntil(tester, () => state.items.length == 7, what: 'the non-recursive listing');
    await tester.tap(find.byTooltip('Sub-folders are not included'));
    await pumpUntil(tester, () => state.items.length == 9, what: 'the recursive listing');

    await close(tester, state);
  });

  testWidgets('on a narrow screen the panels slide over the grid', (tester) async {
    final state = await launch(tester, size: const Size(600, 900));
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');
    // Whatever was saved, start from a known layout.
    if (!state.leftOpen) state.toggleLeft();
    if (state.rightOpen) state.toggleRight();
    // The tree opens down to the current folder and scrolls it into view.
    await pumpUntil(tester, () => find.text('portraits').evaluate().isNotEmpty, what: 'the sub-folder row');
    await screenshot(tester, boundary, '07-narrow-folders');

    // Picking a folder closes the folder panel.
    await tester.tap(find.text('portraits'));
    await pumpUntil(tester, () => state.folder!.endsWith('portraits') && state.items.length == 2, what: 'the sub-folder');
    expect(state.leftOpen, isFalse);
    await pumpUntil(tester, () => tilesWithImages(tester) == 2, what: 'its thumbnails');
    await screenshot(tester, boundary, '08-narrow-grid');

    await close(tester, state);
  });
}
