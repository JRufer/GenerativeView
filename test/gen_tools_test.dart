// The generation tools: wildcards, extending the canvas, tap to select,
// the face and hand detail pass, and the hires fix in tiles. Their rules
// are tested here, and their screens shown with stand-ins for the
// on-device models, as screenshots at the sizes of a Galaxy Z Fold 8
// (closed and open) and a Galaxy Tab S10 Ultra when GV_SCREENSHOT_DIR and
// GV_SAMPLE_DIR (the ComfyUI examples) are set.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/detail_pass.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/object_select.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/core/wildcards.dart';
import 'package:generativeview/src/ui/mask_editor.dart';
import 'package:generativeview/src/ui/media_grid.dart' show MediaGrid;
import 'package:generativeview/src/ui/remix_dialog.dart' show openRemix;
import 'package:generativeview/src/ui/upscale_dialog.dart' show openUpscale;
import 'package:generativeview/src/ui/wildcards_ui.dart' show openWordLists;

import 'support.dart';
import 'ui_audit_test.dart' show foldClosed, foldOpen, sampleLibrary, tabUltra;

/// Round the woman in the field (flux/girl_in_field.png), traced by hand,
/// as the selection model would outline her.
const List<Offset> _woman = [
  Offset(0.47, 0.09), Offset(0.53, 0.09), Offset(0.56, 0.15), Offset(0.60, 0.22), Offset(0.62, 0.32),
  Offset(0.62, 0.44), Offset(0.60, 0.49), Offset(0.67, 0.56), Offset(0.71, 0.63), Offset(0.73, 0.80),
  Offset(0.66, 0.83), Offset(0.67, 1.0), Offset(0.33, 1.0), Offset(0.34, 0.83), Offset(0.27, 0.81),
  Offset(0.29, 0.62), Offset(0.33, 0.56), Offset(0.40, 0.50), Offset(0.39, 0.44), Offset(0.39, 0.32),
  Offset(0.41, 0.22), Offset(0.44, 0.15),
];

class StandInSelector implements ObjectSelector {
  StandInSelector({bool installed = true}) : _model = SelectModelState(installed: installed);
  SelectModelState _model;
  final _changes = StreamController<SelectModelState>.broadcast();

  @override
  int get downloadBytes => 38 << 20;
  @override
  SelectModelState get model => _model;
  @override
  Stream<SelectModelState> get changes => _changes.stream;
  @override
  Future<void> download() async {
    _model = const SelectModelState(installed: true);
    _changes.add(_model);
  }

  @override
  Future<List<Offset>> outline(Offset point) async => point.dx > 0.3 && point.dx < 0.7 ? _woman : const [];
  @override
  void dispose() => _changes.close();
}

class StandInFinder implements RegionFinder {
  StandInFinder({bool installed = true}) : _model = FinderModelState(installed: installed);
  FinderModelState _model;
  final _changes = StreamController<FinderModelState>.broadcast();

  @override
  int get downloadBytes => 12 << 20;
  @override
  FinderModelState get model => _model;
  @override
  Stream<FinderModelState> get changes => _changes.stream;
  @override
  Future<void> download() async {
    _model = const FinderModelState(installed: true);
    _changes.add(_model);
  }

  @override
  Future<List<DetailRegion>> find(String path) async => const [
    DetailRegion(DetailKind.face, Rect.fromLTRB(0.40, 0.27, 0.62, 0.47), 0.97),
  ];
}

