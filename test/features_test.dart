// Ratings, flags and collections; the filter panel; the prompt editor with
// its weight slider and spelling check; look-alikes; new pictures; the
// keyboard shortcut list; and on-device upscaling — the real app against
// the real core, as in app_test.dart.
//
// The upscale itself runs when GV_UPSCALE_MODEL points at a Real-ESRGAN
// `realesr-general-x4v3.pth` (CI downloads it); otherwise only its panel is
// checked.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/backends.dart' show BackendException, RemixImage, RemixTicket;
import 'package:generativeview/src/core/civitai.dart';
import 'package:generativeview/src/core/lora_edits.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/prompt_weights.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/licenses.dart';
import 'package:generativeview/src/ui/about_panel.dart';
import 'package:generativeview/src/ui/media_grid.dart';
import 'package:generativeview/src/ui/filter_sheet.dart' show FilterSet;
import 'package:generativeview/src/ui/folder_panel.dart' show FolderPanel;
import 'package:generativeview/src/ui/meta_panel.dart';
import 'package:generativeview/src/ui/prompt_editor.dart';
import 'package:generativeview/src/ui/remix_dialog.dart';
import 'package:generativeview/src/ui/thumb_image.dart';
import 'package:generativeview/src/ui/upscale_dialog.dart'
    show HiresNotSent, defaultHiresScale, hiresScalesFor, hiresSize, madeOn, maxHiresScale, maxUpscaleFactor, refineUpscale, scaleText, upscaleFactors;

import 'support.dart';

