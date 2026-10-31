// The artist tools against the real core: What Works on the usage page,
// Prompt Doctor in Remix, Breed, near-duplicates grouped with the best one
// marked, Describe for a picture with no generation data, and Find in the
// mask editor. Screenshots at the sizes of a Galaxy Z Fold 8 (closed and
// open) and a Galaxy Tab S10 Ultra, when GV_SCREENSHOT_DIR is set.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/prompt_edits.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/ui/kit.dart';
import 'package:generativeview/src/ui/mask_editor.dart' show heatToMask, smoothHeat;
import 'package:generativeview/src/ui/media_grid.dart' show BestBadge, MediaGrid;
import 'package:generativeview/src/ui/remix_dialog.dart' show openRemix;
import 'package:generativeview/src/ui/stats_page.dart' show openStats;

import 'support.dart';

/// Window sizes, in logical pixels.
const Size foldClosed = Size(476, 752);
const Size foldOpen = Size(932, 696);
const Size tabUltra = Size(1480, 924);

void main() {
  group('prompt edits', () {
    test('a phrase is found as whole words, whatever the case and spacing', () {
      final r = findPhrase('a Red  Fox, red_fox_tail, foxglove', 'red fox');
      expect(r?.start, 2);
      expect(findPhrase('foxglove', 'fox'), isNull);
      expect(findPhrase('x, red_fox', 'red fox')?.start, 3);
    });

    test('weighting, selecting, removing and adding phrases', () {
      final weighted = weightPhrase(const TextEditingValue(text: 'a fox, golden hour, snow'), 'golden hour', 1.3);
      expect(weighted.text, 'a fox, (golden hour:1.3), snow');
      expect(weighted.selection.textInside(weighted.text), 'golden hour');
      final selected = selectPhrase(const TextEditingValue(text: 'a fox, (golden hour:1.3)'), 'golden hour');
      expect(selected.selection.textInside(selected.text), 'golden hour');
      expect(removePhrases('a fox, masterpiece, snow, (best quality:1.2)', ['masterpiece', 'best quality']), 'a fox, snow');
      expect(removePhrases('8k, a fox', ['8k']), 'a fox');
      expect(addPhrase('a fox, snow', 'rim lighting'), 'a fox, snow, rim lighting');
      expect(addPhrase('a fox, rim lighting', 'Rim Lighting'), 'a fox, rim lighting');
      expect(addPhrase('', 'snow'), 'snow');
    });

    test('a prompt cut into phrases as content search reads it', () {
      expect(
        promptPhrases('masterpiece, (a red fox:1.2), [snow], <lora:fur_detail:0.8> misty_forest, a red fox'),
        ['masterpiece', 'a red fox', 'snow', 'misty forest'],
      );
      expect(promptPhrases(r'Link \(Zelda\), , 1.5'), ['Link (Zelda)']);
    });

    test('a heat map becomes a mask where it is hot', () {
      // Hot in the top left quarter only.
      final values = [for (var y = 0; y < 4; y++) for (var x = 0; x < 4; x++) (x < 2 && y < 2) ? 1.0 : 0.0];
      final heat = HeatMap(4, values, null);
      final smooth = smoothHeat(heat, 8);
      expect(smooth.first, greaterThan(0.9));
      expect(smooth.last, lessThan(0.1));
      final ops = heatToMask(heat, 0.5);
      expect(ops, isNotEmpty);
      for (final op in ops) {
        for (final p in op.points) {
          expect(p.dx, lessThanOrEqualTo(0.6));
          expect(p.dy, lessThanOrEqualTo(0.6));
        }
      }
      expect(heatToMask(heat, 1.5), isEmpty);
    });
  });

  late Directory scratch;
  late Directory library;
  late NativeCore core;
  final boundary = GlobalKey();

  setUpAll(() async {
    await loadAppFonts();
    scratch = Directory.systemTemp.createTempSync('gv-artist-');
    library = Directory('${scratch.path}/library')..createSync();
    var n = 0;
    void write(String name, Map<String, String> texts, {int? seed}) {
      final file = File('${library.path}/$name');
      file.writeAsBytesSync(pngWithText(320, 320, seed ?? ++n * 7, texts));
      file.setLastModifiedSync(DateTime(2026, 10, 1, 12).add(Duration(minutes: ++n)));
    }

    for (var i = 0; i < 8; i++) {
      write('good_$i.png', {'prompt': comfyGraph(prompt: 'a red fox $i, rim lighting, snow, masterpiece', seed: i + 1)});
      write('bad_$i.png', {'prompt': comfyGraph(prompt: 'a red fox $i, 8k, snow, masterpiece', seed: i + 20)});
    }
    // Two pictures alike but for their data: near-duplicates.
    write('twin_a.png', {'prompt': comfyGraph(prompt: 'a heron in a pond', seed: 40)}, seed: 999);
    write('twin_b.png', {'prompt': comfyGraph(prompt: 'a heron in a pond', seed: 41)}, seed: 999);
    // Nothing in it but the picture.
    write('shared.png', const {});

    // The small stand-in content-search model, installed.
    final model = Directory('${Directory.current.path}/core/tests/fixtures/clip_mini');
    final home = Directory('${scratch.path}/data/models/tinyclip-vit-40m-32-text-19m')..createSync(recursive: true);
    for (final name in ['config.json', 'tokenizer.json', 'model.safetensors']) {
      File('${model.path}/$name').copySync('${home.path}/$name');
    }
    core = NativeCore.start(dataDir: '${scratch.path}/data', cacheDir: '${scratch.path}/cache', libraryPath: coreLibraryPath());
  });

  tearDownAll(() {
    try {
      scratch.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> launch(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = AppState(core: core, thumbs: ThumbCache(core, maxBytes: 64 << 20));
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: GenerativeViewApp(state: state)));
    var done = false;
    state.restore(initialFolder: library.path).whenComplete(() => done = true);
    await pumpUntil(tester, () => done && state.items.length >= 19, what: 'the folder to open');
    return state;
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump(const Duration(seconds: 5));
  }

  MediaItem item(AppState state, String name) {
    for (var i = 0; i < state.items.length; i++) {
      if (state.items[i].name == name) return state.items[i];
    }
    throw StateError('no $name');
  }

  int indexOf(AppState state, String name) {
    for (var i = 0; i < state.items.length; i++) {
      if (state.items[i].name == name) return i;
    }
    return -1;
  }

  /// Rate the library once: the foxes with rim lighting liked, those with 8k
  /// not, and one twin better than the other.
  var rated = false;
  Future<void> rateLibrary(WidgetTester tester, AppState state) async {
    if (rated) return;
    rated = true;
    await tester.runAsync(() async {
      await state.rate([for (var i = 0; i < 8; i++) item(state, 'good_$i.png')], 5);
      await state.rate([for (var i = 0; i < 8; i++) item(state, 'bad_$i.png')], 1);
      await state.rate([item(state, 'twin_b.png')], 4);
    });
    await pumpUntil(tester, () => item(state, 'twin_b.png').rating == 4, what: 'the ratings to be listed');
  }

  for (final (name, size) in [('fold-closed', foldClosed), ('fold-open', foldOpen), ('tab', tabUltra)]) {
    testWidgets('what works, on the $name', (tester) async {
      final state = await launch(tester, size);
      await rateLibrary(tester, state);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      state.applySearch('');
      await tester.pump();
      // The usage page, then its What works tab.
      openStats(tester.element(find.byType(MediaGrid)), state);
      await pumpUntil(tester, () => find.text('What works').evaluate().isNotEmpty, what: 'the usage page');
      await tester.tap(find.text('What works'));
      await pumpUntil(tester, () => find.byKey(const ValueKey('works-row-rim lighting')).evaluate().isNotEmpty, what: 'what works');
      expect(find.byKey(const ValueKey('works-row-8k')), findsOneWidget);
      expect(find.textContaining('From 16 rated pictures'), findsOneWidget);
      await screenshot(tester, boundary, 'artist-works-$name');
      // A row shows its pictures.
      await tester.tap(find.byKey(const ValueKey('works-row-rim lighting')));
      await pumpUntil(tester, () => state.query.contains('rim lighting') && state.items.length == 8, what: 'the pictures with rim lighting');
      await close(tester, state);
    });

    testWidgets('prompt doctor in remix, on the $name', (tester) async {
      final state = await launch(tester, size);
      await rateLibrary(tester, state);
      state.select(indexOf(state, 'bad_0.png'));
      await tester.pump();
      openRemix(tester.element(find.byType(MediaGrid)), state, item(state, 'bad_0.png'));
      await pumpUntil(tester, () => find.byKey(const ValueKey('remix-suggestions-toggle')).evaluate().isNotEmpty, what: 'the suggestions');
      await tester.tap(find.byKey(const ValueKey('remix-suggestions-toggle')));
      await tester.pump();
      // 8k sinks; rim lighting lifts.
      expect(find.textContaining('is common in your rejects'), findsOneWidget);
      expect(find.textContaining('rim lighting'), findsWidgets);
      await screenshot(tester, boundary, 'artist-doctor-$name');
      await tester.tap(find.byKey(const ValueKey('remix-suggestions-all')));
      await tester.pump();
      final prompt = tester.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('remix-prompt')), matching: find.byType(TextField))).controller!.text;
      expect(prompt, contains('rim lighting'));
      expect(prompt, isNot(contains('8k')));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await close(tester, state);
    });

    testWidgets('breed from ticked pictures, on the $name', (tester) async {
      final state = await launch(tester, size);
      await rateLibrary(tester, state);
      state.toggleChecked(item(state, 'good_0.png'));
      state.toggleChecked(item(state, 'good_1.png'));
      await tester.pump();
      expect(find.byKey(const ValueKey('selection-breed')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('selection-breed')));
      await pumpUntil(tester, () => find.byKey(const ValueKey('breed-child-0')).evaluate().isNotEmpty, what: 'the candidates');
      expect(find.byKey(const ValueKey('breed-send')), findsOneWidget);
      await screenshot(tester, boundary, 'artist-breed-$name');
      // Mixing less: the candidates are written again.
      await tester.tap(find.byKey(const ValueKey('breed-mix-settings')));
      await pumpUntil(tester, () => find.byKey(const ValueKey('breed-child-0')).evaluate().isNotEmpty, what: 'the candidates again');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await close(tester, state);
    });

    testWidgets('near-duplicates grouped with the best one kept, on the $name', (tester) async {
      final state = await launch(tester, size);
      await rateLibrary(tester, state);
      state.applyFilter('is:duplicate');
      await pumpUntil(tester, () => state.duplicateGroups.any((g) => g.paths.any((p) => p.endsWith('twin_a.png'))), what: 'the groups');
      await tester.pump();
      final group = state.duplicateGroups.firstWhere((g) => g.paths.any((p) => p.endsWith('twin_a.png')));
      expect(group.bestPath, endsWith('twin_b.png'));
      expect(find.byType(GroupHeader), findsWidgets);
      expect(find.byType(BestBadge), findsWidgets);
      await screenshot(tester, boundary, 'artist-dupes-$name');
      await tester.tap(find.byKey(const ValueKey('filter-bar-best')));
      await tester.pump();
      expect(state.isChecked(item(state, 'twin_a.png').id), isTrue);
      expect(state.isChecked(item(state, 'twin_b.png').id), isFalse);
      await close(tester, state);
    });

    testWidgets('describe a picture with no generation data, on the $name', (tester) async {
      final state = await launch(tester, size);
      state.select(indexOf(state, 'shared.png'));
      if (!state.rightOpen) state.toggleRight();
      await pumpUntil(tester, () => state.content.value.installed && find.byKey(const ValueKey('describe-start')).evaluate().isNotEmpty, what: 'the describe button');
      await tester.ensureVisible(find.byKey(const ValueKey('describe-start')));
      await tester.tap(find.byKey(const ValueKey('describe-start')));
      await pumpUntil(tester, () => find.byKey(const ValueKey('describe-result')).evaluate().isNotEmpty, what: 'the description', timeout: const Duration(seconds: 60));
      expect(find.text('Subject'), findsOneWidget);
      expect(find.byKey(const ValueKey('describe-remix')), findsOneWidget);
      await screenshot(tester, boundary, 'artist-describe-$name');
      await close(tester, state);
    });

    testWidgets('fix this spot opens Find in the mask editor, on the $name', (tester) async {
      final state = await launch(tester, size);
      state.select(indexOf(state, 'good_2.png'));
      await tester.pump();
      openRemix(tester.element(find.byType(MediaGrid)), state, item(state, 'good_2.png'));
      await pumpUntil(tester, () => find.byKey(const ValueKey('remix-mode')).evaluate().isNotEmpty, what: 'the remix panel');
      await tester.tap(find.text('Image to image'));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('remix-mask-edit')));
      await tester.tap(find.byKey(const ValueKey('remix-mask-edit')));
      await pumpUntil(tester, () => find.byKey(const ValueKey('mask-canvas')).evaluate().isNotEmpty, what: 'the mask editor');
      await tester.tap(find.text('Find'));
      await pumpUntil(
        tester,
        () => tester.widget<OutlinedButton>(find.byKey(const ValueKey('mask-find-use'))).onPressed != null,
        what: 'the heat map',
        timeout: const Duration(seconds: 60),
      );
      await screenshot(tester, boundary, 'artist-find-$name');
      await tester.tap(find.byKey(const ValueKey('mask-find-use')));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('mask-status'))).data, isNot(contains('Finding')));
      await tester.tap(find.byKey(const ValueKey('mask-done')));
      await pumpUntil(tester, () => find.byKey(const ValueKey('remix-mask-status')).evaluate().isNotEmpty, what: 'back in remix');
      expect(tester.widget<Text>(find.byKey(const ValueKey('remix-mask-status'))).data, startsWith('Only the painted part'));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await close(tester, state);
    });
  }
}
