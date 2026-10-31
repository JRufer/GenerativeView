// Audience levels (G to NC-17) against the real core: the filter panel's
// Audience section, the grid filtered with badges on its tiles, the info
// panel's audience row and a level set by hand, and aiming Remix and Breed
// at a level. No content-search model is installed, so the prompt decides
// and the panels say what rating by picture needs. Screenshots at the sizes
// of a Galaxy Z Fold 8 (closed and open) and a Galaxy Tab S10 Ultra, when
// GV_SCREENSHOT_DIR is set.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/audience.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/ui/filter_sheet.dart' show FilterSet, openFilters;
import 'package:generativeview/src/ui/media_grid.dart' show MediaGrid;
import 'package:generativeview/src/ui/remix_dialog.dart' show openRemix;

import 'support.dart';

const Size foldClosed = Size(476, 752);
const Size foldOpen = Size(932, 696);
const Size tabUltra = Size(1480, 924);

void main() {
  group('audience terms', () {
    test('the panel reads back what it writes', () {
      final f = FilterSet.parse('fox audience:..pg13|none');
      expect(f.audienceMax, Audience.pg13);
      expect(f.audienceUnrated, isTrue);
      expect(f.free, ['fox']);
      expect(f.toQuery(), 'fox audience:..pg13|none');
      expect(FilterSet.parse('audience:none').audienceUnrated, isTrue);
      // A shape the panel does not write is left as typed.
      expect(FilterSet.parse('audience:r..').free, ['audience:r..']);
    });
  });

  late Directory scratch;
  late Directory library;
  late NativeCore core;
  final boundary = GlobalKey();

  /// The library: (file, prompt, level the prompt reads as).
  const pictures = [
    ('fox_1.png', 'a red fox in snow, rim lighting, masterpiece', Audience.g),
    ('fox_2.png', 'a red fox asleep in a meadow, golden hour', Audience.g),
    ('lake.png', 'a misty lake at dawn, a heron, soft light', Audience.g),
    ('knight.png', 'a knight with a sword, castle gate, banners', Audience.pg),
    ('beach.png', 'a woman in a swimsuit on a beach, film photo', Audience.pg),
    ('soldier.png', 'a soldier on a battlefield, blood, smoke, rain', Audience.pg13),
    ('detective.png', 'a noir detective with a pistol, wet street, neon', Audience.pg13),
    ('zombie.png', 'a zombie in a ruined city, gore, blood splatter, horror, dusk', Audience.r),
    ('study.png', 'nude figure study, charcoal drawing, art class', Audience.r),
    ('shared.png', '', Audience.unknown),
  ];

  setUpAll(() async {
    await loadAppFonts();
    scratch = Directory.systemTemp.createTempSync('gv-audience-');
    library = Directory('${scratch.path}/library')..createSync();
    var n = 0;
    for (final (name, prompt, _) in pictures) {
      final file = File('${library.path}/$name');
      n++;
      file.writeAsBytesSync(pngWithText(320, 320, n * 11, prompt.isEmpty ? const {} : {'prompt': comfyGraph(prompt: prompt, seed: n)}));
      file.setLastModifiedSync(DateTime(2026, 10, 1, 12).add(Duration(minutes: n)));
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
    await pumpUntil(tester, () => done, what: 'the folder to open');
    state.clearChecked();
    state.applySearch('');
    if (state.leftOpen && state.narrowLayout) state.toggleLeft();
    if (state.rightOpen && state.narrowLayout) state.toggleRight();
    await pumpUntil(tester, () => state.items.length >= pictures.length, what: 'every picture to be listed');
    return state;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
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

  for (final (name, size) in [('fold-closed', foldClosed), ('fold-open', foldOpen), ('tab', tabUltra)]) {
    testWidgets('audience filter and badges, on the $name', (tester) async {
      final state = await launch(tester, size);
      // Every picture carries the level its prompt reads as.
      for (final (file, _, level) in pictures) {
        expect(item(state, file).audience, level, reason: file);
      }
      await settle(tester);
      await screenshot(tester, boundary, 'audience-badges-$name');

      openFilters(tester.element(find.byType(MediaGrid)), state);
      await pumpUntil(tester, () => find.byKey(const ValueKey('filter-audience'), skipOffstage: false).evaluate().isNotEmpty, what: 'the audience section');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.ensureVisible(find.byKey(const ValueKey('filter-audience-pg13')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('filter-audience-pg13')));
      await pumpUntil(tester, () => state.query.contains('audience:..pg13') && state.items.length == 7, what: 'the pictures up to PG-13');
      await settle(tester);
      await screenshot(tester, boundary, 'audience-filter-$name');

      await tester.tap(find.byKey(const ValueKey('filters-done')));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byKey(const ValueKey('filter-bar-audience')), findsOneWidget);
      await settle(tester);
      await screenshot(tester, boundary, 'audience-grid-$name');
      await close(tester, state);
    });

    testWidgets('audience row in the info panel, on the $name', (tester) async {
      final state = await launch(tester, size);
      if (!state.rightOpen) state.toggleRight();
      await settle(tester);
      state.select(indexOf(state, 'zombie.png'));
      await pumpUntil(tester, () => find.byKey(const ValueKey('audience-toggle'), skipOffstage: false).evaluate().isNotEmpty, what: 'the audience row');
      await tester.ensureVisible(find.byKey(const ValueKey('audience-toggle'), skipOffstage: false));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('audience-toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('audience-detail')), findsOneWidget);
      expect(find.textContaining('gore'), findsWidgets);
      expect(find.text('Needs the content search model'), findsOneWidget);
      await settle(tester);
      await screenshot(tester, boundary, 'audience-info-$name');

      // Set by hand: the menu, then PG-13 chosen.
      await tester.ensureVisible(find.byKey(const ValueKey('audience-set')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('audience-set')));
      await pumpUntil(tester, () => find.byKey(const ValueKey('audience-set-pg13')).evaluate().isNotEmpty, what: 'the level menu');
      await settle(tester);
      await screenshot(tester, boundary, 'audience-set-$name');
      await tester.tap(find.byKey(const ValueKey('audience-set-pg13')));
      await pumpUntil(tester, () => item(state, 'zombie.png').audience == Audience.pg13, what: 'the level set by hand');
      // Kept beside the pictures, with the stars and flags.
      final notes = File('${library.path}/.generativeview.json').readAsStringSync();
      expect(notes, contains('"audience": "pg13"'));
      // Back to the app's reading, for the tests after.
      await tester.runAsync(() => state.setAudience(item(state, 'zombie.png'), 0));
      await close(tester, state);
    });

    testWidgets('aim a remix at an audience level, on the $name', (tester) async {
      final state = await launch(tester, size);
      state.select(indexOf(state, 'zombie.png'));
      await tester.pump();
      openRemix(tester.element(find.byType(MediaGrid)), state, item(state, 'zombie.png'));
      await pumpUntil(tester, () => find.byKey(const ValueKey('remix-audience-toggle')).evaluate().isNotEmpty, what: 'the remix panel');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.ensureVisible(find.byKey(const ValueKey('remix-audience-toggle')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('remix-audience-toggle')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('remix-audience-pg13')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('remix-audience-pg13')));
      await pumpUntil(tester, () => find.byKey(const ValueKey('audience-steer-note')).evaluate().isNotEmpty, what: 'the prompt aimed at PG-13');
      final prompt = tester.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('remix-prompt')), matching: find.byType(TextField))).controller!.text;
      expect(prompt, isNot(contains('gore')));
      expect(prompt, contains('a zombie in a ruined city'));
      await tester.ensureVisible(find.byKey(const ValueKey('audience-steer-note')));
      await tester.pump();
      await settle(tester);
      await screenshot(tester, boundary, 'audience-remix-$name');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await close(tester, state);
    });

    testWidgets('aim bred candidates at an audience level, on the $name', (tester) async {
      final state = await launch(tester, size);
      state.toggleChecked(item(state, 'soldier.png'));
      state.toggleChecked(item(state, 'zombie.png'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('selection-breed')));
      await pumpUntil(tester, () => find.byKey(const ValueKey('breed-child-0')).evaluate().isNotEmpty, what: 'the candidates');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.ensureVisible(find.byKey(const ValueKey('breed-audience-pg')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('breed-audience-pg')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      await settle(tester);
      await screenshot(tester, boundary, 'audience-breed-$name');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await close(tester, state);
    });
  }
}
