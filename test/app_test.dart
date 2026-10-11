// Drives the real app against the real Rust core on a folder of generated
// test images. Needs a host build of the core:
//
//     (cd core && cargo build --release) && flutter test
//
// Set GV_SCREENSHOT_DIR to save a PNG of each stage.

import 'dart:io';
import 'dart:math' as math;

// ignore: unnecessary_import
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/model_download.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/ui/focus_view.dart';
import 'package:generativeview/src/ui/folder_panel.dart';
import 'package:generativeview/src/ui/media_grid.dart';
import 'package:generativeview/src/ui/meta_panel.dart';
import 'package:generativeview/src/ui/stats_page.dart';
import 'package:generativeview/src/ui/thumb_image.dart';
import 'package:generativeview/src/ui/top_bar.dart';

import 'support.dart';

const lighthouse =
    'cinematic photo of a lighthouse on a cliff, stormy sea, volumetric light';

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
    void write(
      String relative,
      Map<String, String> texts, {
      int w = 384,
      int h = 384,
    }) {
      final file = File('${library.path}/$relative');
      file.writeAsBytesSync(pngWithText(w, h, ++n, texts));
      // Distinct, ordered modification times make "newest first" predictable.
      file.setLastModifiedSync(
        DateTime(2026, 10, 1, 12).add(Duration(minutes: n)),
      );
    }

    write('ComfyUI_00001_.png', {
      'prompt': comfyGraph(
        prompt: lighthouse,
        seed: 219670278747233,
        lora: 'style/inkwash_v2.safetensors',
      ),
    });
    write('ComfyUI_00002_.png', {
      'prompt': comfyGraph(
        prompt: 'a red fox asleep in fresh snow, macro',
        seed: 22,
      ),
    });
    write(
      'ComfyUI_00003_.png',
      {
        'prompt': comfyGraph(
          prompt: 'isometric cutaway of a clockwork owl',
          seed: 33,
          checkpoint: 'sd_xl_base_1.0.safetensors',
        ),
      },
      w: 512,
      h: 320,
    );
    write(
      'ComfyUI_00004_.png',
      {
        'prompt': comfyGraph(
          prompt: 'a glass violin on a velvet cloth',
          seed: 44,
        ),
      },
      w: 320,
      h: 512,
    );
    write(
      '00012-3958203417.png',
      {
        'parameters': a1111Parameters(
          'oil painting of a lighthouse at dusk <lora:impasto:0.7>',
          seed: 3958203417,
        ),
      },
      w: 320,
      h: 448,
    );
    write('00013-1.png', {
      'parameters': a1111Parameters('a brass heron, studio light', seed: 1),
    });
    write(
      'portraits/a1b2c3.png',
      {
        'invokeai_metadata': invokeMetadata(
          'an isometric cutaway of a cozy submarine cabin',
          seed: 2718281828,
        ),
      },
      w: 448,
      h: 320,
    );
    write('portraits/d4e5f6.png', {
      'invokeai_metadata': invokeMetadata(
        'portrait of an old sailor, weathered face',
        seed: 31,
      ),
    });
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

  Future<AppState> launch(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    String? modelSource,
    List<ModelFile>? modelFiles,
    bool motion = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Panels and the search box move into place over a fraction of a second,
    // unless the system asks for less motion. Most tests ask for that, and
    // so see each change the moment it is made; the test of the movement
    // itself does not.
    if (!motion) {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    }
    final state = AppState(
      core: core,
      thumbs: ThumbCache(core, maxBytes: 64 << 20),
      modelSource: modelSource,
      modelFiles: modelFiles,
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: GenerativeViewApp(state: state),
      ),
    );
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
      .widgetList<RawImage>(
        find.descendant(
          of: find.byType(MediaGrid),
          matching: find.byType(RawImage),
        ),
      )
      .where((w) => w.image != null)
      .length;

  Finder tiles() => find.descendant(
    of: find.byType(MediaGrid),
    matching: find.byType(ThumbImage),
  );

  final search = find.byWidgetPredicate(
    (w) =>
        w is TextField &&
        w.decoration?.hintText == 'Search prompts, models, names',
    description: 'the search box',
  );

  Finder inBar(String text) =>
      find.descendant(of: find.byType(TopBar), matching: find.text(text));

  /// What the zoom chips of the pages in the focus view read.
  List<String> zoomLabels(WidgetTester tester) => [
    for (final chip in tester.widgetList<ZoomChip>(find.byType(ZoomChip)))
      chip.label,
  ];

  /// Whichever folder or search pins an earlier test (or run) left behind.
  void clearPins(AppState state) {
    for (final pin in [...state.pinnedSearches]) {
      state.unpinSearch(pin);
    }
    for (final path in [...state.pinnedFolders]) {
      state.toggleFolderPin(path);
    }
  }

  bool fullImageShown(WidgetTester tester) => tester
      .widgetList<RawImage>(
        find.descendant(
          of: find.byType(Image),
          matching: find.byType(RawImage),
        ),
      )
      .any((w) => w.image != null);

  testWidgets('browse, search, inspect, copy, and step through a folder', (
    tester,
  ) async {
    final copied = captureClipboard(tester);
    final state = await launch(tester);

    // ---- the grid fills with every image in the folder tree ---------------
    await pumpUntil(
      tester,
      () => state.items.length == 9 && tilesWithImages(tester) == 9,
      what: '9 thumbnails',
    );
    expect(inBar('library'), findsOneWidget);
    expect(inBar('9 items'), findsOneWidget);
    // Newest first.
    expect(state.items[0].name, 'plain-photo.png');
    expect(state.items[8].name, 'ComfyUI_00001_.png');
    await screenshot(tester, boundary, '01-grid');

    // ---- thumbnails: cropped to fill, or the whole image -------------------
    Set<BoxFit?> fits() => tester
        .widgetList<RawImage>(
          find.descendant(
            of: find.byType(MediaGrid),
            matching: find.byType(RawImage),
          ),
        )
        .map((w) => w.fit)
        .toSet();
    expect(fits(), {BoxFit.cover});
    await tester.tap(find.byTooltip('Thumbnails are cropped to fill (C)'));
    await tester.pump();
    expect(state.cropTiles, isFalse);
    expect(fits(), {BoxFit.contain});
    await screenshot(tester, boundary, '01b-grid-whole-images');
    // The key does the same, and the choice is put back for the next test.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(state.cropTiles, isTrue);
    expect(fits(), {BoxFit.cover});
    expect(find.byTooltip('Thumbnails are cropped to fill (C)'), findsOneWidget);

    // ---- the folder tree shows where we are --------------------------------
    await tester.pump(const Duration(milliseconds: 200));
    expect(state.leftOpen, isTrue);

    // ---- search by prompt contents, across all three tools -----------------
    await tester.enterText(search, 'lighthouse');
    await pumpUntil(
      tester,
      () => state.items.length == 2 && tiles().evaluate().length == 2,
      what: 'search results',
    );
    // Best match first: the prompt that gets to the lighthouse sooner.
    List<String> listed() => [
      for (var i = 0; i < state.items.length; i++) state.items[i].name,
    ];
    expect(listed(), ['ComfyUI_00001_.png', '00012-3958203417.png']);
    expect(inBar('2 matches'), findsOneWidget);
    await screenshot(tester, boundary, '02-search');

    // Part of a word is not a match, unless a star says it may be.
    await tester.enterText(search, 'lighth');
    await pumpUntil(
      tester,
      () =>
          state.items.isEmpty &&
          find.textContaining('Add * to match').evaluate().isNotEmpty,
      what: 'part of a word to find nothing',
    );
    await tester.enterText(search, 'lighth*');
    await pumpUntil(tester, () => state.items.length == 2, what: 'lighth*');
    // The word itself: "studio light" and "volumetric light", and neither
    // lighthouse for being one.
    await tester.enterText(search, 'light');
    await pumpUntil(
      tester,
      () => listed().join() == '00013-1.pngComfyUI_00001_.png',
      what: 'the whole word',
    );
    await tester.enterText(search, 'lighthouse');
    await pumpUntil(
      tester,
      () => listed().join() == 'ComfyUI_00001_.png00012-3958203417.png',
      what: 'the search',
    );

    // ---- search results can be put in another order, and stay that way -----
    Future<void> sortBy(String label) async {
      await tester.tap(find.byTooltip('Sort and refresh'));
      await settle(tester);
      await tester.tap(find.text(label));
      await settle(tester);
    }

    expect(state.activeSort, 'relevance');
    await sortBy('Name A to Z');
    await pumpUntil(
      tester,
      () => listed().first == '00012-3958203417.png',
      what: 'the matches by name',
    );
    expect(listed(), ['00012-3958203417.png', 'ComfyUI_00001_.png']);
    expect((state.searchSort, state.sort), ('name', 'newest'));
    await tester.enterText(search, 'fox');
    await pumpUntil(tester, () => state.items.length == 1, what: 'fox');
    expect(state.activeSort, 'name');
    await tester.enterText(search, 'lighthouse');
    await pumpUntil(tester, () => state.items.length == 2, what: 'the search');
    await sortBy('Best match first');
    await pumpUntil(
      tester,
      () => listed().first == 'ComfyUI_00001_.png',
      what: 'the best match first again',
    );
    expect((state.searchSort, state.sort), ('relevance', 'newest'));

    await tester.enterText(search, 'model:juggernaut');
    await pumpUntil(
      tester,
      () => state.items.length == 2 && state.items[0].dir.endsWith('portraits'),
      what: 'model search',
    );

    await tester.enterText(search, 'no such prompt anywhere');
    await pumpUntil(
      tester,
      () =>
          state.items.isEmpty &&
          find.textContaining('Nothing matches').evaluate().isNotEmpty,
      what: 'empty result',
    );

    await tester.enterText(search, '');
    await pumpUntil(
      tester,
      () => state.items.length == 9 && tilesWithImages(tester) == 9,
      what: 'full list again',
    );
    // With nothing searched for there is no best match to offer, and the
    // folder is in its own order.
    await tester.tap(find.byTooltip('Sort and refresh'));
    await settle(tester);
    expect(find.text('Best match first'), findsNothing);
    expect(find.text('Newest first'), findsOneWidget);
    await tester.tapAt(const Offset(4, 890));
    await settle(tester);
    expect(state.activeSort, 'newest');

    // ---- select an image and read how it was made --------------------------
    await tester.tap(tiles().last); // ComfyUI_00001_.png
    await tester.pump();
    expect(state.selected?.name, 'ComfyUI_00001_.png');
    expect(state.mode, ViewMode.grid);

    await tester.tap(find.byTooltip('Generation data (I)'));
    await pumpUntil(
      tester,
      () => find.text(lighthouse).evaluate().isNotEmpty,
      what: 'the prompt in the panel',
    );
    final panel = find.byType(MetaPanel);
    Finder inPanel(String text) =>
        find.descendant(of: panel, matching: find.text(text));
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
    await tester.dragUntilVisible(
      find.textContaining('prompt · '),
      find.descendant(of: panel, matching: find.byType(Scrollable)),
      const Offset(0, -200),
    );
    await tester.tap(find.textContaining('prompt · '));
    await tester.pump();
    expect(copied.last, startsWith('{"3":{"class_type":"KSampler"'));

    // The workflow section lists every node.
    await tester.ensureVisible(find.textContaining('WORKFLOW'));
    await tester.pump();
    await tester.tap(find.textContaining('WORKFLOW'));
    await tester.pump();
    expect(
      find.descendant(of: panel, matching: find.text('CheckpointLoaderSimple')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2)); // let the toast go

    // ---- double tap opens the image; keys and swipes move through ----------
    expect(tiles(), findsNWidgets(9));
    final last = tiles().last;
    // The grid times double taps by the real clock, and this tile was last
    // tapped (to select it) a moment ago by that clock, however much test
    // time has gone by since: let that tap grow old first.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.tap(last);
    await tester.pump(const Duration(milliseconds: 40));
    expect(state.mode, ViewMode.grid, reason: 'one tap only selects');
    await tester.tap(last);
    await tester.pump();
    expect(state.mode, ViewMode.focus);
    expect(find.byType(FocusView), findsOneWidget);
    expect(inBar('9 of 9'), findsOneWidget);
    await pumpUntil(
      tester,
      () => fullImageShown(tester),
      what: 'the full-size image',
    );
    await screenshot(tester, boundary, '04-focus');

    // ---- the wheel zooms, and only zooms -----------------------------------
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    final middle = tester.getCenter(find.byType(FocusView));
    await tester.sendEventToBinding(mouse.hover(middle));
    final fitted = zoomLabels(tester);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
    await tester.pump();
    expect(zoomLabels(tester), isNot(fitted), reason: 'wheel up zooms in');
    expect(state.selectedIndex, 8, reason: 'wheel up does not change image');
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(zoomLabels(tester), fitted, reason: 'wheel down zooms back out');
    expect(state.selectedIndex, 8, reason: 'wheel down does not change image');
    expect(state.mode, ViewMode.focus);

    // ---- Space and Enter flip between the image and the grid ---------------
    for (final key in [LogicalKeyboardKey.space, LogicalKeyboardKey.enter]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(state.mode, ViewMode.grid, reason: '${key.keyLabel} leaves focus');
      expect(state.selectedIndex, 8);
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(state.mode, ViewMode.focus, reason: '${key.keyLabel} opens focus');
      expect(state.selectedIndex, 8);
    }
    await pumpUntil(
      tester,
      () => fullImageShown(tester),
      what: 'the full-size image again',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await pumpUntil(
      tester,
      () => inBar('8 of 9').evaluate().isNotEmpty,
      what: 'previous image',
    );
    expect(state.selected?.name, 'ComfyUI_00002_.png');
    // The panel follows the image.
    await pumpUntil(
      tester,
      () => find
          .text('a red fox asleep in fresh snow, macro')
          .evaluate()
          .isNotEmpty,
      what: 'metadata of the new image',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await pumpUntil(
      tester,
      () => inBar('9 of 9').evaluate().isNotEmpty,
      what: 'next image',
    );

    // Swipe right-to-left goes forward; we are at the end, so swipe back.
    await tester.fling(find.byType(FocusView), const Offset(500, 0), 2000);
    await pumpUntil(
      tester,
      () => state.selectedIndex == 7,
      what: 'swipe to the previous image',
    );
    // Let the page settle: while a pager is still gliding, taps stop it
    // rather than reaching the page.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // ---- double tap returns to the grid ------------------------------------
    await tester.tap(find.byType(FocusView));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(FocusView));
    await pumpUntil(
      tester,
      () => state.mode == ViewMode.grid,
      what: 'the grid to return',
    );
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
    await pumpUntil(
      tester,
      () => tilesWithImages(tester) >= 4,
      what: 'larger thumbnails',
    );
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
    await pumpUntil(
      tester,
      () => state.items.length == 9,
      what: 'the initial listing',
    );

    final added = File('${library.path}/ComfyUI_00099_.png')
      ..writeAsBytesSync(
        pngWithText(384, 384, 99, {
          'prompt': comfyGraph(
            prompt: 'a paper boat in a storm drain',
            seed: 99,
          ),
        }),
      );
    await pumpUntil(
      tester,
      () => state.items.length == 10,
      what: 'the new file to appear',
    );
    expect(state.items[0].name, 'ComfyUI_00099_.png');

    await tester.enterText(search, 'paper boat');
    await pumpUntil(
      tester,
      () => state.items.length == 1,
      what: 'the new file to be searchable',
    );

    added.deleteSync();
    await pumpUntil(
      tester,
      () => state.items.isEmpty,
      what: 'the deleted file to disappear',
    );

    await tester.enterText(search, '');
    await pumpUntil(
      tester,
      () => state.items.length == 9,
      what: 'the original listing',
    );

    // Leaving sub-folders out narrows the view.
    await tester.tap(find.byTooltip('Sub-folders are included'));
    await pumpUntil(
      tester,
      () => state.items.length == 7,
      what: 'the non-recursive listing',
    );
    await tester.tap(find.byTooltip('Sub-folders are not included'));
    await pumpUntil(
      tester,
      () => state.items.length == 9,
      what: 'the recursive listing',
    );

    await close(tester, state);
  });

  testWidgets('on a narrow screen the panels slide over the grid', (
    tester,
  ) async {
    final state = await launch(tester, size: const Size(600, 900));
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');
    // Whatever was saved, start from a known layout.
    if (!state.leftOpen) state.toggleLeft();
    if (state.rightOpen) state.toggleRight();
    // The tree opens down to the current folder and scrolls it into view.
    await pumpUntil(
      tester,
      () => find.text('portraits').evaluate().isNotEmpty,
      what: 'the sub-folder row',
    );
    await screenshot(tester, boundary, '07-narrow-folders');

    // Picking a folder closes the folder panel.
    await tester.tap(find.text('portraits'));
    await pumpUntil(
      tester,
      () => state.folder!.endsWith('portraits') && state.items.length == 2,
      what: 'the sub-folder',
    );
    expect(state.leftOpen, isFalse);
    await pumpUntil(
      tester,
      () => tilesWithImages(tester) == 2,
      what: 'its thumbnails',
    );
    await screenshot(tester, boundary, '08-narrow-grid');

    await close(tester, state);
  });

  testWidgets('in a portrait window the metadata panel is a footer', (
    tester,
  ) async {
    final state = await launch(tester, size: const Size(900, 1300));
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');
    // Whatever was saved, start from a known layout.
    if (!state.leftOpen) state.toggleLeft();
    if (!state.rightOpen) state.toggleRight();
    state.setTileSize(190);
    state.select(8); // ComfyUI_00001_.png
    await pumpUntil(
      tester,
      () =>
          find.text(lighthouse).evaluate().isNotEmpty &&
          tilesWithImages(tester) == 9,
      what: 'the grid and the prompt in the panel',
    );

    Rect rect(Type type) => tester.getRect(find.byType(type));
    const seed = '219670278747233';

    // ---- under the grid, across the whole window ----------------------------
    expect(state.portraitLayout, isTrue);
    expect(rect(MetaPanel).top, greaterThanOrEqualTo(rect(MediaGrid).bottom));
    expect(rect(MetaPanel).left, 0);
    expect(rect(MetaPanel).right, 900);
    expect(rect(MetaPanel).bottom, 1300);
    // The folder panel keeps its place beside the grid.
    expect(rect(FolderPanel).right, lessThanOrEqualTo(rect(MediaGrid).left));
    expect(rect(FolderPanel).bottom, lessThanOrEqualTo(rect(MetaPanel).top));
    // Short and wide, so the sections sit in two columns.
    expect(tester.getCenter(find.text(lighthouse)).dx, lessThan(450));
    expect(tester.getCenter(find.text(seed)).dx, greaterThan(450));
    await screenshot(tester, boundary, '09-portrait-footer');

    // ---- its top edge drags to resize it ------------------------------------
    final before = rect(MetaPanel);
    final share = state.bottomShare;
    await tester.dragFrom(
      before.topCenter - const Offset(0, 9),
      const Offset(0, -200),
    );
    await tester.pump();
    expect(state.bottomShare, greaterThan(share));
    expect(rect(MetaPanel).height, greaterThan(before.height + 100));
    expect(rect(MetaPanel).bottom, 1300);
    expect(rect(MetaPanel).top, greaterThanOrEqualTo(rect(MediaGrid).bottom));

    // ---- and it stays there under the focus view ----------------------------
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpUntil(
      tester,
      () => fullImageShown(tester),
      what: 'the full-size image',
    );
    expect(state.mode, ViewMode.focus);
    expect(find.byType(FolderPanel), findsNothing);
    expect(rect(FocusView).left, 0);
    expect(rect(FocusView).right, 900);
    expect(rect(MetaPanel).top, greaterThanOrEqualTo(rect(FocusView).bottom));
    expect(find.text(lighthouse), findsOneWidget);
    await screenshot(tester, boundary, '10-portrait-focus');

    // Esc leaves the image; the footer is docked, not an overlay to dismiss.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state.mode, ViewMode.grid);
    expect(state.rightOpen, isTrue);

    // ---- turned to landscape it is a side panel again -----------------------
    tester.view.physicalSize = const Size(1300, 900);
    await tester.pump();
    await tester.pump();
    expect(state.portraitLayout, isFalse);
    expect(rect(MetaPanel).left, greaterThanOrEqualTo(rect(MediaGrid).right));
    expect(rect(MetaPanel).right, 1300);
    expect(rect(MetaPanel).bottom, 900);
    // Nothing was reloaded on the way over.
    expect(find.text(lighthouse), findsOneWidget);
    expect(
      tester.getCenter(find.text(seed)).dy,
      greaterThan(tester.getCenter(find.text(lighthouse)).dy),
    );

    // ---- a narrow portrait window: a phone, or a tiled half-screen ----------
    tester.view.physicalSize = const Size(600, 900);
    await tester.pump();
    await tester.pump();
    // The folder panel slides over everything, the footer included …
    expect(state.leftFloats, isTrue);
    expect(state.rightFloats, isFalse);
    expect(rect(FolderPanel).bottom, 900);
    expect(rect(MetaPanel).top, greaterThanOrEqualTo(rect(MediaGrid).bottom));
    expect(rect(MetaPanel).left, 0);
    expect(rect(MetaPanel).right, 600);
    // … and Esc puts away the folder panel alone.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state.leftOpen, isFalse);
    expect(state.rightOpen, isTrue);
    expect(find.byType(MetaPanel), findsOneWidget);
    // Too narrow for two columns.
    expect(
      tester.getCenter(find.text(seed)).dy,
      greaterThan(tester.getCenter(find.text(lighthouse)).dy),
    );
    await screenshot(tester, boundary, '11-portrait-narrow');

    // ---- opening the footer never leaves the selected tile behind it --------
    ScrollPosition gridScroll() => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(MediaGrid),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    state.toggleRight();
    await pumpUntil(
      tester,
      () =>
          find.byType(MetaPanel).evaluate().isEmpty &&
          gridScroll().pixels == 0,
      what: 'the whole grid on screen',
    );
    expect(state.selectedIndex, 8); // in the bottom row
    state.toggleRight();
    await tester.pump();
    await tester.pump();
    // Scrolled so that the bottom row sits just above the footer.
    expect(gridScroll().pixels, greaterThan(0));
    expect(gridScroll().pixels, closeTo(gridScroll().maxScrollExtent, 0.5));

    await close(tester, state);
  });

  testWidgets('searches can be pinned and picked from under the search box', (
    tester,
  ) async {
    var state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');
    clearPins(state);
    final pins = find.byKey(const ValueKey<String>('pinned-searches'));
    Finder pinned(String query) =>
        find.descendant(of: pins, matching: find.text(query));

    // ---- nothing pinned: no list, and nothing to pin in an empty box --------
    await tester.tap(search);
    await tester.pump();
    expect(pins, findsNothing);
    expect(find.byTooltip('Pin this search'), findsNothing);

    // ---- type a search, and the pin beside the X keeps it -------------------
    await tester.enterText(search, 'lighthouse');
    await pumpUntil(tester, () => state.items.length == 2, what: 'the search');
    expect(find.byTooltip('Clear search'), findsOneWidget);
    await tester.tap(find.byTooltip('Pin this search'));
    await tester.pump();
    expect(state.pinnedSearches.map((p) => p.query), ['lighthouse']);
    expect(find.byTooltip('Pin this search'), findsNothing);
    expect(find.byTooltip('Unpin this search'), findsOneWidget);
    expect(pinned('lighthouse'), findsOneWidget);

    await tester.enterText(search, 'model:juggernaut');
    await pumpUntil(tester, () => state.items.length == 2, what: 'the search');
    // Typing narrows the list to the pins that contain what was typed.
    expect(pins, findsNothing);
    await tester.tap(find.byTooltip('Pin this search'));
    await tester.pump();
    expect(state.pinnedSearches.map((p) => p.query), [
      'lighthouse',
      'model:juggernaut',
    ]);

    // ---- an empty box offers them all; picking one runs it ------------------
    await tester.tap(find.byTooltip('Clear search'));
    await pumpUntil(tester, () => state.items.length == 9, what: 'everything');
    expect(pinned('lighthouse'), findsOneWidget);
    expect(pinned('model:juggernaut'), findsOneWidget);
    // Under the box, and no narrower than it.
    expect(
      tester.getRect(pins).top,
      greaterThanOrEqualTo(tester.getRect(search).bottom),
    );
    expect(tester.getRect(pins).left, closeTo(tester.getRect(search).left, 1));
    await screenshot(tester, boundary, '12-pinned-searches');

    await tester.tap(pinned('lighthouse'));
    await pumpUntil(
      tester,
      () => state.items.length == 2 && state.query == 'lighthouse',
      what: 'the pinned search to run',
    );
    expect(state.searchText.text, 'lighthouse');
    expect(state.searchFocus.hasFocus, isFalse);
    expect(pins, findsNothing);

    // ---- clicking in the box brings the list back, whatever is in it --------
    await tester.tap(search);
    await tester.pump();
    expect(pinned('lighthouse'), findsOneWidget);
    expect(pinned('model:juggernaut'), findsOneWidget);
    await tester.tap(pinned('model:juggernaut'));
    await pumpUntil(
      tester,
      () => state.items.length == 2 && state.items[0].dir.endsWith('portraits'),
      what: 'the other pinned search to run',
    );

    // ---- pins outlive the app ------------------------------------------------
    await close(tester, state);
    state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');
    expect(state.pinnedSearches.map((p) => p.query), [
      'lighthouse',
      'model:juggernaut',
    ]);

    // ---- the X on a pin removes it; the pin in the box does too -------------
    await tester.tap(search);
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: pins,
        matching: find.byTooltip('Remove from pinned searches'),
      ).first,
    );
    await tester.pump();
    expect(state.pinnedSearches.map((p) => p.query), ['model:juggernaut']);
    expect(pinned('lighthouse'), findsNothing);
    expect(pinned('model:juggernaut'), findsOneWidget);

    await tester.tap(pinned('model:juggernaut'));
    await pumpUntil(tester, () => state.items.length == 2, what: 'the search');
    await tester.tap(find.byTooltip('Unpin this search'));
    await tester.pump();
    expect(state.pinnedSearches, isEmpty);
    expect(find.byTooltip('Pin this search'), findsOneWidget);

    state.applySearch('');
    await close(tester, state);
  });

  testWidgets('folders can be pinned to the top of the folder panel', (
    tester,
  ) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');
    if (!state.leftOpen) state.toggleLeft();
    if (!state.pinsOpen) state.togglePins();
    clearPins(state);
    await pumpUntil(
      tester,
      () => find.text('portraits').evaluate().isNotEmpty,
      what: 'the sub-folder row',
    );
    final portraits = '${library.path}/portraits';
    final section = find.byKey(const ValueKey<String>('pinned-folders'));
    Finder inSection(String text) =>
        find.descendant(of: section, matching: find.text(text));
    final tree = find.descendant(
      of: find.byType(FolderPanel),
      matching: find.byType(Scrollable),
    );
    final goTo = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Go to folder path…',
    );

    // ---- always there, under the path box and above the tree ----------------
    expect(inSection('PINNED'), findsOneWidget);
    expect(find.textContaining('to pin it here'), findsOneWidget);
    expect(
      tester.getRect(section).top,
      greaterThanOrEqualTo(tester.getRect(goTo).bottom),
    );
    expect(
      tester.getRect(section).bottom,
      lessThanOrEqualTo(tester.getRect(tree.last).top),
    );
    expect(find.byIcon(pinnedFolderIcon), findsNothing);

    // ---- right-click a folder to pin it -------------------------------------
    await tester.tap(find.text('portraits'), buttons: kSecondaryButton);
    await settle(tester);
    expect(find.text('Unpin this folder'), findsNothing);
    await tester.tap(find.text('Pin this folder'));
    await settle(tester);
    expect(state.pinnedFolders, [portraits]);
    expect(inSection('portraits'), findsOneWidget);
    expect(find.textContaining('to pin it here'), findsNothing);
    // The blue folder marks it in the section and in the tree alike.
    final marks = tester.widgetList<Icon>(find.byIcon(pinnedFolderIcon));
    expect(marks, hasLength(2));
    expect(marks.every((icon) => icon.color == const Color(0xFF7AA2F7)), isTrue);
    await screenshot(tester, boundary, '13-pinned-folders');

    // ---- one tap goes there --------------------------------------------------
    await tester.tap(inSection('portraits'));
    await pumpUntil(
      tester,
      () => state.folder == portraits && state.items.length == 2,
      what: 'the pinned folder to open',
    );

    // ---- the section folds away, heading and all else staying put -----------
    await tester.tap(inSection('PINNED'));
    await tester.pump();
    expect(state.pinsOpen, isFalse);
    expect(inSection('PINNED'), findsOneWidget);
    expect(inSection('portraits'), findsNothing);
    await tester.tap(inSection('PINNED'));
    await tester.pump();
    expect(inSection('portraits'), findsOneWidget);

    // ---- press and hold to unpin --------------------------------------------
    await tester.longPress(inSection('portraits'));
    await settle(tester);
    expect(find.text('Pin this folder'), findsNothing);
    await tester.tap(find.text('Unpin this folder'));
    await settle(tester);
    expect(state.pinnedFolders, isEmpty);
    expect(find.byIcon(pinnedFolderIcon), findsNothing);
    expect(state.folder, portraits, reason: 'unpinning opens nothing');

    await close(tester, state);
  });

  testWidgets('the metadata panel filters the grid by what an image used', (
    tester,
  ) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');
    if (!state.rightOpen) state.toggleRight();
    const inkwash = 'style/inkwash_v2.safetensors';
    const detail = 'detail_xl.safetensors';
    // Two more images that share two LoRAs, at different strengths.
    final extras = [
      File('${library.path}/both_strong.png')..writeAsBytesSync(
        pngWithText(384, 384, 71, {
          'prompt': comfyGraph(
            prompt: 'a tin robot watering ferns',
            seed: 71,
            loras: [inkwash, detail],
          ),
        }),
      ),
      File('${library.path}/both_faint.png')..writeAsBytesSync(
        pngWithText(384, 384, 72, {
          'prompt': comfyGraph(
            prompt: 'a tin robot asleep',
            seed: 72,
            checkpoint: 'sd_xl_base_1.0.safetensors',
            loras: [detail, inkwash],
            strength: 0.35,
          ),
        }),
      ),
    ];
    await pumpUntil(tester, () => state.items.length == 11, what: 'the extras');

    final panel = find.byType(MetaPanel);
    Finder inPanel(String text) =>
        find.descendant(of: panel, matching: find.text(text));
    List<String> shown() => [
      for (var i = 0; i < state.items.length; i++) state.items[i].name,
    ]..sort();
    Future<void> pick(String name, String prompt) async {
      state.applySearch('');
      await pumpUntil(tester, () => state.items.length == 11, what: 'all');
      state.select(
        List.generate(11, (i) => state.items[i].name).indexOf(name),
      );
      await pumpUntil(
        tester,
        () => inPanel(prompt).evaluate().isNotEmpty,
        what: 'the metadata of $prompt',
      );
    }

    Future<void> choose(String label) async {
      await settle(tester);
      expect(find.text(label), findsOneWidget);
      await tester.tap(find.text(label));
      await settle(tester);
    }

    // ---- press and hold the model -------------------------------------------
    await pick('ComfyUI_00001_.png', lighthouse);
    await tester.longPress(inPanel('flux1-dev.safetensors'));
    await choose('Show only images made with this model');
    await pumpUntil(tester, () => state.items.length == 4, what: 'one model');
    expect(state.searchText.text, 'model:=flux1-dev.safetensors');
    expect(shown(), [
      'ComfyUI_00001_.png',
      'ComfyUI_00002_.png',
      'ComfyUI_00004_.png',
      'both_strong.png',
    ]);
    // The image it came from is still the selected one.
    expect(state.selected?.name, 'ComfyUI_00001_.png');
    expect(inBar('4 matches'), findsOneWidget);

    // ---- right-click the seed ------------------------------------------------
    await tester.tap(inPanel('219670278747233'), buttons: kSecondaryButton);
    await choose('Show only images with this seed');
    await pumpUntil(tester, () => state.items.length == 1, what: 'one seed');
    expect(state.searchText.text, 'seed:=219670278747233');

    // ---- "LoRAs": every image that uses all of them, at any strength --------
    await pick('both_strong.png', 'a tin robot watering ferns');
    await tester.longPress(inPanel('LORAS'));
    await choose('Show only images using all 2 of these LoRAs');
    await pumpUntil(tester, () => state.items.length == 2, what: 'both LoRAs');
    expect(state.searchText.text.split(' ').toSet(), {
      'lora:=$inkwash',
      'lora:=$detail',
    });
    expect(shown(), ['both_faint.png', 'both_strong.png']);
    await screenshot(tester, boundary, '14-filtered-by-loras');

    // ---- one LoRA: every image that uses that one ---------------------------
    await tester.longPress(inPanel(inkwash));
    await choose('Show only images using this LoRA');
    await pumpUntil(tester, () => state.items.length == 3, what: 'one LoRA');
    expect(state.searchText.text, 'lora:=$inkwash');
    expect(shown(), [
      'ComfyUI_00001_.png',
      'both_faint.png',
      'both_strong.png',
    ]);

    // With a single LoRA the heading offers the same thing.
    await pick('ComfyUI_00001_.png', lighthouse);
    await tester.longPress(inPanel('LORAS'));
    await choose('Show only images using this LoRA');
    await pumpUntil(tester, () => state.items.length == 3, what: 'one LoRA');

    // ---- a setting ------------------------------------------------------------
    await tester.longPress(inPanel('dpmpp_2m'));
    await choose('Show only images with this setting');
    await pumpUntil(tester, () => state.items.length == 6, what: 'a sampler');
    expect(state.searchText.text, 'sampler:=dpmpp_2m');

    // ---- from the focus view, filtering comes back to the grid --------------
    await pick('ComfyUI_00001_.png', lighthouse);
    state.openFocus();
    await tester.pump();
    expect(state.mode, ViewMode.focus);
    await tester.longPress(inPanel('flux1-dev.safetensors'));
    await choose('Show only images made with this model');
    await pumpUntil(tester, () => state.items.length == 4, what: 'one model');
    expect(state.mode, ViewMode.grid);
    expect(state.selected?.name, 'ComfyUI_00001_.png');

    // A tap still just copies.
    final copied = captureClipboard(tester);
    await tester.tap(inPanel('flux1-dev.safetensors'));
    await tester.pump();
    expect(copied.last, 'flux1-dev.safetensors');
    expect(state.searchText.text, 'model:=flux1-dev.safetensors');

    for (final file in extras) {
      file.deleteSync();
    }
    state.applySearch('');
    await pumpUntil(tester, () => state.items.length == 9, what: 'the nine');
    await close(tester, state);
  });

  testWidgets('usage stats count what a folder was made with, and filter by it', (
    tester,
  ) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');

    // The grid stays alive under the page, so look for things on the page.
    Finder onPage(String text) => find.descendant(
      of: find.byType(StatsPage),
      matching: find.text(text),
    );

    Future<void> open() async {
      await tester.tap(find.byTooltip('Usage stats'));
      await pumpUntil(
        tester,
        () => onPage('MODELS').evaluate().isNotEmpty,
        what: 'the usage page',
      );
      await settle(tester);
    }

    Future<void> closed() => pumpUntil(
      tester,
      () => find.byType(StatsPage).evaluate().isEmpty,
      what: 'the usage page to close',
    );

    /// The count shown beside [label] on the page.
    String countOf(String label) {
      final row = find.ancestor(
        of: onPage(label),
        matching: find.byType(InkWell),
      );
      final texts = tester.widgetList<Text>(
        find.descendant(of: row.first, matching: find.byType(Text)),
      );
      return texts.last.data!;
    }

    await open();
    expect(
      onPage('9 images  ·  8 with generation data  ·  sub-folders included'),
      findsOneWidget,
    );
    // Most used first, under each heading.
    expect(countOf('flux1-dev.safetensors'), '3');
    expect(countOf('Juggernaut XL v9'), '2');
    expect(countOf('sd_xl_base_1.0'), '2');
    expect(countOf('sd_xl_base_1.0.safetensors'), '1');
    expect(
      tester.getTopLeft(onPage('flux1-dev.safetensors')).dy,
      lessThan(tester.getTopLeft(onPage('Juggernaut XL v9')).dy),
    );
    expect(onPage('LORAS'), findsOneWidget);
    expect(countOf('cutaway-diagram-xl'), '2');
    expect(countOf('impasto'), '1');
    expect(countOf('style/inkwash_v2.safetensors'), '1');
    expect(onPage('MADE WITH'), findsOneWidget);
    expect(countOf('ComfyUI'), '4');
    expect(countOf('A1111'), '2');
    expect(countOf('InvokeAI'), '2');
    expect(onPage('PROMPT WORDS'), findsOneWidget);
    expect(countOf('lighthouse'), '2');
    expect(onPage('IMAGES PER DAY'), findsOneWidget);
    await screenshot(tester, boundary, '15-usage');

    // ---- tap a model: back at the grid, with only its images ----------------
    await tester.tap(onPage('Juggernaut XL v9'));
    await closed();
    await pumpUntil(tester, () => state.items.length == 2, what: 'one model');
    expect(state.searchText.text, 'model:="Juggernaut XL v9"');
    expect(state.items[0].dir, endsWith('portraits'));
    expect(inBar('2 matches'), findsOneWidget);

    // ---- a LoRA, a tool, a prompt word, a day --------------------------------
    await open();
    await tester.tap(onPage('impasto'));
    await closed();
    await pumpUntil(tester, () => state.items.length == 1, what: 'one LoRA');
    expect(state.searchText.text, 'lora:=impasto');
    expect(state.items[0].name, '00012-3958203417.png');

    await open();
    await tester.tap(onPage('ComfyUI'));
    await closed();
    await pumpUntil(tester, () => state.items.length == 4, what: 'one tool');
    expect(state.searchText.text, 'source:comfyui');

    await open();
    await tester.ensureVisible(onPage('lighthouse'));
    await tester.pump();
    await tester.tap(onPage('lighthouse'));
    await closed();
    await pumpUntil(tester, () => state.items.length == 2, what: 'one word');
    expect(state.searchText.text, 'prompt:=lighthouse');

    await open();
    await tester.tap(find.byTooltip('2026-10-01  ·  9 images'));
    await closed();
    await pumpUntil(tester, () => state.items.length == 9, what: 'one day');
    expect(state.searchText.text, 'date:2026-10-01');

    // ---- Esc and the arrow leave without changing anything -------------------
    await open();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await closed();
    await open();
    await tester.tap(find.byTooltip('Back to the grid (Esc)'));
    await closed();
    expect(state.searchText.text, 'date:2026-10-01');

    state.applySearch('');
    await close(tester, state);
  });

  testWidgets('an image copies, metadata and all, from its menu', (
    tester,
  ) async {
    final files = captureCopiedFiles(tester);
    final copied = captureClipboard(tester);
    final state = await launch(tester);
    await pumpUntil(
      tester,
      () => state.items.length == 9 && tilesWithImages(tester) == 9,
      what: '9 thumbnails',
    );
    final path = '${library.path}/ComfyUI_00001_.png';

    // ---- press and hold a tile ------------------------------------------------
    await tester.longPress(tiles().last);
    await settle(tester);
    expect(state.selected?.name, 'ComfyUI_00001_.png');
    expect(find.text('Copy image'), findsOneWidget);
    expect(find.text('Copy prompt'), findsOneWidget);
    expect(find.text('Copy file path'), findsOneWidget);
    await screenshot(tester, boundary, '16-image-menu');
    await tester.tap(find.text('Copy image'));
    await settle(tester);
    // The file itself was handed over, not a picture of it.
    expect(files, [path]);
    expect(find.text('Copied image'), findsOneWidget);
    expect(state.mode, ViewMode.grid);

    // ---- right-click works the same, on any tile ------------------------------
    await tester.tap(tiles().first, buttons: kSecondaryButton);
    await settle(tester);
    expect(state.selected?.name, 'plain-photo.png');
    await tester.tap(find.text('Copy file path'));
    await settle(tester);
    expect(copied.last, '${library.path}/plain-photo.png');

    await tester.tap(tiles().last, buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Copy prompt'));
    await pumpUntil(tester, () => copied.last == lighthouse, what: 'the prompt');

    // ---- Ctrl+Shift+C copies the selected image -------------------------------
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(files, [path, path]);

    // ---- and so does the menu in the focus view -------------------------------
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpUntil(
      tester,
      () => fullImageShown(tester),
      what: 'the full-size image',
    );
    await tester.longPress(find.byType(FocusView));
    await settle(tester);
    await tester.tap(find.text('Copy image'));
    await settle(tester);
    expect(files, [path, path, path]);
    expect(state.mode, ViewMode.focus);

    // ---- a file that cannot be copied says so ---------------------------------
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('generativeview/media'),
      (call) async => false,
    );
    await tester.tap(find.byType(FocusView), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Copy image'));
    // The toast before it has to leave first.
    await pumpUntil(
      tester,
      () => find.text('Could not copy this image').evaluate().isNotEmpty,
      what: 'being told the copy failed',
    );

    await tester.pump(const Duration(seconds: 2)); // let the toast go
    await close(tester, state);
  });

  testWidgets('zoom moves in steps of ten percent and marks 100%', (
    tester,
  ) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');
    if (state.rightOpen) state.toggleRight();
    // An image larger than the window, beside the small ones already there.
    final large = File('${library.path}/large.png')
      ..writeAsBytesSync(pngWithText(1400, 1400, 80, const {}));
    await pumpUntil(tester, () => state.items.length == 10, what: 'the image');
    int indexOf(String name) =>
        List.generate(state.items.length, (i) => state.items[i].name)
            .indexOf(name);

    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    Future<void> wheel(double dy) async {
      await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
      await tester.pump();
    }

    Future<Size> show(String name) async {
      if (state.mode == ViewMode.focus) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
      }
      state.openFocus(indexOf(name));
      await pumpUntil(
        tester,
        () => fullImageShown(tester),
        what: 'the full-size image',
      );
      await tester.sendEventToBinding(
        mouse.hover(tester.getCenter(find.byType(FocusView))),
      );
      return tester.getSize(find.byType(FocusView));
    }

    // The chip of the page on screen (its neighbours have chips of their own).
    ZoomChip chip() {
      final view = tester.getRect(find.byType(FocusView));
      final onScreen = find.byType(ZoomChip).evaluate().where((element) {
        final at = tester.getCenter(find.byWidget(element.widget));
        return view.contains(at);
      });
      return onScreen.single.widget as ZoomChip;
    }

    // ---- an image larger than the view: fitted, then up to and past 100% ----
    var view = await show('large.png');
    var fit = math.min(view.width, view.height) / 1400 * 100;
    expect(fit, lessThan(100));
    expect(chip().label, '${fit.round()}%');
    expect(chip().highlighted, isFalse);
    final above = (fit / 10).floor() * 10 + 10;
    for (var percent = above; percent <= 120; percent += 10) {
      await wheel(-120);
      expect(chip().label, '$percent%');
      // The coloured chip is for 100% alone.
      expect(chip().highlighted, percent == 100, reason: '$percent%');
    }
    await screenshot(tester, boundary, '17-zoom-120');
    await wheel(120);
    await wheel(120);
    expect(chip().label, '100%');
    expect(chip().highlighted, isTrue);
    await screenshot(tester, boundary, '18-zoom-100');
    // It stays for as long as the image is at 100%.
    await tester.pump(const Duration(seconds: 3));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: find.byWidget(chip()),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity,
      1,
    );
    // Back down: ten at a time, to the fitted size and no further.
    for (var percent = 90; percent > fit; percent -= 10) {
      await wheel(120);
      expect(chip().label, '$percent%');
    }
    await wheel(120);
    expect(chip().label, '${fit.round()}%');
    await wheel(120);
    expect(chip().label, '${fit.round()}%');
    expect(state.items[state.selectedIndex].name, 'large.png');
    // Away from 100% the chip fades once the zooming stops.
    await tester.pump(const Duration(seconds: 3));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: find.byWidget(chip()),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity,
      0,
    );

    // ---- an image smaller than the view: fitted is above 100% ---------------
    view = await show('ComfyUI_00001_.png');
    fit = math.min(view.width, view.height) / 384 * 100;
    expect(fit, greaterThan(200));
    expect(chip().label, '${fit.round()}%');
    final next = (fit / 10).floor() * 10 + 10;
    await wheel(-120);
    expect(chip().label, '$next%');
    // Down again stops at the fitted size on the way...
    await wheel(120);
    expect(chip().label, '${fit.round()}%');
    // ...and carries on to 100%, where it stops for good.
    for (var percent = next - 10; percent >= 100; percent -= 10) {
      await wheel(120);
      expect(chip().label, '$percent%');
    }
    expect(chip().highlighted, isTrue);
    await wheel(120);
    expect(chip().label, '100%');

    // ---- a pinch is free while it lasts, then settles on a multiple of ten --
    final centre = tester.getCenter(find.byType(FocusView));
    final one = await tester.startGesture(centre - const Offset(0, 40));
    final two = await tester.startGesture(
      centre + const Offset(0, 40),
      pointer: 7,
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await one.moveBy(const Offset(0, -9));
      await two.moveBy(const Offset(0, 9));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final during = int.parse(chip().label.replaceAll('%', ''));
    expect(during, greaterThan(110));
    await one.up();
    await two.up();
    // Whatever glide follows the fingers, then the move to the nearest stop.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final after = int.parse(chip().label.replaceAll('%', ''));
    expect(after, greaterThan(110));
    expect(
      after % 10 == 0 || after == fit.round(),
      isTrue,
      reason: 'settled on $after% from $during%',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    large.deleteSync();
    await pumpUntil(tester, () => state.items.length == 9, what: 'the nine');
    await close(tester, state);
  });

  testWidgets('content search finds pictures by what they show', (
    tester,
  ) async {
    // A small CLIP model with made-up weights stands in for the real one
    // (what it "sees" is arbitrary, but it is the real code that looks), and
    // a server on this machine stands in for the place it is fetched from.
    final model = Directory(
      '${Directory.current.path}/core/tests/fixtures/clip_mini',
    );
    const names = ['config.json', 'tokenizer.json', 'model.safetensors'];
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = saved);
    var refuse = true;
    final server = (await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final file = File('${model.path}/${request.uri.pathSegments.last}');
        if (refuse || !file.existsSync()) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.contentLength = file.lengthSync();
          await request.response.addStream(file.openRead());
        }
        await request.response.close();
      });
      return server;
    }))!;
    addTearDown(() => server.close(force: true));

    final state = await launch(
      tester,
      modelSource: 'http://127.0.0.1:${server.port}/',
      modelFiles: [
        for (final name in names)
          ModelFile(name, File('${model.path}/$name').lengthSync()),
      ],
    );
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');
    clearPins(state);
    expect(state.contentSearch, isFalse);
    // The stand-in model sees nothing in particular in any picture, so the
    // bar a picture has to clear is set by hand: on the floor here, so that
    // everything matches and what is checked is the order.
    state.contentBar = -1e6;

    final box = find.byWidgetPredicate(
      (w) => w is TextField && w.focusNode == state.searchFocus,
      description: 'the search box',
    );
    final banner = find.byKey(const ValueKey<String>('content-banner'));
    const toContent =
        'Searching prompts and metadata.\n'
        'Click to search by what the pictures show.';
    const toText =
        'Searching by what the pictures show.\n'
        'Click to search prompts and metadata.';
    List<String> shown() => [
      for (var i = 0; i < state.items.length; i++) state.items[i].name,
    ];
    Future<T> wait<T>(Future<T> future) async {
      T? value;
      var done = false;
      future.then((v) {
        value = v;
        done = true;
      });
      await pumpUntil(tester, () => done, what: 'the core to answer');
      return value as T;
    }

    // ---- the magnifying glass switches the kind of search -------------------
    await tester.tap(find.byTooltip(toContent));
    await pumpUntil(
      tester,
      () => state.content.value.known,
      what: 'content search to report in',
    );
    expect(state.contentSearch, isTrue);
    expect(find.byTooltip(toText), findsOneWidget);
    expect(
      tester.widget<TextField>(box).decoration?.hintText,
      'Describe what the picture shows',
    );
    // With nothing typed the folder is listed as usual.
    expect(state.items.length, 9);

    // ---- it needs a model first, and says so --------------------------------
    expect(state.content.value.installed, isFalse);
    expect(banner, findsOneWidget);
    expect(find.textContaining('one-time download of'), findsOneWidget);
    await tester.enterText(box, 'a lighthouse on a cliff');
    await pumpUntil(
      tester,
      () => find.text('Content search is not set up yet').evaluate().isNotEmpty,
      what: 'being told there is no model',
    );
    expect(state.items.length, 0);
    await screenshot(tester, boundary, '19-content-search-setup');

    // ---- a download that fails says so and can be tried again ---------------
    await tester.tap(find.text('Download'));
    await pumpUntil(
      tester,
      () => find.text('Try again').evaluate().isNotEmpty,
      what: 'the failed download to be reported',
    );
    expect(find.textContaining('The server answered 404'), findsOneWidget);
    expect(state.content.value.installed, isFalse);

    // ---- once fetched, the pictures are looked at and the search answers ----
    refuse = false;
    await tester.tap(find.text('Try again'));
    await pumpUntil(
      tester,
      () => state.content.value.installed,
      what: 'the model to be fetched',
      timeout: const Duration(seconds: 60),
    );
    final home = state.content.value.modelDir;
    expect(home, startsWith('${scratch.path}/data/models/'));
    for (final name in names) {
      expect(
        File('$home/$name').lengthSync(),
        File('${model.path}/$name').lengthSync(),
      );
      expect(File('$home/$name.part').existsSync(), isFalse);
    }
    await pumpUntil(
      tester,
      () =>
          state.content.value.embedded == 9 &&
          !state.content.value.indexing &&
          state.items.length == 9,
      what: 'every picture to be looked at',
      timeout: const Duration(seconds: 60),
    );
    expect(banner, findsNothing);
    expect(inBar('9 matches'), findsOneWidget);
    // Best match first: the order the core itself ranks them in.
    Future<List<String>> ranked(String text) async {
      final answer = await wait(
        core.call('content_query_json', {
          'dir': library.path,
          'recursive': true,
          'text': text,
          'bar': -1e6,
        }),
      );
      return [
        for (final row in (answer as Map)['rows'] as List)
          (row as List)[2] as String,
      ];
    }

    final cliff = await ranked('a lighthouse on a cliff');
    expect(cliff, hasLength(9));
    expect(shown(), cliff);
    await pumpUntil(
      tester,
      () => tilesWithImages(tester) == 9,
      what: 'the matches to be drawn',
    );
    await screenshot(tester, boundary, '20-content-search');

    await tester.enterText(box, 'a red fox');
    final fox = await ranked('a red fox');
    await pumpUntil(
      tester,
      () => shown().join() == fox.join(),
      what: 'the other description to be ranked',
    );
    expect(fox, isNot(cliff));

    // ---- only what matches is listed: with the bar out of reach, nothing ----
    state.contentBar = 1e6;
    await tester.enterText(box, 'a red fox asleep');
    await pumpUntil(
      tester,
      () =>
          state.items.isEmpty &&
          find
              .text('No picture here shows “a red fox asleep”')
              .evaluate()
              .isNotEmpty,
      what: 'a description nothing matches',
    );
    expect(inBar('0 matches'), findsOneWidget);
    state.contentBar = -1e6;
    await tester.enterText(box, 'a red fox');
    await pumpUntil(
      tester,
      () => shown().join() == fox.join(),
      what: 'the matches again',
    );

    // ---- and the matches can be put in another order -------------------------
    await tester.tap(find.byTooltip('Sort and refresh'));
    await settle(tester);
    await tester.tap(find.text('Name A to Z'));
    await pumpUntil(
      tester,
      () => shown().first == '00012-3958203417.png',
      what: 'the matches by name',
    );
    expect(shown(), [
      '00012-3958203417.png',
      '00013-1.png',
      'ComfyUI_00001_.png',
      'ComfyUI_00002_.png',
      'ComfyUI_00003_.png',
      'ComfyUI_00004_.png',
      'plain-photo.png',
      'a1b2c3.png',
      'd4e5f6.png',
    ]);
    state.setSort('relevance');
    await pumpUntil(
      tester,
      () => shown().join() == fox.join(),
      what: 'the best match first again',
    );

    // ---- a content search pins as one, and comes back as one ----------------
    await tester.tap(find.byTooltip('Pin this search'));
    await tester.pump();
    expect(state.pinnedSearches, [
      const PinnedSearch('a red fox', content: true),
    ]);

    // Back to searching the metadata: the same words now have to be there.
    await tester.tap(find.byTooltip(toText));
    await pumpUntil(
      tester,
      () => state.items.length == 1,
      what: 'the metadata search',
    );
    expect(state.contentSearch, isFalse);
    expect(shown(), ['ComfyUI_00002_.png']);
    expect(find.byTooltip('Pin this search'), findsOneWidget);

    await tester.enterText(box, '');
    await pumpUntil(tester, () => state.items.length == 9, what: 'everything');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('pinned-searches')),
        matching: find.text('a red fox'),
      ),
    );
    await pumpUntil(
      tester,
      () => state.contentSearch && shown().join() == fox.join(),
      what: 'the pinned content search to run',
    );
    expect(find.byTooltip(toText), findsOneWidget);

    // ---- a picture that arrives is looked at too -----------------------------
    final added = File('${library.path}/ComfyUI_00077_.png')
      ..writeAsBytesSync(pngWithText(384, 384, 77, const {}));
    await pumpUntil(
      tester,
      () => state.content.value.embedded == 10 && state.items.length == 10,
      what: 'the new picture to be looked at',
      timeout: const Duration(seconds: 60),
    );

    // ---- a filter from the metadata panel is a metadata search ---------------
    state.applyFilter('seed:=22');
    await pumpUntil(tester, () => state.items.length == 1, what: 'the filter');
    expect(state.contentSearch, isFalse);
    expect(state.searchText.text, 'seed:=22');

    added.deleteSync();
    clearPins(state);
    state.applySearch('');
    await pumpUntil(tester, () => state.items.length == 9, what: 'the nine');
    await close(tester, state);
  });

  testWidgets('panels, the search box and its switch move into place', (
    tester,
  ) async {
    final state = await launch(tester, motion: true);
    await pumpUntil(tester, () => state.items.length == 9, what: 'the listing');
    clearPins(state);
    // Whatever was saved, start with both panels shut.
    if (state.leftOpen) state.toggleLeft();
    if (state.rightOpen) state.toggleRight();
    await settle(tester);
    expect(find.byType(FolderPanel), findsNothing);
    expect(find.byType(MetaPanel), findsNothing);

    const part = Duration(milliseconds: 60);
    const rest = Duration(milliseconds: 500);
    double gridWidth() => tester.getSize(find.byType(MediaGrid)).width;
    final full = gridWidth();
    expect(full, 1440);

    // ---- the folder panel slides out and pushes the grid over ---------------
    const handle = 7.0;
    await tester.tap(find.byTooltip('Folders ([)'));
    await tester.pump();
    await tester.pump(part);
    var taken = state.leftWidth + handle;
    expect(find.byType(FolderPanel), findsOneWidget);
    expect(gridWidth(), allOf(lessThan(full), greaterThan(full - taken)));
    // The panel is uncovered at its full width, not squeezed into the gap.
    expect(tester.getSize(find.byType(FolderPanel)).width, state.leftWidth);
    await tester.pump(rest);
    expect(gridWidth(), closeTo(full - taken, 0.01));
    expect(tester.getRect(find.byType(FolderPanel)).left, 0);

    // ...and slides back, there until it is all the way in.
    await tester.tap(find.byTooltip('Folders ([)'));
    await tester.pump();
    await tester.pump(part);
    expect(state.leftOpen, isFalse);
    expect(find.byType(FolderPanel), findsOneWidget);
    expect(gridWidth(), allOf(lessThan(full), greaterThan(full - taken)));
    expect(tester.getRect(find.byType(FolderPanel)).left, lessThan(0));
    await tester.pump(rest);
    expect(find.byType(FolderPanel), findsNothing);
    expect(gridWidth(), full);

    // ---- so does the metadata panel, from the other side ---------------------
    await tester.tap(find.byTooltip('Generation data (I)'));
    await tester.pump();
    await tester.pump(part);
    taken = state.rightWidth + handle;
    expect(find.byType(MetaPanel), findsOneWidget);
    expect(gridWidth(), allOf(lessThan(full), greaterThan(full - taken)));
    expect(tester.getSize(find.byType(MetaPanel)).width, state.rightWidth);
    expect(tester.getRect(find.byType(MetaPanel)).right, greaterThan(1440));
    await tester.pump(rest);
    expect(gridWidth(), closeTo(full - taken, 0.01));
    expect(tester.getRect(find.byType(MetaPanel)).right, closeTo(1440, 0.01));

    await tester.tap(find.byTooltip('Generation data (I)'));
    await tester.pump();
    await tester.pump(part);
    expect(find.byType(MetaPanel), findsOneWidget);
    expect(gridWidth(), allOf(lessThan(full), greaterThan(full - taken)));
    await tester.pump(rest);
    expect(find.byType(MetaPanel), findsNothing);
    expect(gridWidth(), full);

    // ---- the search box grows over the folder's name while it is typed in ---
    double boxWidth() => tester.getSize(search).width;
    double boxRight() => tester.getRect(search).right;
    final resting = boxWidth();
    final edge = boxRight();
    expect(resting, 320);
    expect(inBar('library'), findsOneWidget);
    expect(inBar('9 items'), findsOneWidget);
    await tester.tap(search);
    await tester.pump();
    await tester.pump();
    await tester.pump(part);
    await tester.pump(part);
    expect(state.searchFocus.hasFocus, isTrue);
    expect(boxWidth(), allOf(greaterThan(resting), lessThan(760)));
    // It grows to the left: its right end stays where it was.
    expect(boxRight(), closeTo(edge, 0.01));
    await tester.pump(rest);
    expect(boxWidth(), 760);
    expect(boxRight(), closeTo(edge, 0.01));
    // The name has made way; the count is still there to see.
    expect(inBar('library'), findsNothing);
    expect(inBar('9 items'), findsOneWidget);
    await tester.enterText(search, 'lighthouse');
    await pumpUntil(
      tester,
      () => inBar('2 matches').evaluate().isNotEmpty,
      what: 'the count beside the grown box',
    );
    expect(boxWidth(), 760);

    // Put down, it shrinks back and the name returns.
    state.searchFocus.unfocus();
    await tester.pump();
    await tester.pump();
    await tester.pump(part);
    await tester.pump(part);
    expect(boxWidth(), allOf(greaterThan(resting), lessThan(760)));
    await tester.pump(rest);
    expect(boxWidth(), resting);
    expect(inBar('library'), findsOneWidget);
    expect(inBar('2 matches'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await pumpUntil(tester, () => state.items.length == 9, what: 'everything');

    // ---- the switch between the two kinds of search slides across -----------
    const toContent =
        'Searching prompts and metadata.\n'
        'Click to search by what the pictures show.';
    const toText =
        'Searching by what the pictures show.\n'
        'Click to search prompts and metadata.';
    final thumb = find.byKey(const ValueKey<String>('search-kind-thumb'));
    double thumbLeft() => tester.getTopLeft(thumb).dx;
    final home = thumbLeft();
    expect(state.contentSearch, isFalse);
    await tester.tap(find.byTooltip(toContent));
    await tester.pump();
    await tester.pump(part);
    expect(state.contentSearch, isTrue);
    expect(thumbLeft(), allOf(greaterThan(home), lessThan(home + 25)));
    await tester.pump(rest);
    expect(thumbLeft(), closeTo(home + 25, 0.01));
    expect(find.byTooltip(toText), findsOneWidget);
    await pumpUntil(
      tester,
      () => state.content.value.known,
      what: 'content search to report in',
    );

    await tester.tap(find.byTooltip(toText));
    await tester.pump();
    await tester.pump(part);
    expect(state.contentSearch, isFalse);
    expect(thumbLeft(), allOf(greaterThan(home), lessThan(home + 25)));
    await tester.pump(rest);
    expect(thumbLeft(), closeTo(home, 0.01));

    // ---- in a narrow window a panel slides in over the grid instead ---------
    tester.view.physicalSize = const Size(700, 500);
    await settle(tester);
    expect(gridWidth(), 700);
    await tester.tap(find.byTooltip('Folders ([)'));
    await tester.pump();
    await tester.pump(part);
    var panel = tester.getRect(find.byType(FolderPanel));
    expect(panel.left, allOf(lessThan(0), greaterThan(-panel.width)));
    expect(gridWidth(), 700);
    await tester.pump(rest);
    expect(tester.getRect(find.byType(FolderPanel)).left, 0);
    state.toggleLeft();
    await tester.pump();
    await tester.pump(part);
    panel = tester.getRect(find.byType(FolderPanel));
    expect(panel.left, allOf(lessThan(0), greaterThan(-panel.width)));
    await tester.pump(rest);
    expect(find.byType(FolderPanel), findsNothing);

    await close(tester, state);
  });
}