void main() {
  const fixtures = ['fox_01.png', 'fox_02.png', 'fox_03.png', 'owl_01.png', 'heron.png', 'sailor.png'];
  late Directory scratch;
  late Directory library;
  late NativeCore core;
  final boundary = GlobalKey();

  setUpAll(() async {
    await loadAppFonts();
    scratch = Directory.systemTemp.createTempSync('gv-features-');
    library = Directory('${scratch.path}/library')..createSync();
    Directory('${library.path}/sub').createSync();
    var n = 0;
    void write(String name, Map<String, String> texts, {int w = 320, int h = 320}) {
      final file = File('${library.path}/$name');
      file.writeAsBytesSync(pngWithText(w, h, ++n * 5, texts));
      file.setLastModifiedSync(DateTime(2026, 10, 1, 12).add(Duration(minutes: n)));
    }

    write('fox_01.png', {'prompt': comfyGraph(prompt: 'a red fox in the snow, cinematic', seed: 1, lora: 'fur_detail.safetensors')});
    write('fox_02.png', {'prompt': comfyGraph(prompt: 'a red fox in the snow, cinematic', seed: 2, lora: 'fur_detail.safetensors')});
    write('fox_03.png', {'prompt': comfyGraph(prompt: 'a red fox at dawn, misty forest', seed: 3)});
    write('owl_01.png', {'prompt': comfyGraph(prompt: 'isometric clockwork owl, brass', seed: 4, checkpoint: 'sd_xl_base_1.0.safetensors')});
    write('heron.png', {'parameters': a1111Parameters('a brass heron, studio light', seed: 5)});
    write('sub/sailor.png', {'invokeai_metadata': invokeMetadata('portrait of an old sailor', seed: 6)}, w: 256, h: 384);

    core = NativeCore.start(dataDir: '${scratch.path}/data', cacheDir: '${scratch.path}/cache', libraryPath: coreLibraryPath());
  });

  tearDown(() {
    void clean(Directory dir) {
      for (final ent in dir.listSync()) {
        if (ent is File) {
          final name = ent.path.split(RegExp(r'[/\\]')).last;
          if (!fixtures.contains(name) && name != '.generativeview.json') {
            try { ent.deleteSync(); } catch (_) {}
          }
        } else if (ent is Directory) {
          clean(ent);
        }
      }
    }
    clean(library);
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
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = AppState(core: core, thumbs: ThumbCache(core, maxBytes: 64 << 20));
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: GenerativeViewApp(state: state)));
    var done = false;
    state.restore(initialFolder: library.path).whenComplete(() => done = true);
    await pumpUntil(tester, () => done, what: 'the folder to open');
    return state;
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump(const Duration(seconds: 5));
  }

  int thumbsShown(WidgetTester tester) => tester
      .widgetList<RawImage>(find.descendant(of: find.byType(MediaGrid), matching: find.byType(RawImage)))
      .where((w) => w.image != null)
      .length;

  List<String> names(AppState state) => [for (var i = 0; i < state.items.length; i++) state.items[i].name];

  int indexOf(AppState state, String name) => names(state).indexOf(name);

  Map<String, dynamic> notesFile(String dir) =>
      jsonDecode(File('$dir/.generativeview.json').readAsStringSync()) as Map<String, dynamic>;

  testWidgets('ratings, flags and collections live beside the pictures', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 6 && thumbsShown(tester) == 6, what: '6 thumbnails');
    if (!state.rightOpen) state.toggleRight();

    // ---- keys rate and flag the selected picture -----------------------------
    state.select(indexOf(state, 'fox_01.png'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await pumpUntil(tester, () => state.selected?.rating == 5, what: '5 stars');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await pumpUntil(tester, () => state.selected?.flag == Flag.keep, what: 'kept');
    expect(notesFile(library.path)['images']['fox_01.png'], {'rating': 5, 'flag': 'keep'});

    state.select(indexOf(state, 'fox_02.png'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await pumpUntil(tester, () => state.selected?.rating == 3, what: '3 stars');
    // The same number again clears it; then set it back.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await pumpUntil(tester, () => state.selected?.rating == 0, what: 'cleared');
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await pumpUntil(tester, () => state.selected?.rating == 4, what: '4 stars');

    state.select(indexOf(state, 'owl_01.png'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await pumpUntil(tester, () => state.selected?.flag == Flag.reject, what: 'rejected');

    // ---- the stars in the metadata panel do the same -------------------------
    state.select(indexOf(state, 'sailor.png'));
    await pumpUntil(tester, () => find.byKey(const ValueKey('star-2')).evaluate().isNotEmpty, what: 'the stars');
    await tester.tap(find.byKey(const ValueKey('star-2')));
    await pumpUntil(tester, () => state.selected?.rating == 2, what: '2 stars from the panel');
    // In its own folder's file.
    expect(notesFile('${library.path}/sub')['images']['sailor.png']['rating'], 2);

    // ---- a collection, from its panel ---------------------------------------
    state.select(indexOf(state, 'fox_01.png'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await pumpUntil(tester, () => find.byKey(const ValueKey('new-collection')).evaluate().isNotEmpty, what: 'the collection panel');
    await settle(tester);
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('new-collection')), 'Foxes');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpUntil(
      tester,
      () => (notesFile(library.path)['images']['fox_01.png'] as Map)['collections']?.toString() == '[Foxes]',
      what: 'the collection saved',
    );
    await screenshot(tester, boundary, '28-collections');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    // Listed in the folder panel; tapping it shows the collection.
    await pumpUntil(tester, () => find.text('COLLECTIONS').evaluate().isNotEmpty, what: 'the collections section');
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('collections')), matching: find.text('Foxes')));
    await pumpUntil(tester, () => names(state).join() == 'fox_01.png', what: 'the collection shown');
    expect(state.searchText.text, 'collection:=Foxes');
    state.applySearch('');
    await pumpUntil(tester, () => state.items.length == 6 && thumbsShown(tester) == 6, what: 'everything again');
    state.select(indexOf(state, 'fox_01.png'));
    await pumpUntil(tester, () => find.text('Foxes').evaluate().length >= 2, what: 'the chip in the panel');
    await screenshot(tester, boundary, '20-ratings');

    // ---- the files are the truth: edited elsewhere, the app follows ------------
    final file = File('${library.path}/.generativeview.json');
    final edited = notesFile(library.path);
    (edited['images'] as Map)['heron.png'] = {'rating': 1};
    file.writeAsStringSync(jsonEncode(edited));
    state.rescan();
    await pumpUntil(tester, () => state.items[indexOf(state, 'heron.png')].rating == 1, what: 'the edit from elsewhere');

    // ---- sorted best first ---------------------------------------------------
    await tester.tap(find.byTooltip('Sort and refresh'));
    await settle(tester);
    await tester.tap(find.text('Best rated first'));
    await settle(tester);
    await pumpUntil(tester, () => names(state).first == 'fox_01.png', what: 'best first');
    expect(names(state).sublist(0, 4), ['fox_01.png', 'fox_02.png', 'sailor.png', 'heron.png']);
    expect(names(state).last, 'owl_01.png', reason: 'rejected after the unrated');
    state.setSort('newest');
    await close(tester, state);
  });

  testWidgets('the filter panel narrows by facet, rating and flag', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 6 && thumbsShown(tester) == 6, what: '6 thumbnails');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await settle(tester);
    await pumpUntil(tester, () => find.byKey(const ValueKey('filter-stars-4')).evaluate().isNotEmpty, what: 'the filter panel');

    await tester.tap(find.byKey(const ValueKey('filter-stars-4')));
    await pumpUntil(tester, () => state.items.length == 2, what: '4 stars or more');
    expect(state.searchText.text, 'rating:>=4');
    // Below the Audience section: scrolled to first.
    await tester.ensureVisible(find.byKey(const ValueKey('filter-lora-fur_detail.safetensors')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('filter-lora-fur_detail.safetensors')));
    await pumpUntil(tester, () => state.searchText.text == 'lora:=fur_detail.safetensors rating:>=4', what: 'and the LoRA');
    await pumpUntil(tester, () => state.items.length == 2, what: 'both foxes');
    // Back up to the flags, above the Audience section.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('filter-flag-keep')),
      -200,
      scrollable: find.ancestor(of: find.byKey(const ValueKey('filter-lora-fur_detail.safetensors')), matching: find.byType(Scrollable)).first,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('filter-flag-keep')));
    await pumpUntil(tester, () => names(state).join() == 'fox_01.png', what: 'the kept one');
    expect(find.text('Show 1 picture'), findsOneWidget);
    await screenshot(tester, boundary, '21-filters');
    await tester.tap(find.byKey(const ValueKey('filters-done')));
    await settle(tester);
    // The button shows how many filters are on.
    expect(find.byTooltip('Filters (F)'), findsOneWidget);
    expect(find.text('3'), findsWidgets);

    // A typed word stays when filters change.
    state.applySearch('fox rating:>=4');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await settle(tester);
    await pumpUntil(tester, () => find.text('Clear filters').evaluate().isNotEmpty, what: 'the panel again');
    await tester.tap(find.text('Clear filters'));
    await pumpUntil(tester, () => state.searchText.text == 'fox', what: 'just the word');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // ---- prompts filter like any other value -----------------------------------
    state.applySearch('');
    await pumpUntil(tester, () => state.items.length == 6, what: 'everything');
    if (!state.rightOpen) state.toggleRight();
    state.select(indexOf(state, 'fox_02.png'));
    await pumpUntil(tester, () => find.text('PROMPT').evaluate().isNotEmpty, what: 'the prompt');
    await tester.longPress(find.descendant(of: find.byType(MetaPanel), matching: find.text('a red fox in the snow, cinematic')));
    await settle(tester);
    await tester.tap(find.text('Show only images with this prompt'));
    await pumpUntil(tester, () => state.items.length == 2, what: 'the same prompt');
    expect(state.searchText.text, 'fullprompt:="a red fox in the snow, cinematic"');
    expect(names(state)..sort(), ['fox_01.png', 'fox_02.png']);
    state.applySearch('');
    await close(tester, state);
  });

  testWidgets('the prompt editor weights selected words and checks spelling', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 6, what: 'the listing');
    state.select(indexOf(state, 'fox_03.png'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await settle(tester);
    await pumpUntil(tester, () => find.byKey(const ValueKey('remix-prompt')).evaluate().isNotEmpty, what: 'the remix panel');
    await settle(tester);
    final editor = tester.widget<PromptEditor>(find.byKey(const ValueKey('remix-prompt')));
    final c = editor.controller;
    expect(c.text, 'a red fox at dawn, misty forest');

    // ---- select words: a slider under them, 1.0 until moved -----------------------
    await tester.tap(find.byKey(const ValueKey('remix-prompt')));
    await tester.pump();
    c.selection = const TextSelection(baseOffset: 2, extentOffset: 9); // "red fox"
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('weight-slider')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('weight-value'))).data, '1.0');
    expect(c.text, 'a red fox at dawn, misty forest', reason: 'nothing changes until the slider moves');
    // Dragged right: heavier, in brackets with the number after.
    await tester.drag(find.byKey(const ValueKey('weight-slider')), const Offset(40, 0));
    await tester.pump();
    final heavier = RegExp(r'^a \(red fox:(1\.\d+)\) at dawn, misty forest$').firstMatch(c.text);
    expect(heavier, isNotNull, reason: c.text);
    expect(double.parse(heavier!.group(1)!), greaterThan(1));
    expect(c.selection.textInside(c.text), 'red fox', reason: 'still on the words');
    await screenshot(tester, boundary, '22-prompt-weights');
    // Dragged far left: down to the floor of 0.1, never past it.
    await tester.drag(find.byKey(const ValueKey('weight-slider')), const Offset(-600, 0));
    await tester.pump();
    expect(c.text, 'a (red fox:0.1) at dawn, misty forest');
    // Far right: 2.0 at most.
    await tester.drag(find.byKey(const ValueKey('weight-slider')), const Offset(900, 0));
    await tester.pump();
    expect(c.text, 'a (red fox:2.0) at dawn, misty forest');
    // Keys nudge it by a step.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(c.text, 'a (red fox:1.95) at dawn, misty forest');
    // And the cross takes the weight off.
    await tester.tap(find.byTooltip('Remove the weight'));
    await tester.pump();
    expect(c.text, 'a red fox at dawn, misty forest');

    // ---- a slip is underlined, and corrected from the caret ---------------------
    await pumpUntil(tester, () => c.spelling?.ready ?? false, what: 'the dictionary');
    c.value = const TextEditingValue(text: 'a red fox at dwan, misty forset', selection: TextSelection.collapsed(offset: 28));
    await tester.pump();
    await tester.pump();
    expect(c.misspelled('forset'), isTrue);
    expect(c.misspelled('dwan'), isTrue);
    expect(c.misspelled('misty'), isFalse);
    expect(c.misspelled('cinematic'), isFalse, reason: 'prompt words are known');
    expect(find.byKey(const ValueKey('spelling-popup')), findsOneWidget);
    await screenshot(tester, boundary, '23-spelling');
    await tester.tap(find.widgetWithText(ActionChip, 'forest'));
    await tester.pump();
    expect(c.text, 'a red fox at dwan, misty forest');
    expect(c.spelling!.suggest('dwan'), contains('dawn'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await close(tester, state);
  });

  testWidgets('weights round-trip as prompt syntax', (tester) async {
    TextEditingValue v(String text, int a, int b) => TextEditingValue(text: text, selection: TextSelection(baseOffset: a, extentOffset: b));
    // Sloppy selections take just the words.
    expect(applyWeight(v('cat, dog', 3, 8), 1.2).text, 'cat, (dog:1.2)');
    // Inside a group: its number changes.
    expect(applyWeight(v('a (b c:1.1) d', 3, 6), 0.7).text, 'a (b c:0.7) d');
    // The whole group, brackets and all, is the group too.
    expect(applyWeight(v('a (b c:1.1) d', 2, 11), 1.5).text, 'a (b c:1.5) d');
    expect(removeWeight(v('a (b c:1.1) d', 3, 6)).text, 'a b c d');
    expect(formatWeight(1), '1.0');
    expect(formatWeight(1.05), '1.05');
    expect(snapWeight(5), 2.0);
    expect(snapWeight(0), 0.1);
  });

  testWidgets('new pictures are marked, and followed when asked', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 6 && thumbsShown(tester) == 6, what: '6 thumbnails');
    // Made "now", while the folder is open.
    File('${library.path}/fresh_01.png').writeAsBytesSync(pngWithText(320, 320, 91, {'prompt': comfyGraph(prompt: 'a fresh fox', seed: 91)}));
    await pumpUntil(tester, () => state.items.length == 7 && state.fresh.length == 1, what: 'the new picture');
    expect(find.byKey(const ValueKey('new-pill')), findsOneWidget);
    expect(find.text('1 new picture'), findsOneWidget);
    await pumpUntil(tester, () => thumbsShown(tester) == 7, what: '7 thumbnails');
    await screenshot(tester, boundary, '26-new-pictures');
    await tester.tap(find.text('1 new picture'));
    await tester.pump();
    expect(state.selected?.name, 'fresh_01.png');
    expect(state.fresh, isEmpty, reason: 'seen');

    // Following: the newest arrival is selected, in the focus view too.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pump();
    expect(state.followNew, isTrue);
    state.openFocus(indexOf(state, 'heron.png'));
    await tester.pump();
    File('${library.path}/fresh_02.png').writeAsBytesSync(pngWithText(320, 320, 92, {'prompt': comfyGraph(prompt: 'a fresher fox', seed: 92)}));
    await pumpUntil(tester, () => state.selected?.name == 'fresh_02.png', what: 'following the new one');
    expect(state.mode, ViewMode.focus);
    state.toggleFollowNew();
    state.closeFocus();
    for (final name in ['fresh_01.png', 'fresh_02.png']) {
      File('${library.path}/$name').deleteSync();
    }
    await pumpUntil(tester, () => state.items.length == 6, what: 'gone again');
    await close(tester, state);
  });

  testWidgets('about, on a phone-sized screen', (tester) async {
    final state = await launch(tester, size: const Size(412, 915));
    await pumpUntil(tester, () => state.items.length == 6, what: 'the listing');
    await tester.tap(find.byKey(const ValueKey<String>('more-menu')));
    await settle(tester);
    await tester.tap(find.text('About GenerativeView'));
    await settle(tester);
    // The icon is drawn, on every screen size.
    await pumpUntil(
      tester,
      () => tester.widgetList<RawImage>(find.descendant(of: find.byKey(const ValueKey<String>('about-panel')), matching: find.byType(RawImage))).any((w) => w.image != null),
      what: 'the app icon on the About panel',
    );
    await settle(tester);
    expect(find.text('Josh Rufer'), findsOneWidget);
    await screenshot(tester, boundary, '25-about-phone');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await close(tester, state);
  });

  testWidgets('the keyboard shortcuts list, and the best rated', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 6, what: 'the listing');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Rate it (the same number again clears)'), findsOneWidget);
    await screenshot(tester, boundary, '24-shortcuts');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.text('Keyboard shortcuts'), findsNothing);
    // Back to the grid: the keys work again.
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settle(tester);
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // ---- about, from the More menu -------------------------------------------
    registerLicenses();
    await tester.tap(find.byKey(const ValueKey<String>('more-menu')));
    await settle(tester);
    await tester.tap(find.text('About GenerativeView'));
    await settle(tester);
    // The icon is drawn, on every screen size.
    await pumpUntil(
      tester,
      () => tester.widgetList<RawImage>(find.descendant(of: find.byKey(const ValueKey<String>('about-panel')), matching: find.byType(RawImage))).any((w) => w.image != null),
      what: 'the app icon on the About panel',
    );
    await settle(tester);
    expect(find.text('GenerativeView'), findsWidgets);
    expect(find.text('Josh Rufer'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('about-github')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('about-website')), findsOneWidget);
    await screenshot(tester, boundary, '25-about');
    // Every credit is listed, with somewhere to go: scroll through the
    // panel, noting each one that comes into view.
    final aboutList = find.byKey(const ValueKey<String>('about-panel'));
    final names = [for (final (_, list) in credits) for (final c in list) c.name];
    for (final (_, list) in credits) {
      for (final c in list) {
        expect(c.url, startsWith('https://'), reason: c.name);
      }
    }
    final seen = <String>{};
    for (var step = 0; step < 40 && seen.length < names.length; step++) {
      seen.addAll(names.where((n) => find.text(n).evaluate().isNotEmpty));
      if (step == 4) await screenshot(tester, boundary, '26-about-credits');
      await tester.drag(aboutList, const Offset(0, -250), warnIfMissed: false);
      await settle(tester);
    }
    expect(names.toSet().difference(seen), isEmpty);
    // The MIT licence text, its button at the top.
    await tester.drag(aboutList, const Offset(0, 6000), warnIfMissed: false);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('about-mit')));
    await settle(tester);
    expect(find.textContaining('Permission is hereby granted'), findsOneWidget);
    expect(find.textContaining('Joshua Hamilton Rufer'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    // The licences page carries the Rust crates and native libraries too.
    await tester.tap(find.byKey(const ValueKey<String>('about-licences')));
    await settle(tester);
    // The page opens; what it lists is checked by licenses_test.dart.
    expect(find.byType(LicensePage), findsOneWidget);
    for (var i = 0; i < 10 && find.textContaining('rusqlite').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await screenshot(tester, boundary, '27-licences');
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('about-panel')), findsNothing);

    // ---- best rated, on the usage page ---------------------------------------
    await tester.tap(find.byTooltip('Usage stats'));
    await settle(tester);
    await pumpUntil(tester, () => find.text('Best rated').evaluate().isNotEmpty, what: 'the usage page');
    await tester.tap(find.text('Best rated'));
    await settle(tester);
    await pumpUntil(tester, () => find.text('fur_detail.safetensors').evaluate().isNotEmpty, what: 'the ranking');
    await pumpUntil(
      tester,
      () => tester.widgetList<RawImage>(find.descendant(of: find.byType(ThumbImage), matching: find.byType(RawImage))).any((w) => w.image != null),
      what: 'sample thumbnails',
    );
    expect(find.text('4.5'), findsWidgets, reason: 'the LoRA of a 5 and a 4');
    await screenshot(tester, boundary, '27-best-rated');
    await tester.tap(find.text('fur_detail.safetensors'));
    await settle(tester);
    await pumpUntil(tester, () => state.items.length == 2, what: 'its pictures');
    state.applySearch('');
    await close(tester, state);
  });

  testWidgets('the mouse back and forward buttons', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 6, what: 'the listing');
    Future<void> click(int button) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: button);
      await mouse.down(const Offset(720, 450));
      await mouse.up();
      await mouse.removePointer();
      await settle(tester);
    }

    if (state.leftOpen) state.toggleLeft();
    if (state.rightOpen) state.toggleRight();
    state.select(indexOf(state, 'fox_01.png'));
    state.openFocus();
    await tester.pump();

    // Back from a picture: the grid, folders still hidden.
    await click(kBackMouseButton);
    expect(state.mode, ViewMode.grid);
    expect(state.leftOpen, isFalse);
    // Back in the grid: the folders open, and stay open.
    await click(kBackMouseButton);
    expect(state.leftOpen, isTrue);
    await click(kBackMouseButton);
    expect(state.leftOpen, isTrue);
    expect(state.mode, ViewMode.grid);
    // Forward: the generation data, on and off, in either view.
    await click(kForwardMouseButton);
    expect(state.rightOpen, isTrue);
    state.openFocus();
    await tester.pump();
    await click(kForwardMouseButton);
    expect(state.rightOpen, isFalse);
    // The middle button does the same.
    await click(kMiddleMouseButton);
    expect(state.rightOpen, isTrue);
    await click(kMiddleMouseButton);
    expect(state.rightOpen, isFalse);

    // With the remix panel up, neither button does anything.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await settle(tester);
    await pumpUntil(tester, () => find.byKey(const ValueKey('remix-prompt')).evaluate().isNotEmpty, what: 'the remix panel');
    await click(kBackMouseButton);
    await click(kForwardMouseButton);
    await click(kMiddleMouseButton);
    expect(find.byKey(const ValueKey('remix-prompt')), findsOneWidget);
    expect(state.mode, ViewMode.focus);
    expect(state.rightOpen, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    state.closeFocus();
    await close(tester, state);
  });

  testWidgets('upscale on the device, with or without the metadata', (tester) async {
    final model = Platform.environment['GV_UPSCALE_MODEL'] ?? '';
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 6, what: 'the listing');
    final models = await tester.runAsync(state.upscaleModels);
    if (model.isNotEmpty && File(model).existsSync()) {
      Directory(models!.dir).createSync(recursive: true);
      File(model).copySync('${models.dir}/realesr-general-x4v3.pth');
    }
    state.select(indexOf(state, 'heron.png'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
    await pumpUntil(tester, () => find.byKey(const ValueKey('upscale-start')).evaluate().isNotEmpty, what: 'the upscale panel');
    await settle(tester);
    expect(find.text('Real-ESRGAN general'), findsOneWidget);
    expect(find.text('Real-ESRGAN anime'), findsOneWidget);
    expect(find.text('320 × 320 to 640 × 640'), findsOneWidget);
    await screenshot(tester, boundary, '25-upscale');
    if (model.isEmpty) {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await close(tester, state);
      return;
    }
    await tester.tap(find.byKey(const ValueKey('upscale-start')));
    await settle(tester);
    final out = File('${library.path}/heron_up2x.png');
    await pumpUntil(tester, () => out.existsSync() && state.upscales.value.isEmpty, what: 'the upscale', timeout: const Duration(minutes: 3));
    // The original's metadata, byte for byte: it reads the same.
    await pumpUntil(tester, () => names(state).contains('heron_up2x.png'), what: 'the upscale in the grid');
    // Done, in the Upscales collection, and waiting on the round button to
    // be gone to.
    await pumpUntil(tester, () => state.upscaled.value.isNotEmpty, what: 'the upscale done');
    expect(state.upscaled.value.single.replaceAll(r'\', '/'), endsWith('/heron_up2x.png'));
    state.dismissDoneUpscales();
    final bigger = state.items[indexOf(state, 'heron_up2x.png')];
    final upNote = await tester.runAsync(() => state.notes(bigger));
    expect(upNote!.collections, [AppState.upscaleCollection]);
    expect((bigger.width, bigger.height), (640, 640));
    final info = await tester.runAsync(() => state.metadata(bigger));
    expect(info!.prompt, 'a brass heron, studio light');
    expect(info.seed, '5');
    // And stripped, nothing.
    state.select(indexOf(state, 'heron.png'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await pumpUntil(tester, () => find.byKey(const ValueKey('upscale-strip-metadata')).evaluate().isNotEmpty, what: 'the upscale panel again');
    await tester.tap(find.byKey(const ValueKey('upscale-strip-metadata')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('upscale-start')));
    await settle(tester);
    final bare = File('${library.path}/heron_up2x-2.png');
    await pumpUntil(tester, () => bare.existsSync() && state.upscales.value.isEmpty, what: 'the stripped upscale', timeout: const Duration(minutes: 3));
    await pumpUntil(tester, () => names(state).contains('heron_up2x-2.png'), what: 'it in the grid');
    final plain = await tester.runAsync(() => state.metadata(state.items[indexOf(state, 'heron_up2x-2.png')]));
    expect(plain!.hasGeneration, isFalse);
    // Leave the Upscales collection as it was for the tests that follow.
    await tester.runAsync(() => state.core.call('notes_set', {
          'paths': [out.path, bare.path],
          'remove': [AppState.upscaleCollection],
        }));
    out.deleteSync();
    bare.deleteSync();
    await close(tester, state);
  });
  testWidgets('hires fix: the upscale goes to a server as image to image, and what comes back is saved as name_hires1', (tester) async {
    // A Forge on this machine that takes the image to image and answers with
    // a picture, as Forge does.
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = saved);
    final bodies = <Map<String, dynamic>>[];
    final paths = <String>[];
    final server = (await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        paths.add(request.uri.path);
        final body = await utf8.decoder.bind(request).join();
        if (body.isNotEmpty) bodies.add(jsonDecode(body) as Map<String, dynamic>);
        final picture = File('${library.path}/heron.png').readAsBytesSync();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'images': [base64Encode(picture)], 'info': '{}'}));
        await request.response.close();
      });
      return server;
    }))!;
    addTearDown(() => server.close(force: true));

    final state = await launch(tester);
    await pumpUntil(tester, () => indexOf(state, 'heron.png') >= 0, what: 'the listing');
    state.setBackendUrl('forge', 'http://127.0.0.1:${server.port}');

    // ---- the panel: the switch, the server, the size it will be made at ----
    state.select(indexOf(state, 'heron.png'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await pumpUntil(tester, () => find.byKey(const ValueKey('hires-switch')).evaluate().isNotEmpty, what: 'the upscale panel');
    await settle(tester);
    expect(find.byKey(const ValueKey('hires-strength')), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('hires-switch')));
    await tester.tap(find.byKey(const ValueKey('hires-switch')));
    await settle(tester);
    expect(find.byKey(const ValueKey('hires-server-forge')), findsOneWidget);
    expect(find.byKey(const ValueKey('hires-strength')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('hires-strength-value'))).data, '0.35');
    // The upscale's own sizes give way to the hires ones, which run from
    // the picture's own size up as far as the server is asked to go.
    expect(find.byKey(const ValueKey('upscale-factor-16')), findsNothing);
    expect(find.byKey(const ValueKey('hires-scale-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('hires-scale-1.5')), findsOneWidget);
    expect(find.byKey(const ValueKey('hires-scale-4')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('upscale-size'))).data, '320 × 320 to 640 × 640');
    await tester.tap(find.byKey(const ValueKey('hires-scale-1.5')));
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(const ValueKey('upscale-size'))).data, '320 × 320 to 480 × 480');
    expect(tester.widget<Text>(find.byKey(const ValueKey('upscale-saved-as'))).data, contains('heron_hires1'));
    // 'Upscale and refine', or 'Download, upscale and refine' while the model is not here.
    expect(find.textContaining(RegExp('[Uu]pscale and refine\$')), findsOneWidget);
    // At its own size: nothing upscaled here, the picture itself is sent.
    await tester.tap(find.byKey(const ValueKey('hires-scale-1')));
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(const ValueKey('upscale-size'))).data, '320 × 320, redrawn at 320 × 320');
    expect(tester.widget<Text>(find.byKey(const ValueKey('upscale-saved-as'))).data, contains('at its own size'));
    expect(find.text('Refine'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // ---- the second half: the upscale sent on, and what comes back ---------
    // The original stands in for its upscale (the upscale itself is tested
    // above); what is sent is made at twice the original's size from it.
    final heron = state.items[indexOf(state, 'heron.png')];
    // Waited for by pumping, so a step that never finishes fails here,
    // saying which, rather than hanging the run.
    Future<T> waitFor<T>(Future<T> future, String what) async {
      T? value;
      Object? error;
      var done = false;
      future.then((v) {
        value = v;
        done = true;
      }, onError: (Object e) {
        error = e;
        done = true;
      });
      await pumpUntil(tester, () => done, what: what, timeout: const Duration(seconds: 60));
      if (error != null) throw error!;
      return value as T;
    }

    final message = await waitFor(
      refineUpscale(state, heron, heron.path, kind: 'forge', strength: 0.35, scale: 2),
      'the hires fix to be sent',
    );
    expect(message, contains('640 × 640'));
    final out = File('${library.path}/heron_hires1.png');
    await pumpUntil(tester, () => out.existsSync(), what: 'the hires fix to be saved');
    expect(paths, ['/sdapi/v1/img2img']);
    final sent = bodies.single;
    expect(sent['width'], 640);
    expect(sent['height'], 640);
    expect(sent['denoising_strength'], 0.35);
    expect(sent['seed'], 5);
    expect(sent['n_iter'], 1);
    expect(sent['prompt'], 'a brass heron, studio light');
    expect((sent['init_images'] as List).single, isA<String>());
    expect(sent.containsKey('mask'), isFalse);
    // It is an upscale: in the Upscales collection, not Remixes, and done
    // with the upscales.
    await pumpUntil(tester, () => names(state).contains('heron_hires1.png'), what: 'the hires fix in the grid');
    final note = await tester.runAsync(() => state.notes(state.items[indexOf(state, 'heron_hires1.png')]));
    expect(note!.collections, contains(AppState.upscaleCollection));
    expect(note.collections, isNot(contains(AppState.remixCollection)));
    await pumpUntil(tester, () => state.upscaled.value.any((p) => p.replaceAll(r'\', '/').endsWith('/heron_hires1.png')),
        what: 'the hires fix done with the upscales');
    expect(state.remixes.value, isEmpty);
    state.dismissDoneUpscales();
    // Leave the Upscales collection as it was for the tests that follow.
    await tester.runAsync(() => state.core.call('notes_set', {
          'paths': [out.path],
          'remove': [AppState.upscaleCollection],
        }));
    out.deleteSync();

    // A server not set up: not sent, and it says why, to be kept on the
    // round button rather than lost in a passing message.
    await expectLater(
      waitFor(refineUpscale(state, heron, heron.path, kind: 'comfyui', strength: 0.35, scale: 2), 'the refusal'),
      throwsA(isA<HiresNotSent>().having((e) => e.message, 'message', contains('ComfyUI is no longer set up'))),
    );

    // The sizes and names the panel works with.
    expect(hiresSize(832, 1216, 1.5), (1248, 1824));
    expect(scaleText(1.5), '1.5');
    expect(scaleText(1.25), '1.25');
    expect(scaleText(2), '2');
    expect(madeOn('a1111'), 'forge');
    expect(madeOn('swarmui'), isNull);
    // Forgotten before the app closes: settings are kept in the shared index.
    state.setBackendUrl('forge', '');
    await close(tester, state);
  });
  testWidgets('remixes show while they run, open the Remixes collection when done, and are picked out', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => indexOf(state, 'sailor.png') >= 0, what: 'the pictures');
    final sailor = state.items[indexOf(state, 'sailor.png')];
    final owl = state.items[indexOf(state, 'owl_01.png')];

    // Two out at once, in different folders.
    final first = StreamController<RemixImage>();
    final second = StreamController<RemixImage>();
    state.collectRemix(sailor, RemixTicket('', 1, first.stream));
    state.collectRemix(owl, RemixTicket('', 1, second.stream));
    // A small round button in the bottom right corner, clear of the
    // tiles' boxes, spinning, with how many on it.
    final button = find.byKey(const ValueKey('activity-button'));
    await pumpUntil(tester, () => button.evaluate().isNotEmpty, what: 'the activity button');
    await settle(tester);
    expect(find.byKey(const ValueKey('activity-spinner')), findsOneWidget);
    expect(find.text('2 Remixes Running'), findsNothing);
    final corner = tester.getBottomRight(button);
    expect(corner.dx, greaterThan(1440 - 40));
    expect(corner.dy, greaterThan(900 - 40));
    expect(tester.getSize(button).width, lessThanOrEqualTo(56));
    expect(find.descendant(of: find.byKey(const ValueKey('activity-count')), matching: find.text('2')), findsOneWidget);
    // Tapped, it says what is running.
    await tester.tap(button);
    await settle(tester);
    expect(find.byKey(const ValueKey('activity-card')), findsOneWidget);
    expect(find.text('2 Remixes Running'), findsOneWidget);
    await screenshot(tester, boundary, '40-remix-running');

    // One comes back: it is saved beside its original and put in the
    // Remixes collection, which did not exist before. The other runs on.
    final before = await tester.runAsync(state.collections);
    expect(before!.any((c) => c.$1 == AppState.remixCollection), isFalse);
    first.add(RemixImage(pngWithText(256, 384, 99, const {})));
    unawaited(first.close());
    await pumpUntil(
      tester,
      () => find.text('Remix Done').evaluate().isNotEmpty && find.text('Remix Running').evaluate().isNotEmpty,
      what: 'one done, one running',
    );
    final sailorRemix = File('${library.path}/sub/sailor_remix1.png');
    expect(sailorRemix.existsSync(), isTrue);
    // The count is renders still to come, not how many were sent: one left.
    expect(find.descendant(of: find.byKey(const ValueKey('activity-count')), matching: find.text('1')), findsOneWidget);
    expect((notesFile('${library.path}/sub')['images']['sailor_remix1.png'] as Map)['collections'], [AppState.remixCollection]);

    second.add(RemixImage(pngWithText(320, 320, 98, const {})));
    unawaited(second.close());
    await pumpUntil(
      tester,
      () => find.text('2 Remixes Done').evaluate().isNotEmpty && find.textContaining('Running').evaluate().isEmpty,
      what: 'both done',
    );
    final owlRemix = File('${library.path}/owl_01_remix1.png');
    expect(owlRemix.existsSync(), isTrue);
    final after = await tester.runAsync(state.collections);
    expect(after!.any((c) => c.$1 == AppState.remixCollection && c.$2 == 2), isTrue);
    // All back: the button is a tick, with nothing left to count.
    expect(find.byKey(const ValueKey('activity-done-icon')), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-count')), findsNothing);
    expect(find.byKey(const ValueKey('activity-spinner')), findsNothing);

    // Tapped: the Remixes collection, both new pictures picked out.
    await tester.tap(find.text('2 Remixes Done'));
    await pumpUntil(
      tester,
      () => state.query.contains(AppState.remixCollection) && state.highlightIds.length == 2,
      what: 'the Remixes collection with the new pictures picked out',
    );
    expect(names(state)..sort(), ['owl_01_remix1.png', 'sailor_remix1.png']);
    expect(state.highlightIds, contains(state.selected!.id));
    expect(state.remixes.value, isEmpty);
    await screenshot(tester, boundary, '41-remixes-collection');
    await pumpUntil(tester, () => state.highlightIds.isEmpty, what: 'the highlight to end');
    expect(button, findsNothing);
    expect(find.byKey(const ValueKey('activity-card')), findsNothing);

    // With only that done, a tap on the tick goes straight to it.
    final third = StreamController<RemixImage>();
    state.collectRemix(owl, RemixTicket('', 1, third.stream));
    third.add(RemixImage(pngWithText(320, 320, 97, const {})));
    unawaited(third.close());
    await pumpUntil(tester, () => find.byKey(const ValueKey('activity-done-icon')).evaluate().isNotEmpty, what: 'the tick');
    await settle(tester);
    await tester.tap(button);
    await pumpUntil(tester, () => state.highlightIds.length == 1, what: 'the new remix picked out');
    expect(find.byKey(const ValueKey('activity-card')), findsNothing);
    expect(button, findsNothing);
    await pumpUntil(tester, () => state.highlightIds.isEmpty, what: 'the highlight to end');

    // A remix the server failed, or one that came back with nothing, is
    // kept on it too, saying which and why.
    state.collectRemix(owl, RemixTicket('', 1, Stream<RemixImage>.error(BackendException('InvokeAI: CUDA out of memory'))), label: 'hires');
    state.collectRemix(sailor, RemixTicket('', 1, const Stream<RemixImage>.empty()));
    await pumpUntil(tester, () => state.problems.value.length == 2, what: 'both failures kept');
    expect(state.problems.value, [
      'Hires fix of owl_01.png: InvokeAI: CUDA out of memory',
      'Remix of sailor.png: finished, but brought no picture back',
    ]);
    await pumpUntil(tester, () => find.byKey(const ValueKey('activity-problem-icon')).evaluate().isNotEmpty, what: 'them shown');
    state.dismissProblems();
    await pumpUntil(tester, () => button.evaluate().isEmpty, what: 'the button to go after the failures');

    // Something that went wrong is kept on it, in red, until put away.
    state.problems.value = ['heron.png: InvokeAI did not take the refine: out of memory'];
    await pumpUntil(tester, () => find.byKey(const ValueKey('activity-problem-icon')).evaluate().isNotEmpty, what: 'the problem shown');
    await settle(tester);
    await tester.tap(button);
    await settle(tester);
    expect(find.textContaining('did not take the refine: out of memory'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('activity-problems-dismiss')));
    await settle(tester);
    expect(state.problems.value, isEmpty);
    await pumpUntil(tester, () => button.evaluate().isEmpty, what: 'the button to go after the problem');

    // A hires fix being sent shows as running.
    state.afterUpscale.value = ['heron.png, then refined on InvokeAI'];
    await pumpUntil(tester, () => find.byKey(const ValueKey('activity-spinner')).evaluate().isNotEmpty, what: 'sending shown as running');
    await settle(tester);
    await tester.tap(button);
    await settle(tester);
    expect(find.text('Sending heron.png, then refined on InvokeAI'), findsOneWidget);
    state.afterUpscale.value = const [];
    await pumpUntil(tester, () => button.evaluate().isEmpty, what: 'the button to go after sending');

    // Pressed and held, it is put away without going there.
    final fourth = StreamController<RemixImage>();
    state.collectRemix(owl, RemixTicket('', 1, fourth.stream));
    fourth.add(RemixImage(pngWithText(320, 320, 96, const {})));
    unawaited(fourth.close());
    await pumpUntil(tester, () => find.byKey(const ValueKey('activity-done-icon')).evaluate().isNotEmpty, what: 'the tick again');
    await settle(tester);
    await tester.longPress(button);
    await settle(tester);
    expect(state.remixes.value, isEmpty);
    expect(state.highlightIds, isEmpty);
    await pumpUntil(tester, () => button.evaluate().isEmpty, what: 'the button to go');

    sailorRemix.deleteSync();
    owlRemix.deleteSync();
    for (final n in ['owl_01_remix2.png', 'owl_01_remix3.png']) {
      final f = File('${library.path}/$n');
      if (f.existsSync()) f.deleteSync();
    }
    await close(tester, state);
  });
  testWidgets('collections are deleted from their menu, after asking', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'the listing');
    if (!state.leftOpen) state.toggleLeft();
    await tester.runAsync(() => state.changeNotes(
          targets: [state.items[indexOf(state, 'owl_01.png')], state.items[indexOf(state, 'sailor.png')]],
          add: ['Doomed'],
        ));
    await pumpUntil(tester, () => find.byKey(const ValueKey('collection-Doomed')).evaluate().isNotEmpty, what: 'the collection listed');
    // Shown, so deleting it also stops showing it.
    await tester.tap(find.byKey(const ValueKey('collection-Doomed')));
    await pumpUntil(tester, () => state.items.length == 2, what: 'the collection shown');

    Future<void> openMenu() async {
      final row = find.byKey(const ValueKey('collection-Doomed'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await mouse.down(tester.getCenter(row));
      await mouse.up();
      await mouse.removePointer();
      await settle(tester);
    }

    // Said no to: nothing changes.
    await openMenu();
    await tester.tap(find.text('Delete collection…'));
    await settle(tester);
    expect(find.byKey(const ValueKey('confirm-dialog')), findsOneWidget);
    expect(find.textContaining('2 pictures'), findsOneWidget);
    await screenshot(tester, boundary, '42-delete-collection');
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    var left = await tester.runAsync(state.collections);
    expect(left!.any((c) => c.$1 == 'Doomed'), isTrue);

    // Said yes to: gone everywhere, the pictures still there.
    await openMenu();
    await tester.tap(find.text('Delete collection…'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-action')));
    await pumpUntil(tester, () => find.byKey(const ValueKey('collection-Doomed')).evaluate().isEmpty, what: 'the collection gone');
    left = await tester.runAsync(state.collections);
    expect(left!.any((c) => c.$1 == 'Doomed'), isFalse);
    expect(state.query, isEmpty);
    await pumpUntil(tester, () => !state.query.contains('collection') && fixtures.every((n) => indexOf(state, n) >= 0), what: 'everything again');
    expect(File('${library.path}/owl_01.png').existsSync(), isTrue);
    expect(notesFile('${library.path}/sub')['images']?['sailor.png']?['collections'], isNull);
    await close(tester, state);
  });

  testWidgets('pictures are pasted in, taken out of a collection, and deleted', (tester) async {
    const channel = MethodChannel('generativeview/media');
    final calls = <String>[];
    String trashAnswer = 'unsupported';
    Object? pasteAnswer;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'pasteSource':
          return pasteAnswer;
        case 'trashFile':
          if (trashAnswer == 'trashed') File((call.arguments as Map)['path'] as String).deleteSync();
          return trashAnswer;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    addTearDown(() {
      for (final f in library.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (name.startsWith('pasted-') || name == 'heron (2).png') f.deleteSync();
      }
    });

    final state = await launch(tester);
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'the listing');
    Future<void> menuOn(String name, String entry) async {
      state.select(indexOf(state, name));
      await tester.pump();
      final tile = find.byKey(ValueKey<int>(state.items[indexOf(state, name)].id));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await mouse.down(tile.evaluate().isNotEmpty ? tester.getCenter(tile) : const Offset(720, 450));
      await mouse.up();
      await mouse.removePointer();
      await pumpUntil(tester, () => find.text(entry).evaluate().isNotEmpty, what: 'the menu with "$entry"');
      // Let it finish opening: rows further down take taps once shown.
      await settle(tester);
      await tester.tap(find.text(entry));
      await settle(tester);
    }

    // ---- nothing on the clipboard ---------------------------------------------
    pasteAnswer = null;
    await tester.sendKeyDownEvent(primaryModifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(primaryModifier);
    await pumpUntil(tester, () => find.textContaining('Nothing to paste').evaluate().isNotEmpty, what: 'nothing to paste');

    // ---- a copied file arrives whole, beside its namesake --------------------
    pasteAnswer = {'path': '${library.path}/heron.png'};
    String? snack() {
      final bars = find.byType(SnackBar).evaluate();
      if (bars.isEmpty) return null;
      final texts = find.descendant(of: find.byWidget(bars.last.widget), matching: find.byType(Text)).evaluate();
      return texts.map((e) => (e.widget as Text).data).join(' ');
    }

    await menuOn('heron.png', 'Paste into this folder');
    await pumpUntil(tester, () => calls.where((c) => c == 'pasteSource').length == 2, what: 'the clipboard read from the menu');
    final copied = File('${library.path}/heron (2).png');
    await pumpUntil(tester, () => copied.existsSync() || (snack()?.contains('paste here') ?? false), what: 'the copy written');
    expect(copied.existsSync(), isTrue, reason: snack());
    await pumpUntil(tester, () => indexOf(state, 'heron (2).png') >= 0, what: 'the pasted copy listed');
    expect(File('${library.path}/heron (2).png').readAsBytesSync(), File('${library.path}/heron.png').readAsBytesSync());
    // A picture's bytes from a browser get a name of their own.
    pasteAnswer = {'bytes': pngWithText(64, 64, 77, const {}), 'type': 'image/png'};
    await menuOn('heron.png', 'Paste into this folder');
    await pumpUntil(tester, () => names(state).any((n) => n.startsWith('pasted-')), what: 'the pasted picture');
    final pasted = names(state).firstWhere((n) => n.startsWith('pasted-'));
    expect(pasted, endsWith('.png'));
    // Several copied files all arrive, not just the first.
    pasteAnswer = {
      'path': '${library.path}/heron.png',
      'more': [
        {'path': '${library.path}/owl_01.png'},
        {'path': '${library.path}/heron.png'},
      ],
    };
    await menuOn('heron.png', 'Paste into this folder');
    final multi = ['heron (3).png', 'owl_01 (2).png', 'heron (4).png'];
    await pumpUntil(tester, () => multi.every((n) => indexOf(state, n) >= 0), what: 'all three pasted');
    await pumpUntil(tester, () => snack()?.contains('Pasted 3 files') ?? false, what: 'the three-file toast');
    for (final n in multi) {
      File('${library.path}/$n').deleteSync();
    }
    state.rescan();
    await pumpUntil(tester, () => multi.every((n) => indexOf(state, n) < 0), what: 'the extra copies gone');

    // ---- in a collection, it can be taken out ----------------------------------
    final copy = state.items[indexOf(state, 'heron (2).png')];
    await tester.runAsync(() => state.changeNotes(targets: [copy], add: ['Herons']));
    state.applyFilter(exactTerm('collection', 'Herons'));
    await pumpUntil(tester, () => names(state).join() == 'heron (2).png', what: 'the collection');
    await menuOn('heron (2).png', 'Remove from "Herons"');
    await pumpUntil(tester, () => state.items.isEmpty, what: 'out of the collection');
    expect(File('${library.path}/heron (2).png').existsSync(), isTrue);
    state.applySearch('');
    await pumpUntil(tester, () => indexOf(state, 'heron (2).png') >= 0 && indexOf(state, pasted) >= 0, what: 'everything again');

    // ---- deleted, after asking: to the trash ---------------------------------
    trashAnswer = 'trashed';
    await menuOn('heron (2).png', 'Delete image…');
    expect(find.text('Move to trash'), findsOneWidget);
    await screenshot(tester, boundary, '43-delete-image');
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(calls, isNot(contains('trashFile')));
    expect(File('${library.path}/heron (2).png').existsSync(), isTrue);
    await menuOn('heron (2).png', 'Delete image…');
    await tester.tap(find.byKey(const ValueKey('confirm-action')));
    await pumpUntil(tester, () => indexOf(state, 'heron (2).png') < 0, what: 'trashed and forgotten');
    expect(File('${library.path}/heron (2).png').existsSync(), isFalse);
    expect(state.selected, isNotNull, reason: 'the selection moves to a neighbour');

    // ---- where there is no trash, asked again, then gone for good ---------------
    trashAnswer = 'unsupported';
    state.select(indexOf(state, pasted));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-action')));
    await settle(tester);
    expect(find.text('Delete permanently'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-action')));
    await pumpUntil(tester, () => indexOf(state, pasted) < 0, what: 'deleted for good');
    expect(File('${library.path}/$pasted').existsSync(), isFalse);
    await close(tester, state);
  });

  testWidgets('images or videos, and filters cleared from the button', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'the listing');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await pumpUntil(tester, () => find.byKey(const ValueKey('filter-type-videos')).evaluate().isNotEmpty, what: 'the filter panel');
    await tester.tap(find.byKey(const ValueKey('filter-type-videos')));
    await pumpUntil(tester, () => state.items.isEmpty, what: 'no videos here');
    expect(state.query, 'type:video');
    await tester.tap(find.byKey(const ValueKey('filter-type-images')));
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'all images');
    expect(state.query, 'type:image');
    await screenshot(tester, boundary, '44-images-or-videos');
    await tester.tap(find.byKey(const ValueKey('filters-done')));
    await settle(tester);

    // A word typed alongside stays when the filters are cleared.
    state.applySearch('fox type:image');
    await pumpUntil(tester, () => names(state).every((n) => n.startsWith('fox')) && state.items.length >= 3, what: 'foxes only');
    final button = find.byKey(const ValueKey('filter-button'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await mouse.down(tester.getCenter(button));
    await mouse.up();
    await mouse.removePointer();
    await settle(tester);
    await tester.tap(find.text('Clear filters'));
    await pumpUntil(tester, () => state.query == 'fox', what: 'the filters cleared');
    // And a long press, on a touch screen, finds the same menu.
    state.applySearch('fox type:video');
    await pumpUntil(tester, () => state.items.isEmpty, what: 'filtered again');
    await tester.longPress(button);
    await settle(tester);
    await tester.tap(find.text('Clear filters'));
    await pumpUntil(tester, () => state.query == 'fox', what: 'cleared by touch');
    // With nothing to clear there is no menu.
    await tester.longPress(button);
    await settle(tester);
    expect(find.text('Clear filters'), findsNothing);
    state.applySearch('');
    await close(tester, state);
  });

  testWidgets('the remix panel keeps its controls steady', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'the listing');
    state.select(indexOf(state, 'fox_03.png'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await pumpUntil(tester, () => find.byKey(const ValueKey('remix-random')).evaluate().isNotEmpty, what: 'the remix panel');
    await settle(tester);
    final random = find.byKey(const ValueKey('remix-random'));
    final before = tester.getSize(random);
    await tester.tap(random);
    await settle(tester);
    expect(tester.getSize(random), before, reason: 'ticking it does not resize it');
    await tester.tap(random);
    await settle(tester);
    expect(tester.getSize(random), before);
    // Width and height on one line, in one box.
    final width = tester.getRect(find.byKey(const ValueKey('remix-width')));
    final height = tester.getRect(find.byKey(const ValueKey('remix-height')));
    expect(width.center.dy, height.center.dy);
    expect(height.left, greaterThan(width.right));
    await screenshot(tester, boundary, '45-remix-controls');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await close(tester, state);
  });

  testWidgets('locked, width and height keep the picture\'s shape and say so', (tester) async {
    final width = TextEditingController(text: '832');
    final height = TextEditingController(text: '1216');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizeField(width: width, height: height, aspect: 832 / 1216))),
    ));
    BoxDecoration glow(String side) =>
        tester.widget<AnimatedContainer>(find.byKey(ValueKey('remix-$side-glow'))).decoration! as BoxDecoration;
    Icon lock() => tester.widget<Icon>(find.descendant(of: find.byKey(const ValueKey('remix-size-lock')), matching: find.byType(Icon)));

    // Locked to start with, and blue.
    expect(lock().icon, Icons.lock);
    expect(lock().color, isNot(Colors.white));
    // The lock sits above the swap button, between the two sides.
    final lockAt = tester.getCenter(find.byKey(const ValueKey('remix-size-lock')));
    final swapAt = tester.getCenter(find.byKey(const ValueKey('remix-size-swap')));
    expect(lockAt.dy, lessThan(swapAt.dy));
    expect(lockAt.dx, closeTo(swapAt.dx, 1));
    expect(lockAt.dx, greaterThan(tester.getRect(find.byKey(const ValueKey('remix-width'))).right));
    expect(lockAt.dx, lessThan(tester.getRect(find.byKey(const ValueKey('remix-height'))).left));

    // A new width brings the height along, and the height glows for a moment.
    await tester.enterText(find.byKey(const ValueKey('remix-width')), '1024');
    await tester.pump();
    expect(height.text, '${snapSize((1024 * 1216 / 832).round())}', reason: 'rounded to a size every server takes');
    expect((glow('height').border! as Border).top.color, isNot(Colors.transparent));
    expect((glow('width').border! as Border).top.color, Colors.transparent);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect((glow('height').border! as Border).top.color, Colors.transparent);
    // And the other way.
    await tester.enterText(find.byKey(const ValueKey('remix-height')), '608');
    await tester.pump();
    expect(width.text, '${snapSize((608 * 832 / 1216).round())}');
    expect((glow('width').border! as Border).top.color, isNot(Colors.transparent));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Turned on its side, it keeps the turned shape.
    await tester.tap(find.byKey(const ValueKey('remix-size-swap')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('remix-width')), '1216');
    await tester.pump();
    expect(height.text, '832');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Unlocked (white), each side is its own.
    await tester.tap(find.byKey(const ValueKey('remix-size-lock')));
    await tester.pump();
    expect(lock().icon, Icons.lock_open);
    expect(lock().color, Colors.white);
    await tester.enterText(find.byKey(const ValueKey('remix-width')), '500');
    await tester.pump();
    expect(height.text, '832');
    expect((glow('height').border! as Border).top.color, Colors.transparent);
    // An empty side brings nothing along.
    await tester.tap(find.byKey(const ValueKey('remix-size-lock')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('remix-width')), '');
    await tester.pump();
    expect(height.text, '832');
  });

  testWidgets('steps and CFG are folded away, set by slider or by typing, and can go back', (tester) async {
    final choice = SamplingChoice(steps: 20, cfg: 7);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 480, child: SamplingSection(choice: choice)),
        ),
      ),
    ));
    // Folded away to start with, the values on the heading.
    expect(find.byKey(const ValueKey('remix-steps-slider')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const ValueKey('remix-sampling-summary'))).data, '20 steps · CFG 7');
    await tester.tap(find.byKey(const ValueKey('remix-sampling-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remix-steps-slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('remix-cfg-slider')), findsOneWidget);
    expect(choice.sentSteps, isNull, reason: 'unchanged, sent as the picture had it');
    expect(choice.sentCfg, isNull);

    // Typed.
    await tester.enterText(find.byKey(const ValueKey('remix-steps')), '42');
    await tester.enterText(find.byKey(const ValueKey('remix-cfg')), '3.25');
    await tester.pump();
    expect(choice.sentSteps, 42);
    expect(choice.sentCfg, 3.25);
    expect(tester.widget<Text>(find.byKey(const ValueKey('remix-sampling-summary'))).data, '42 steps · CFG 3.25');

    // Slid (to the middle of 0 to 30): the box follows, in half steps.
    await tester.tap(find.byKey(const ValueKey('remix-cfg-slider')));
    await tester.pump();
    expect(choice.cfg, 15);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('remix-cfg'))).controller!.text, '15');

    // Back to the picture's own.
    await tester.tap(find.byKey(const ValueKey('remix-steps-reset')));
    await tester.tap(find.byKey(const ValueKey('remix-cfg-reset')));
    await tester.pump();
    expect(choice.sentSteps, isNull);
    expect(choice.sentCfg, isNull);
    expect(find.byKey(const ValueKey('remix-steps-reset')), findsNothing);
  });

  test('steps and CFG a picture does not record are left to the server until set', () {
    final choice = SamplingChoice();
    expect(choice.sentSteps, isNull);
    expect(choice.sentCfg, isNull);
    choice.steps = 25;
    choice.cfg = 5;
    expect(choice.sentSteps, 25);
    expect(choice.sentCfg, 5);
    expect(cfgText(7), '7');
    expect(cfgText(3.5), '3.5');
    expect(cfgText(10), '10');
    expect(cfgText(4.25), '4.25');
  });

  testWidgets('a LoRA weight slider starts at the picture\'s weight and shows how far it moved', (tester) async {
    final choice = LoraChoice(const LoraRef('loras/fur_detail.safetensors', 0.8, null, ''));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 424, child: LoraSection(loras: [choice])),
        ),
      ),
    ));
    // Folded away to start with.
    expect(find.byKey(const ValueKey('remix-lora-slider-0')), findsNothing);
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('remix-loras')));
    await tester.pumpAndSettle();
    expect(find.text('fur_detail'), findsOneWidget);
    expect(find.byKey(const ValueKey('remix-lora-switch-0')), findsOneWidget);
    expect(find.text('0.8'), findsOneWidget);
    expect(find.byKey(const ValueKey('remix-lora-offset-0')), findsNothing);
    // The slider is below the name.
    final slider = find.byKey(const ValueKey('remix-lora-slider-0'));
    expect(tester.getRect(slider).top, greaterThan(tester.getRect(find.text('fur_detail')).bottom));

    // A tap where 1.5 is: -1 to 2 across the track, inside 12 at each end.
    final rect = tester.getRect(slider);
    final track = rect.width - 24;
    Offset at(double v) => Offset(rect.left + 12 + (v + 1) / 3 * track, rect.center.dy);
    await tester.tapAt(at(1.5));
    await tester.pump();
    expect(choice.weight, closeTo(1.5, 1e-9));
    expect(find.text('1.5'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('remix-lora-offset-0'))).data, '+0.7');
    // Dragged down below zero: the offset goes the other way.
    await tester.dragFrom(at(1.5), Offset(at(-0.5).dx - at(1.5).dx, 0));
    await tester.pump();
    expect(choice.weight, closeTo(-0.5, 1e-9));
    expect(tester.widget<Text>(find.byKey(const ValueKey('remix-lora-offset-0'))).data, '−1.3');
    // Not past the ends.
    await tester.dragFrom(at(-0.5), const Offset(-400, 0));
    await tester.pump();
    expect(choice.weight, -1);
    // The arrow keys step it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(choice.weight, closeTo(-0.95, 1e-9));
    // Back to where the picture had it.
    await tester.tap(find.byKey(const ValueKey('remix-lora-reset-0')));
    await tester.pump();
    expect(choice.weight, 0.8);
    expect(find.byKey(const ValueKey('remix-lora-offset-0')), findsNothing);

    // Off: left out of the remix, and the slider will not move.
    await tester.tap(find.byKey(const ValueKey('remix-lora-switch-0')));
    await tester.pump();
    expect(choice.enabled, isFalse);
    expect(tester.widget<Text>(find.byKey(const ValueKey('remix-loras-summary'))).data, '1 · 1 off');
    await tester.tapAt(at(2));
    await tester.pump();
    expect(choice.weight, 0.8);
  });

  testWidgets('the remix panel lists the picture\'s LoRAs, folded away', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'the listing');
    state.select(indexOf(state, 'fox_01.png'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await pumpUntil(tester, () => find.byKey(const ValueKey('remix-loras')).evaluate().isNotEmpty, what: 'the LoRAs');
    await settle(tester);
    expect(find.byKey(const ValueKey('remix-lora-slider-0')), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('remix-loras')));
    await tester.tap(find.byKey(const ValueKey('remix-loras')));
    await settle(tester);
    expect(find.descendant(of: find.byType(LoraSection), matching: find.text('fur_detail')), findsOneWidget);
    expect(find.byKey(const ValueKey('remix-lora-slider-0')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('remix-lora-slider-0')));
    await settle(tester);
    final slider = tester.getRect(find.byKey(const ValueKey('remix-lora-slider-0')));
    await tester.tapAt(Offset(slider.left + 12 + (1.2 + 1) / 3 * (slider.width - 24), slider.center.dy));
    await settle(tester);
    await screenshot(tester, boundary, '47-remix-loras');
    // A picture without LoRAs has no such section.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    state.select(indexOf(state, 'fox_03.png'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await pumpUntil(tester, () => find.byKey(const ValueKey('remix-random')).evaluate().isNotEmpty, what: 'the remix panel');
    await settle(tester);
    expect(find.byKey(const ValueKey('remix-loras')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await close(tester, state);
  });

  testWidgets('pictures are ticked by their corner box and acted on together', (tester) async {
    final copied = captureCopiedFiles(tester);
    final state = await launch(tester);
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'the listing');
    MediaItem item(String name) => state.items[indexOf(state, name)];
    Finder box(String name) => find.byKey(ValueKey<String>('tile-check-${item(name).id}'));
    Finder tile(String name) => find.byKey(ValueKey<int>(item(name).id));

    // Every tile has an empty box in its top right corner.
    expect(box('fox_01.png'), findsOneWidget);
    final tileRect = tester.getRect(tile('fox_01.png'));
    final boxAt = tester.getCenter(box('fox_01.png'));
    expect(boxAt.dx, greaterThan(tileRect.center.dx));
    expect(boxAt.dy, lessThan(tileRect.center.dy));
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);

    // Tapping the box ticks it, without opening anything.
    await tester.tap(box('fox_01.png'));
    await tester.pump();
    expect(state.checkedCount, 1);
    expect(state.mode, ViewMode.grid);
    expect(tester.widget<Text>(find.byKey(const ValueKey('selection-count'))).data, '1 selected');
    // Once one is ticked, a tap anywhere on a tile ticks it, or unticks it.
    await tester.tap(tile('fox_02.png'));
    await tester.pump();
    await tester.tap(tile('owl_01.png'));
    await tester.pump();
    expect(state.checkedCount, 3);
    await tester.tap(tile('owl_01.png'));
    await tester.pump();
    expect(state.checkedItems.map((i) => i.name).toSet(), {'fox_01.png', 'fox_02.png'});
    expect(tester.widget<Text>(find.byKey(const ValueKey('selection-count'))).data, '2 selected');
    await screenshot(tester, boundary, '48-ticked');

    final owlFlag = item('owl_01.png').flag;
    final foxRating = item('fox_03.png').rating;
    // The menu on a ticked picture is for both, and has only what can be
    // done to both at once.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await mouse.down(tester.getCenter(tile('fox_02.png')));
    await mouse.up();
    await mouse.removePointer();
    await settle(tester);
    expect(find.text('Copy 2 images'), findsOneWidget);
    expect(find.text('Rate…'), findsOneWidget);
    expect(find.text('Keep all (P)'), findsNothing, reason: 'flags are set with P / X, not from the menu');
    expect(find.text('Reject all (X)'), findsNothing);
    expect(find.text('Upscale 2 images… (Shift U)'), findsOneWidget);
    expect(find.text('Delete 2 images…'), findsOneWidget);
    expect(find.text('Remix… (R)'), findsNothing);
    expect(find.text('More like this (L)'), findsNothing);
    expect(find.text('Copy prompt'), findsNothing);
    await screenshot(tester, boundary, '49-many-menu');
    // Close the menu (leaving the ticks alone), then flag both with the key.
    Navigator.of(tester.element(find.text('Rate…'))).pop();
    await settle(tester);
    expect(state.checkedCount, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await pumpUntil(tester, () => item('fox_01.png').flag == Flag.keep && item('fox_02.png').flag == Flag.keep, what: 'both kept');
    expect(item('owl_01.png').flag, owlFlag, reason: 'unticked: left alone');

    // Keys act on them all too.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await pumpUntil(tester, () => item('fox_01.png').rating == 4 && item('fox_02.png').rating == 4, what: 'both rated');
    expect(item('fox_03.png').rating, foxRating);
    await tester.sendKeyDownEvent(primaryModifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(primaryModifier);
    await tester.pump();
    expect(copied.toSet(), {normalizePath(item('fox_01.png').path), normalizePath(item('fox_02.png').path)});
    // Rated from the menu: the Rate entry asks how many stars.
    final again = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await again.down(tester.getCenter(tile('fox_01.png')));
    await again.up();
    await again.removePointer();
    await settle(tester);
    await tester.tap(find.text('Rate…'));
    await settle(tester);
    await tester.tap(find.textContaining('(2)'));
    await pumpUntil(tester, () => item('fox_01.png').rating == 2 && item('fox_02.png').rating == 2, what: 'both rated from the menu');

    // Esc unticks them all; the corner boxes are empty again.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state.checkedCount, 0);
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);

    // Ctrl-click ticks too; a plain click then ticks more.
    await tester.sendKeyDownEvent(primaryModifier);
    await tester.tap(tile('heron.png'));
    await tester.sendKeyUpEvent(primaryModifier);
    await tester.pump();
    expect(state.checkedItems.map((i) => i.name), ['heron.png']);
    expect(state.mode, ViewMode.grid);
    // Ctrl A ticks every picture listed; the bar's cross unticks them.
    await tester.sendKeyDownEvent(primaryModifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(primaryModifier);
    await tester.pump();
    expect(state.checkedCount, state.items.length);
    await tester.tap(find.byKey(const ValueKey('selection-clear')));
    await tester.pump();
    expect(state.checkedCount, 0);

    // One ticked picture alone gets the menu of one picture.
    await tester.tap(box('fox_03.png'));
    await tester.pump();
    final one = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await one.down(tester.getCenter(tile('fox_03.png')));
    await one.up();
    await one.removePointer();
    await settle(tester);
    expect(find.text('Remix… (R)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    // Tidy up the notes for the tests after.
    await tester.runAsync(() => state.changeNotes(targets: [item('fox_01.png'), item('fox_02.png')], rating: 0, flag: Flag.none));
    await close(tester, state);
  });

  testWidgets('pictures move to another folder with their notes: from the menu, by cut and paste, and by dragging', (tester) async {
    final sub = normalizePath('${library.path}/sub');
    final home = normalizePath(library.path);
    // Whatever happens, fox_03 goes home again for the tests after.
    addTearDown(() {
      final strayed = File('$sub/fox_03.png');
      if (strayed.existsSync()) strayed.renameSync('${library.path}/fox_03.png');
    });
    final state = await launch(tester);
    if (!state.leftOpen) state.toggleLeft();
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'the listing');
    MediaItem item(String name) => state.items[indexOf(state, name)];
    Finder tile(String name) => find.byKey(ValueKey<int>(item(name).id));
    bool inSub() => File('$sub/fox_03.png').existsSync() && !File('${library.path}/fox_03.png').existsSync();
    bool atHome() => File('${library.path}/fox_03.png').existsSync() && !File('$sub/fox_03.png').existsSync();
    Future<void> rightClick(Finder target) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await mouse.down(tester.getCenter(target));
      await mouse.up();
      await mouse.removePointer();
      await settle(tester);
    }

    // Stars and a collection to carry along.
    await tester.runAsync(() => state.changeNotes(targets: [item('fox_03.png')], rating: 4, add: ['Movers']));
    await pumpUntil(tester, () => item('fox_03.png').rating == 4, what: 'four stars');

    // From the menu: Move to… opens a picker at the picture's folder.
    state.select(indexOf(state, 'fox_03.png'));
    await tester.pump();
    await rightClick(tile('fox_03.png'));
    expect(find.text('Keep (P)'), findsNothing);
    await tester.tap(find.text('Move to… (M)'));
    await settle(tester);
    await pumpUntil(tester, () => find.byKey(const ValueKey<String>('move-browse-sub')).evaluate().isNotEmpty, what: 'the folders to pick from');
    expect(find.text('Already here'), findsOneWidget, reason: 'the folder it is in is not a choice');
    await screenshot(tester, boundary, '60-move-picker');
    await tester.tap(find.byKey(const ValueKey<String>('move-browse-sub')));
    await pumpUntil(tester, () => find.text('Move to sub').evaluate().isNotEmpty, what: 'the sub folder open');
    await tester.tap(find.byKey(const ValueKey<String>('move-here')));
    await pumpUntil(tester, inSub, what: 'the move');
    final subNotes = (notesFile(sub)['images'] as Map)['fox_03.png'] as Map;
    expect(subNotes['rating'], 4);
    expect(subNotes['collections'], ['Movers']);
    final homeImages = (File('$home/.generativeview.json').existsSync() ? notesFile(home)['images'] as Map? : null) ?? const {};
    expect(homeImages.containsKey('fox_03.png'), isFalse, reason: 'nothing left behind');
    // (The folder as the core lists it, which may be the real path behind a link.)
    expect(state.moveTargets.first, endsWith('/sub'));
    // Undo puts it back, notes and all.
    await pumpUntil(tester, () => find.byKey(const ValueKey<String>('undo-move')).evaluate().isNotEmpty, what: 'the Undo');
    await tester.tap(find.byKey(const ValueKey<String>('undo-move')));
    await pumpUntil(tester, atHome, what: 'the undo');
    await pumpUntil(tester, () => indexOf(state, 'fox_03.png') >= 0 && item('fox_03.png').rating == 4, what: 'back with its stars');

    // The picker remembers where things went.
    await rightClick(tile('fox_03.png'));
    await tester.tap(find.text('Move to… (M)'));
    await settle(tester);
    expect(find.byKey(ValueKey<String>('move-recent-${state.moveTargets.first}')), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    // Cut, then a folder's menu moves it there.
    state.toggleFolderPin(sub);
    await tester.pump();
    final pinnedSub = find.descendant(of: find.byKey(const ValueKey<String>('pinned-folders')), matching: find.text('sub'));
    expect(pinnedSub, findsOneWidget);
    state.select(indexOf(state, 'fox_03.png'));
    await tester.pump();
    await tester.sendKeyDownEvent(primaryModifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(primaryModifier);
    await tester.pump();
    expect(state.cutCount, 1);
    expect(find.byKey(const ValueKey<String>('tile-cut')), findsOneWidget);
    // Esc lets go of it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state.hasCut, isFalse);
    await tester.sendKeyDownEvent(primaryModifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(primaryModifier);
    await tester.pump();
    await rightClick(pinnedSub);
    expect(find.text('Paste here'), findsOneWidget);
    await screenshot(tester, boundary, '61-folder-menu-move');
    await tester.tap(find.text('Move the cut file here'));
    await pumpUntil(tester, inSub, what: 'the cut file to move');
    expect(state.hasCut, isFalse);
    await tester.runAsync(() => state.movePaths(['$sub/fox_03.png'], home, remember: false));
    await pumpUntil(tester, () => atHome() && indexOf(state, 'fox_03.png') >= 0, what: 'back home');
    await settle(tester);

    // Dragged with the mouse onto the pinned folder.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(tester.getCenter(tile('fox_03.png')));
    await mouse.moveBy(const Offset(20, 20));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('drag-feedback')), findsOneWidget);
    await mouse.moveTo(tester.getCenter(pinnedSub));
    await tester.pump();
    expect(state.folderDrag.value?.folder, sub);
    expect(find.text('Move to sub'), findsOneWidget);
    await screenshot(tester, boundary, '62-drag-to-folder');
    await mouse.up();
    await mouse.removePointer();
    await pumpUntil(tester, inSub, what: 'the drop');
    expect(state.folderDrag.value, isNull);
    expect(find.byKey(const ValueKey<String>('drag-feedback')), findsNothing);
    expect(((notesFile(sub)['images'] as Map)['fox_03.png'] as Map)['rating'], 4);

    // Tidy up for the tests after.
    await tester.runAsync(() => state.movePaths(['$sub/fox_03.png'], home, remember: false));
    await pumpUntil(tester, () => atHome() && indexOf(state, 'fox_03.png') >= 0, what: 'home again');
    await tester.runAsync(() => state.changeNotes(targets: [item('fox_03.png')], rating: 0, remove: ['Movers']));
    state.toggleFolderPin(sub);
    await close(tester, state);
  });

  testWidgets('near-duplicates only: the pictures with a twin, each pair together', (tester) async {
    // Pictures with something in them: a bright disc on a ramp, placed by
    // (cx, cy). Two pairs of all-but-identical ones, and one alone.
    Uint8List disc(double cx, double cy, int lift) {
      const w = 240, h = 320;
      final raw = Uint8List(h * (1 + w * 3));
      var o = 0;
      for (var y = 0; y < h; y++) {
        raw[o++] = 0;
        for (var x = 0; x < w; x++) {
          final ramp = (x + y) / (w + h) * 120;
          final d = math.sqrt(math.pow(x - cx * w, 2) + math.pow(y - cy * h, 2));
          final v = (ramp + (d < 45 ? 110 : 0)).round();
          raw[o++] = math.min(255, v + lift);
          raw[o++] = v;
          raw[o++] = v;
        }
      }
      return pngFromRows(w, h, raw);
    }

    final dir = Directory('${scratch.path}/twins')..createSync();
    addTearDown(() => dir.deleteSync(recursive: true));
    final pictures = {
      'a.png': disc(0.3, 0.4, 0),
      'b.png': disc(0.8, 0.8, 0),
      'c.png': disc(0.3, 0.4, 4),
      'd.png': disc(0.7, 0.2, 0),
      'e.png': disc(0.7, 0.2, 2),
    };
    var minute = 0;
    pictures.forEach((name, bytes) {
      File('${dir.path}/$name')
        ..writeAsBytesSync(bytes)
        ..setLastModifiedSync(DateTime(2026, 10, 2, 12, minute++));
    });

    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.isNotEmpty, what: 'the listing');
    await tester.runAsync(() => state.openFolder(dir.path));
    await pumpUntil(tester, () => state.items.length == 5, what: 'the twins folder');

    // Turned on in the filter panel.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await pumpUntil(tester, () => find.byKey(const ValueKey('filter-duplicates')).evaluate().isNotEmpty, what: 'the filter panel');
    await tester.tap(find.byKey(const ValueKey('filter-duplicates')));
    await pumpUntil(tester, () => state.items.length == 4, what: 'only the twins');
    expect(state.query, 'is:duplicate');
    expect(FilterSet.parse(state.query).duplicates, isTrue);
    final order = names(state);
    expect(order.toSet(), {'a.png', 'c.png', 'd.png', 'e.png'});
    // Each pair side by side.
    expect((order.indexOf('a.png') - order.indexOf('c.png')).abs(), 1);
    expect((order.indexOf('d.png') - order.indexOf('e.png')).abs(), 1);
    await screenshot(tester, boundary, '50-filter-duplicates');
    await tester.tap(find.byKey(const ValueKey('filters-done')));
    await settle(tester);
    await screenshot(tester, boundary, '51-near-duplicates');
    state.applySearch('');
    await tester.runAsync(() => state.openFolder(library.path));
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'back to the library');
    await close(tester, state);
  });

  testWidgets('a picture shared to the app opens with how it was made', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'the listing');
    if (state.rightOpen) state.toggleRight();
    state.applySearch('owl');
    await pumpUntil(tester, () => names(state).join() == 'owl_01.png', what: 'a search');
    await tester.runAsync(() => state.showShared(['${library.path}/fox_02.png']));
    await pumpUntil(tester, () => state.mode == ViewMode.focus && state.selected?.name == 'fox_02.png', what: 'the shared picture open');
    expect(state.query, '', reason: 'the search is cleared, so the picture is listed');
    expect(state.rightOpen, isTrue, reason: 'the generation data shows');
    state.closeFocus();
    state.toggleRight();
    await settle(tester);
    await close(tester, state);
  });

  testWidgets('trigger words are looked up when asked, and added with a tap', (tester) async {
    final prompt = TextEditingController(text: 'a red fox in the snow');
    final asked = <String>[];
    Future<CivitaiModel?> lookUp({required String name, String hash = '', String kind = ''}) async {
      asked.add(name);
      if (name.contains('unknown')) return null;
      return CivitaiModel(
        modelId: 1,
        versionId: 2,
        name: name,
        version: 'v1',
        type: 'LORA',
        baseModel: 'SDXL 1.0',
        trainedWords: name.contains('fur') ? ['furry detail', 'soft fur, fluffy'] : [],
        creator: 'someone',
        preview: null,
        matchedBy: 'name',
      );
    }

    final loras = [
      LoraChoice(const LoraRef('loras/fur_detail_test.safetensors', 0.8, null, '')),
      LoraChoice(const LoraRef('plain_test.safetensors', 1, null, '')),
      LoraChoice(const LoraRef('unknown_test.safetensors', 1, null, '')),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: 560, child: LoraSection(loras: loras, prompt: prompt, lookUp: lookUp)),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('remix-loras')));
    await tester.pumpAndSettle();
    // Nothing is asked until the button is pressed.
    expect(asked, isEmpty);
    expect(find.byKey(const ValueKey('remix-loras-missing')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('remix-lora-triggers')));
    await tester.pumpAndSettle();
    expect(asked, hasLength(3));
    expect(find.text('furry detail'), findsOneWidget);
    expect(find.text('soft fur, fluffy'), findsOneWidget);
    expect(find.byKey(const ValueKey('remix-lora-nowords-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('remix-lora-unknown-2')), findsOneWidget);
    // On, and none of its words in the prompt: said on the heading.
    expect(find.byKey(const ValueKey('remix-loras-missing')), findsOneWidget);
    expect(find.byKey(const ValueKey('remix-lora-triggers')), findsNothing, reason: 'all looked up');
    // A tap puts it at the start of the prompt.
    await tester.tap(find.byKey(const ValueKey('remix-lora-word-0-0')));
    await tester.pumpAndSettle();
    expect(prompt.text, 'furry detail, a red fox in the snow');
    expect(find.byKey(const ValueKey('remix-loras-missing')), findsNothing);
    // Turned off, a LoRA's missing words don't matter.
    prompt.text = 'a red fox';
    await tester.pump();
    expect(find.byKey(const ValueKey('remix-loras-missing')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('remix-lora-switch-0')));
    await tester.pump();
    expect(find.byKey(const ValueKey('remix-loras-missing')), findsNothing);
    // What was found is remembered: a new panel shows it without asking.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: 560, child: LoraSection(loras: [LoraChoice(loras[0].original)], prompt: prompt, lookUp: lookUp)),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('remix-loras')));
    await tester.pumpAndSettle();
    expect(find.text('furry detail'), findsOneWidget);
    expect(asked, hasLength(3), reason: 'not asked again');
    expect(find.byKey(const ValueKey('remix-lora-triggers')), findsNothing);
  });

  testWidgets('side panels resize by their grips and snap shut past half their least', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'the listing');
    if (!state.leftOpen) state.toggleLeft();
    state.setLeftWidth(320);
    await settle(tester);
    final grip = find.byKey(const ValueKey('resize-left'));
    expect(grip, findsOneWidget);
    await screenshot(tester, boundary, '46-resize-grips');

    // Wider and narrower.
    await tester.drag(grip, const Offset(60, 0));
    await settle(tester);
    expect(state.leftWidth, closeTo(380, 1));
    // Past the least, it sticks there and stays open.
    await tester.drag(grip, const Offset(-(380 - minLeftWidth) - 60, 0));
    await settle(tester);
    expect(state.leftOpen, isTrue);
    expect(state.leftWidth, minLeftWidth);
    // On past half of it, shut, and it will open at the size it had.
    state.setLeftWidth(300);
    await settle(tester);
    await tester.drag(grip, const Offset(-(300 - minLeftWidth / 2) - 30, 0));
    await settle(tester);
    expect(state.leftOpen, isFalse);
    expect(state.leftWidth, 300);
    state.toggleLeft();
    await settle(tester);

    // The metadata panel, from the other side.
    if (!state.rightOpen) state.toggleRight();
    state.select(0);
    await settle(tester);
    final right = find.byKey(const ValueKey('resize-right'));
    await tester.drag(right, Offset(state.rightWidth - minRightWidth / 2 + 30, 0));
    await settle(tester);
    expect(state.rightOpen, isFalse);
    await close(tester, state);
  });

  testWidgets('panels lying over the grid on a narrow screen resize by their grips too', (tester) async {
    // A Fold-sized window, wider than tall: both panels slide over the grid.
    final state = await launch(tester, size: const Size(800, 700));
    await pumpUntil(tester, () => fixtures.every((n) => indexOf(state, n) >= 0), what: 'the listing');
    expect(state.narrowLayout, isTrue);
    if (state.rightOpen) state.toggleRight();
    if (!state.leftOpen) state.toggleLeft();
    state.setLeftWidth(280);
    await settle(tester);
    final grip = find.byKey(const ValueKey('resize-left'));
    expect(grip, findsOneWidget);
    await screenshot(tester, boundary, '55-narrow-resize-left');
    await tester.drag(grip, const Offset(80, 0));
    await settle(tester);
    expect(state.leftWidth, closeTo(360, 1));
    expect(tester.getSize(find.byType(FolderPanel)).width, closeTo(360, 1));
    // Never so wide that no grid is left to tap.
    await tester.drag(grip, const Offset(600, 0));
    await settle(tester);
    expect(tester.getTopRight(grip).dx, lessThan(800 - 40));
    // Dragged shut, it closes like its button.
    state.setLeftWidth(300);
    await settle(tester);
    await tester.drag(grip, const Offset(-(300 - minLeftWidth / 2) - 30, 0));
    await settle(tester);
    expect(state.leftOpen, isFalse);
    expect(state.leftWidth, 300);

    // The metadata panel, from the other side.
    state.select(0);
    if (!state.rightOpen) state.toggleRight();
    state.setRightWidth(300);
    await settle(tester);
    final right = find.byKey(const ValueKey('resize-right'));
    expect(right, findsOneWidget);
    await tester.drag(right, const Offset(-60, 0));
    await settle(tester);
    expect(state.rightWidth, closeTo(360, 1));
    expect(tester.getSize(find.byType(MetaPanel)).width, closeTo(360, 1));
    await screenshot(tester, boundary, '56-narrow-resize-right');
    await close(tester, state);
  });

  testWidgets('filters show over the grid and come off one by one', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 6 && thumbsShown(tester) == 6, what: '6 thumbnails');
    await settle(tester);
    expect(find.byKey(const ValueKey('filter-bar')), findsNothing, reason: 'no filters, no bar');

    // A filter shows as a chip over the grid; its cross takes it off.
    state.applySearch('fox lora:=fur_detail.safetensors');
    await pumpUntil(tester, () => state.items.length == 2, what: 'the LoRA');
    await settle(tester);
    final chip = find.byKey(const ValueKey('filter-bar-lora-fur_detail.safetensors'));
    expect(chip, findsOneWidget);
    expect(find.text('LoRA: fur_detail.safetensors'), findsOneWidget);
    expect(find.text('Showing 2'), findsOneWidget);
    await tester.tap(find.descendant(of: chip, matching: find.byType(IconButton)));
    await pumpUntil(tester, () => state.query == 'fox', what: 'the filter off, the word kept');
    await settle(tester);
    expect(find.byKey(const ValueKey('filter-bar')), findsNothing);

    // Several at once; "Clear all" takes them off and keeps a typed word.
    state.applySearch('fox lora:=fur_detail.safetensors type:image');
    await pumpUntil(tester, () => state.items.length == 2, what: 'two filters');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('filter-bar-clear')));
    await pumpUntil(tester, () => state.query == 'fox', what: 'all cleared');
    state.applySearch('');
    await close(tester, state);
  });

  testWidgets('smart collections are saved beside the pictures, shown, edited and deleted', (tester) async {
    final state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 6 && thumbsShown(tester) == 6, what: '6 thumbnails');
    if (!state.leftOpen) state.toggleLeft();
    await settle(tester);
    expect(find.text('SMART COLLECTIONS'), findsOneWidget);

    // Filters over the grid, kept as a smart collection.
    state.applySearch('fox lora:=fur_detail.safetensors');
    await pumpUntil(tester, () => state.items.length == 2, what: 'the furry foxes');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('filter-bar-save')));
    await pumpUntil(tester, () => find.byKey(const ValueKey('smart-name')).evaluate().isNotEmpty, what: 'the editor');
    await settle(tester);
    // One rule per term, and the count of what they match.
    expect(find.byKey(const ValueKey('smart-field-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('smart-field-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('smart-field-2')), findsNothing);
    await pumpUntil(tester, () => find.text('2 pictures here match now', findRichText: true).evaluate().isNotEmpty, what: 'the count');
    await tester.enterText(find.byKey(const ValueKey('smart-name')), 'Furry foxes');
    await pumpUntil(tester, () => thumbsShown(tester) >= 2, what: 'the grid behind');
    await settle(tester);
    await screenshot(tester, boundary, '53-smart-editor');
    await tester.tap(find.byKey(const ValueKey('smart-save')));
    await pumpUntil(
      tester,
      () => File('${library.path}/.generativeview.json').existsSync() && jsonEncode(notesFile(library.path)['smart']) == jsonEncode([{'name': 'Furry foxes', 'query': 'fox lora:=fur_detail.safetensors'}]),
      what: 'the smart collection saved in the folder',
    );
    await settle(tester);
    // Listed with its count, and named over the grid while it shows.
    await pumpUntil(tester, () => find.byKey(const ValueKey('smart-Furry foxes')).evaluate().isNotEmpty, what: 'listed');
    expect(find.descendant(of: find.byKey(const ValueKey('smart-collections')), matching: find.text('2')), findsOneWidget);
    expect(state.showingSmart?.name, 'Furry foxes');
    expect(find.byKey(const ValueKey('filter-bar-smart')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-bar-save')), findsNothing);
    await screenshot(tester, boundary, '54-smart-collection-shown');

    // Tapped in the panel it shows, and tapped again it goes.
    await tester.tap(find.byKey(const ValueKey('smart-Furry foxes')));
    await pumpUntil(tester, () => state.query.isEmpty, what: 'tapped off');
    await tester.tap(find.byKey(const ValueKey('smart-Furry foxes')));
    await pumpUntil(tester, () => state.query == 'fox lora:=fur_detail.safetensors' && state.items.length == 2, what: 'tapped on');

    // Edited from the bar: renamed, a rule taken out.
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('filter-bar-edit-smart')));
    await pumpUntil(tester, () => find.byKey(const ValueKey('smart-delete')).evaluate().isNotEmpty, what: 'the editor, for a saved one');
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('smart-name')), 'Fox fur');
    await tester.tap(find.byKey(const ValueKey('smart-remove-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('smart-save')));
    await pumpUntil(
      tester,
      () => jsonEncode(notesFile(library.path)['smart']) == jsonEncode([{'name': 'Fox fur', 'query': 'lora:=fur_detail.safetensors'}]),
      what: 'renamed in place',
    );
    await pumpUntil(tester, () => state.query == 'lora:=fur_detail.safetensors', what: 'what shows follows the edit');

    // Deleted from its menu, after asking; the pictures stay.
    await settle(tester);
    final row = find.byKey(const ValueKey('smart-Fox fur'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await mouse.down(tester.getCenter(row));
    await mouse.up();
    await mouse.removePointer();
    await settle(tester);
    await tester.tap(find.text('Delete smart collection…'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-action')));
    await pumpUntil(tester, () => notesFile(library.path)['smart'] == null && state.query.isEmpty, what: 'deleted');
    await pumpUntil(tester, () => state.items.length == 6, what: 'every picture still there');
    await close(tester, state);
  });

  testWidgets('a fresh start comes back to the folder and search last showing', (tester) async {
    var state = await launch(tester);
    await pumpUntil(tester, () => state.items.length == 6, what: 'the folder');
    // Opened by the user, so remembered (a folder named on the command line is not).
    var reopened = false;
    state.openFolder(library.path).whenComplete(() => reopened = true);
    await pumpUntil(tester, () => reopened && state.items.length == 6, what: 'the folder opened by hand');
    state.applySearch('lora:=fur_detail.safetensors');
    await pumpUntil(tester, () => state.items.length == 2, what: 'filtered');
    await close(tester, state);

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    state = AppState(core: core, thumbs: ThumbCache(core, maxBytes: 64 << 20));
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: GenerativeViewApp(state: state)));
    var done = false;
    state.restore().whenComplete(() => done = true);
    await pumpUntil(tester, () => done, what: 'the app to start again');
    expect(state.folder, normalizePath(library.path));
    expect(state.query, 'lora:=fur_detail.safetensors');
    expect(state.searchText.text, 'lora:=fur_detail.safetensors');
    await pumpUntil(tester, () => state.items.length == 2, what: 'the same two pictures');

    // Back to how other tests expect to find it.
    state.applySearch('');
    await pumpUntil(tester, () => state.items.length == 6, what: 'everything');
    await close(tester, state);
  });

  test('upscale sizes are worked out from the picture, not fixed', () {
    MediaItem pic(int w, int h) =>
        MediaItem(id: 0, dir: '/x', name: 'p.png', isVideo: false, width: w, height: h, mtime: 0, size: 0, durationMs: 0);
    const models = UpscaleModels('', '', []);
    // Small: every step up to the cap of 16.
    expect(maxUpscaleFactor([pic(320, 320)], models), 16);
    expect(upscaleFactors(16), [1.5, 2, 3, 4, 6, 8, 12, 16]);
    // A usual size: as far as 8192 on a side and 40 megapixels allow, with
    // the largest offered past the last step.
    expect(maxUpscaleFactor([pic(1024, 1024)], models), 6.1);
    expect(upscaleFactors(6.1), [1.5, 2, 3, 4, 6]);
    expect(maxUpscaleFactor([pic(832, 1216)], models), 6.2);
    expect(upscaleFactors(6.2), [1.5, 2, 3, 4, 6, 6.2]);
    expect(upscaleFactors(1.7), [1.5, 1.7]);
    // Several: the largest decides.
    expect(maxUpscaleFactor([pic(512, 512), pic(2048, 2048)], models), 3);
    // Already large: nothing to offer, and it says 1.
    expect(maxUpscaleFactor([pic(8000, 5000)], models), 1);
    expect(upscaleFactors(1), isEmpty);
    // Unknown sizes keep to the model's own 4×.
    expect(maxUpscaleFactor([pic(0, 0)], models), 4);
    // The limits come from the core.
    expect(maxUpscaleFactor([pic(1000, 1000)], const UpscaleModels('', '', [], maxSide: 2000, maxPixels: 4000000)), 2);

    // A hires fix: the picture's own size always, larger as the server's
    // 4096 allows, never past 4×.
    expect(maxHiresScale([pic(512, 512)]), 4);
    expect(hiresScalesFor(4), [1, 1.25, 1.5, 2, 3, 4]);
    expect(maxHiresScale([pic(1536, 1536)]), 2.65);
    expect(hiresScalesFor(2.65), [1, 1.25, 1.5, 2, 2.65]);
    expect(maxHiresScale([pic(3000, 2000)]), 1.35);
    expect(hiresScalesFor(1.35), [1, 1.25, 1.35]);
    // Already past what a server is asked to go to: only its own size.
    expect(maxHiresScale([pic(5000, 3000)]), 1);
    expect(hiresScalesFor(1), [1]);
    // Where it starts: 2× unless that is heavy, then smaller, then 1.
    expect(defaultHiresScale([pic(832, 1216)], hiresScalesFor(maxHiresScale([pic(832, 1216)]))), 2);
    expect(defaultHiresScale([pic(1536, 1536)], hiresScalesFor(2.65)), 1.5);
    expect(defaultHiresScale([pic(2048, 2048)], hiresScalesFor(maxHiresScale([pic(2048, 2048)]))), 1.25);
    expect(defaultHiresScale([pic(3000, 2000)], hiresScalesFor(1.35)), 1);
  });
}