void main() {
  group('wildcards', () {
    const lists = {'lighting': ['golden hour', 'overcast', 'blue hour']};

    test('choices and lists are counted and made in order', () {
      final p = WildcardPrompt.parse('a {red|blue} fox, __lighting__', lists);
      expect(p.hasChoices, isTrue);
      expect(p.choiceCount, 1);
      expect(p.listNames, ['lighting']);
      expect(p.combinations(), 6);
      expect(p.every(), [
        'a red fox, golden hour',
        'a red fox, overcast',
        'a red fox, blue hour',
        'a blue fox, golden hour',
        'a blue fox, overcast',
        'a blue fox, blue hour',
      ]);
    });

    test('choices inside choices, empty options, and escapes', () {
      final p = WildcardPrompt.parse('{a {red|blue} fox|an owl}, {|snow}', const {});
      expect(p.combinations(), 6);
      expect(p.every(), contains('a red fox'));
      expect(p.every(), contains('an owl, snow'));
      expect(WildcardPrompt.parse(r'a \{red|blue\} fox', const {}).hasChoices, isFalse);
      // A brace with no bar is left as it is.
      expect(WildcardPrompt.parse('{masterpiece}', const {}).every(), ['{masterpiece}']);
    });

    test('a list that does not exist is reported and left as written', () {
      final p = WildcardPrompt.parse('a fox, __weather__', lists);
      expect(p.missingLists, ['weather']);
      expect(p.hasChoices, isFalse);
      expect(p.pick(math.Random(1)), 'a fox, __weather__');
    });

    test('random picks repeat for the same seed', () {
      final p = WildcardPrompt.parse('{a|b|c|d|e} {f|g|h}', const {});
      expect(p.expand(5, all: false, seed: 7), p.expand(5, all: false, seed: 7));
      expect(p.expand(20, all: true).toSet().length, 15);
    });

    test('marks for the editor: braces, bars and lists', () {
      const text = 'a {red|blue} fox, __lighting__, __nope__';
      final marks = wildcardMarks(text, lists);
      expect(marks.map((m) => text.substring(m.start, m.end)), ['{red|blue}', '__lighting__', '__nope__']);
      expect(marks.first.bars, [text.indexOf('|')]);
      expect(marks[1].missing, isFalse);
      expect(marks[2].missing, isTrue);
    });

    test('each picture gets its own prompt and negative', () {
      expect(wildcardPicks('a fox', 'blur', lists, count: 3, every: false), isNull);
      final every = wildcardPicks('a {red|blue} fox', '{blur|noise}', lists, count: 4, every: true)!;
      expect(every, [('a red fox', 'blur'), ('a red fox', 'noise'), ('a blue fox', 'blur'), ('a blue fox', 'noise')]);
      final picked = wildcardPicks('a fox, __lighting__', 'blur', lists, count: 5, every: false, seed: 3)!;
      expect(picked.length, 5);
      expect(picked.every((p) => p.$2 == 'blur' && !p.$1.contains('__')), isTrue);
      expect(wildcardPicks('a fox, __lighting__', 'blur', lists, count: 5, every: false, seed: 3), picked);
    });

    test('word list files: one option a line, no blanks or comments', () {
      expect(wordListFromText('# lighting\ngolden hour\n\n  overcast  \n'), ['golden hour', 'overcast']);
      expect(wordListsFromJson('{"a":["x","y"]}'), {'a': ['x', 'y']});
      expect(wordListsFromJson('nonsense'), isEmpty);
    });
  });

  group('tiles', () {
    test('tiles cover the picture evenly, sharing the overlap or more', () {
      final tiles = planTiles(3072, 3072, tile: 1024, overlap: 128);
      expect(tiles.length, 16);
      expect(tiles.first.topLeft, Offset.zero);
      expect(tiles.last.bottomRight, const Offset(3072, 3072));
      expect(tiles[1].left, lessThanOrEqualTo(1024 - 128));
      expect(planTiles(800, 600, tile: 1024), [const Rect.fromLTWH(0, 0, 800, 600)]);
    });

    test('auto tiles only a large hires fix', () {
      expect(usesTiles(TileMode.auto, 2048, 2048), isFalse);
      expect(usesTiles(TileMode.auto, 3072, 3072), isTrue);
      expect(usesTiles(TileMode.tiles, 1024, 1024), isTrue);
      expect(usesTiles(TileMode.whole, 4096, 4096), isFalse);
    });
  });

  group('extending the canvas', () {
    test('to a shape, and the size it comes to', () {
      final wide = Extension.toAspect(1, 16 / 9);
      expect(wide.left, closeTo(wide.right, 1e-9));
      expect(wide.aspectOf(1), closeTo(16 / 9, 1e-9));
      expect(wide.sizeOf(1024, 1024), (1824, 1024));
      expect(const Extension(top: 0.25).sizeOf(1024, 1024), (1024, 1280));
      expect(const Extension().copyWith(left: 5).left, Extension.most);
    });
  });

  // ---------------------------------------------------------------- screens

  final samples = Platform.environment['GV_SAMPLE_DIR'] ?? '';
  final skip = samples.isEmpty || !File('$samples/flux/girl_in_field.png').existsSync();

  late Directory scratch;
  late Directory library;
  late NativeCore core;
  final boundary = GlobalKey();

  setUpAll(() async {
    if (skip) return;
    await loadAppFonts();
    scratch = Directory.systemTemp.createTempSync('gv-gen-');
    library = sampleLibrary(samples, scratch);
    core = NativeCore.start(dataDir: '${scratch.path}/data', cacheDir: '${scratch.path}/cache', libraryPath: coreLibraryPath());
  });

  tearDownAll(() {
    if (skip) return;
    try {
      scratch.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> launch(WidgetTester tester, Size size, {bool modelsInstalled = true}) async {
    // Real shadows in the pictures; put back in close(), before the test
    // framework checks they were.
    debugDisableShadows = false;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = AppState(core: core, thumbs: ThumbCache(core, maxBytes: 128 << 20))
      ..previewTools = true
      ..objectSelectorFor = ((_) => StandInSelector(installed: modelsInstalled))
      ..regionFinder = StandInFinder(installed: modelsInstalled);
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: GenerativeViewApp(state: state)));
    var done = false;
    state.restore(initialFolder: library.path).whenComplete(() => done = true);
    await pumpUntil(tester, () => done, what: 'the folder to open');
    state.clearChecked();
    state.applySearch('');
    if (state.leftOpen && state.narrowLayout) state.toggleLeft();
    await pumpUntil(tester, () => state.items.length >= 8 && !state.scan.value.running, what: 'the pictures', timeout: const Duration(minutes: 2));
    state.setBackendUrl('comfyui', 'http://127.0.0.1:8188');
    state.saveWordList('lighting', const ['golden hour', 'overcast', 'blue hour']);
    return state;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump(const Duration(seconds: 5));
    debugDisableShadows = true;
  }

  MediaItem item(AppState state, String name) {
    for (var i = 0; i < state.items.length; i++) {
      if (state.items[i].name == name) return state.items[i];
    }
    throw StateError('no $name');
  }

  BuildContext ctx(WidgetTester tester) => tester.element(find.byType(MediaGrid));

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    await screenshot(tester, boundary, name);
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await settle(tester);
  }

  Future<void> openEditor(WidgetTester tester, AppState state, {bool select = true}) async {
    final girl = item(state, 'girl_in_field.png');
    editMask(
      ctx(tester),
      path: girl.path,
      name: girl.name,
      aspect: 1,
      ops: const [],
      state: state,
      phrases: const ['a woman', 'rice field'],
      pixels: const Size(1024, 1024),
      selector: select ? state.objectSelectorFor!(girl.path) : null,
      canExtend: true,
    );
    await pumpUntil(tester, () => find.byKey(const ValueKey('mask-canvas')).evaluate().isNotEmpty, what: 'the mask editor');
    await settle(tester);
  }

  for (final (name, size) in [('fold-closed', foldClosed), ('fold-open', foldOpen), ('tab', tabUltra)]) {
    testWidgets('wildcards in remix, on the $name', skip: skip, (tester) async {
      final state = await launch(tester, size);
      openRemix(ctx(tester), state, item(state, 'girl_in_field.png'));
      await pumpUntil(tester, () => find.byKey(const ValueKey('remix-prompt')).evaluate().isNotEmpty, what: 'remix');
      await tester.pump(const Duration(milliseconds: 800));
      final prompt = find.descendant(of: find.byKey(const ValueKey('remix-prompt')), matching: find.byType(TextField));
      await tester.enterText(prompt, 'a woman in a {yellow|red|blue} robe standing in a rice field, __lighting__, {anime|watercolor} style');
      await settle(tester);
      expect(find.byKey(const ValueKey('wildcard-bar')), findsOneWidget);
      await shot(tester, 'gen-wildcards-random-$name');
      await tap(tester, find.text('Every one (18)'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('remix-count'))).data, '18');
      await shot(tester, 'gen-wildcards-every-$name');
      // A list that is not there yet.
      await tester.enterText(prompt, 'a woman in a rice field, __weather__');
      await settle(tester);
      expect(find.byKey(const ValueKey('wildcard-make-weather')), findsOneWidget);
      await shot(tester, 'gen-wildcards-missing-$name');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      openWordLists(ctx(tester), state);
      await shot(tester, 'gen-word-lists-$name');
      await tap(tester, find.byKey(const ValueKey('word-list-lighting')));
      await shot(tester, 'gen-word-list-edit-$name');
      await close(tester, state);
    });

    testWidgets('extend and select in the mask editor, on the $name', skip: skip, (tester) async {
      final state = await launch(tester, size);
      await openEditor(tester, state);
      await tap(tester, find.text('Extend'));
      await shot(tester, 'gen-extend-empty-$name');
      await tap(tester, find.byKey(const ValueKey('mask-extend-16:9')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('mask-extend-size'))).textSpan!.toPlainText(), contains('1824 × 1024'));
      await shot(tester, 'gen-extend-wide-$name');
      // On the mask, the new canvas shows as drawn new.
      await tap(tester, find.text('Mask'));
      await tap(tester, find.text('Select'));
      final canvas = tester.getRect(find.byKey(const ValueKey('mask-canvas')));
      await tester.tapAt(canvas.center);
      await settle(tester);
      expect(find.byKey(const ValueKey('mask-select-row')), findsOneWidget);
      await shot(tester, 'gen-select-$name');
      await tester.tap(find.byKey(const ValueKey('mask-cancel')));
      await settle(tester);
      await close(tester, state);
    });

    testWidgets('the detail pass and tiles in upscale, on the $name', skip: skip, (tester) async {
      final state = await launch(tester, size);
      openUpscale(ctx(tester), state, item(state, 'girl_in_field.png'));
      await pumpUntil(tester, () => find.byKey(const ValueKey('hires-switch')).evaluate().isNotEmpty, what: 'upscale');
      // A bottom sheet slides up; tap once it is in place.
      await tester.pump(const Duration(milliseconds: 800));
      await tap(tester, find.byKey(const ValueKey('hires-switch')));
      await tap(tester, find.byKey(const ValueKey('hires-scale-3')));
      expect(find.byKey(const ValueKey('tiles-section')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('tiles-caption'))).data, startsWith('16 tiles'));
      await tester.ensureVisible(find.byKey(const ValueKey('tiles-section')));
      await shot(tester, 'gen-tiles-$name');
      await tap(tester, find.byKey(const ValueKey('detail-faces')));
      await pumpUntil(tester, () => find.textContaining('Found 1 face').evaluate().isNotEmpty, what: 'the face');
      await tester.ensureVisible(find.byKey(const ValueKey('upscale-detail')));
      await shot(tester, 'gen-upscale-detail-$name');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      // Fixing faces only, at the picture's own size.
      openUpscale(ctx(tester), state, item(state, 'girl_in_field.png'), detail: true);
      await pumpUntil(tester, () => find.textContaining('Found 1 face').evaluate().isNotEmpty, what: 'the face');
      expect(find.text('Fix faces and hands'), findsOneWidget);
      await shot(tester, 'gen-fix-faces-$name');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await close(tester, state);
    });

    testWidgets('faces and hands in remix, and models to download, on the $name', skip: skip, (tester) async {
      final state = await launch(tester, size, modelsInstalled: false);
      openRemix(ctx(tester), state, item(state, 'girl_in_field.png'));
      await pumpUntil(tester, () => find.byKey(const ValueKey('remix-detail')).evaluate().isNotEmpty, what: 'remix');
      await tester.pump(const Duration(milliseconds: 800));
      await tap(tester, find.text('FACES AND HANDS'));
      await tap(tester, find.byKey(const ValueKey('detail-faces')));
      await tap(tester, find.byKey(const ValueKey('detail-hands')));
      await shot(tester, 'gen-remix-detail-$name');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await openEditor(tester, state);
      await tap(tester, find.text('Mask'));
      await tap(tester, find.text('Select'));
      expect(find.byKey(const ValueKey('mask-select-download')), findsOneWidget);
      await shot(tester, 'gen-select-download-$name');
      await tester.tap(find.byKey(const ValueKey('mask-cancel')));
      await settle(tester);
      await close(tester, state);
    });
  }
}
