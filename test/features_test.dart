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

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/backends.dart' show RemixImage;
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/prompt_weights.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/ui/media_grid.dart';
import 'package:generativeview/src/ui/meta_panel.dart';
import 'package:generativeview/src/ui/prompt_editor.dart';
import 'package:generativeview/src/ui/thumb_image.dart';

import 'support.dart';

void main() {
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

  const fixtures = ['fox_01.png', 'fox_02.png', 'fox_03.png', 'owl_01.png', 'heron.png', 'sailor.png'];

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
    await tester.tap(find.byKey(const ValueKey('filter-lora-fur_detail.safetensors')));
    await pumpUntil(tester, () => state.searchText.text == 'lora:=fur_detail.safetensors rating:>=4', what: 'and the LoRA');
    await pumpUntil(tester, () => state.items.length == 2, what: 'both foxes');
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
    final bigger = state.items[indexOf(state, 'heron_up2x.png')];
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
    out.deleteSync();
    bare.deleteSync();
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
    state.collectRemix(sailor, first.stream);
    state.collectRemix(owl, second.stream);
    await pumpUntil(tester, () => find.text('2 Remixes Running').evaluate().isNotEmpty, what: 'the running chip');
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
    sailorRemix.deleteSync();
    owlRemix.deleteSync();
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
      final before = calls.length;
      final at = tester.getCenter(find.text(entry));
      await tester.tap(find.text(entry));
      await settle(tester);
      await settle(tester);
      if (entry.startsWith('Paste') && calls.length == before) {
        final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().take(40).join(' | ');
        fail('"$entry" at $at led nowhere: menu still up: ${find.text(entry).evaluate().isNotEmpty}, '
            'menu items: ${find.byWidgetPredicate((w) => w is PopupMenuItem).evaluate().length}, texts: $texts');
      }
    }

    // ---- nothing on the clipboard ---------------------------------------------
    pasteAnswer = null;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
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
}
