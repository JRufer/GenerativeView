// Screenshots of the common screens at the sizes of a Galaxy Z Fold 8
// (closed and open) and a Galaxy Tab S10 Ultra, on real generated pictures,
// for a usability review. Skipped unless GV_SAMPLE_DIR points at the
// ComfyUI examples and GV_SCREENSHOT_DIR says where to put the pictures.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/ui/breed_dialog.dart' show openBreed;
import 'package:generativeview/src/ui/filter_sheet.dart' show openFilters;
import 'package:generativeview/src/ui/mask_editor.dart' show editMask;
import 'package:generativeview/src/ui/media_grid.dart' show MediaGrid;
import 'package:generativeview/src/ui/remix_dialog.dart' show openRemix;
import 'package:generativeview/src/ui/settings_panel.dart' show openSettings;
import 'package:generativeview/src/ui/upscale_dialog.dart' show openUpscale;

import 'support.dart';

const Size foldClosed = Size(476, 752);
const Size foldOpen = Size(932, 696);
const Size tabUltra = Size(1480, 924);

/// The example pictures used, by their path in the ComfyUI examples.
const List<String> samplePictures = [
  'flux/girl_in_field.png',
  'chroma/fennec_girl_flowers.png',
  'sdxl/sdxl_simple_example.png',
  'flux/flux_dev_example.png',
  'z_image/z_image_turbo_example.png',
  'sd3/sd3.5_simple_example.png',
  'hidream/hidream_full_example.png',
  'unclip/mountains.png',
  'unclip/sunset.png',
  'inpaint/yosemite_inpaint_example.png',
  'stable_cascade/stable_cascade__text_to_image.png',
  'flux2/flux2_example.png',
];

/// Copy the [samplePictures] found under [samples] into a new folder.
Directory sampleLibrary(String samples, Directory into) {
  final library = Directory('${into.path}/library')..createSync(recursive: true);
  var n = 0;
  for (final rel in samplePictures) {
    final from = File('$samples/$rel');
    if (!from.existsSync()) continue;
    final to = File('${library.path}/${rel.split('/').last}');
    from.copySync(to.path);
    to.setLastModifiedSync(DateTime(2026, 11, 1, 12).add(Duration(minutes: n++)));
  }
  return library;
}

void main() {
  final samples = Platform.environment['GV_SAMPLE_DIR'] ?? '';
  final skip = samples.isEmpty || !Directory(samples).existsSync();

  late Directory scratch;
  late Directory library;
  late NativeCore core;
  final boundary = GlobalKey();

  setUpAll(() async {
    if (skip) return;
    await loadAppFonts();
    scratch = Directory.systemTemp.createTempSync('gv-audit-');
    library = sampleLibrary(samples, scratch);
    core = NativeCore.start(dataDir: '${scratch.path}/data', cacheDir: '${scratch.path}/cache', libraryPath: coreLibraryPath());
  });

  tearDownAll(() {
    if (skip) return;
    try {
      scratch.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> launch(WidgetTester tester, Size size) async {
    debugDisableShadows = false;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = AppState(core: core, thumbs: ThumbCache(core, maxBytes: 128 << 20));
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: GenerativeViewApp(state: state)));
    var done = false;
    state.restore(initialFolder: library.path).whenComplete(() => done = true);
    await pumpUntil(tester, () => done, what: 'the folder to open');
    state.clearChecked();
    state.applySearch('');
    if (state.leftOpen && state.narrowLayout) state.toggleLeft();
    await pumpUntil(tester, () => state.items.length >= 8 && !state.scan.value.running, what: 'the pictures to be listed', timeout: const Duration(minutes: 2));
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
  }

  MediaItem item(AppState state, String name) => state.items.firstWhere((i) => i.name == name);
  int indexOf(AppState state, String name) => state.items.indexWhere((i) => i.name == name);
  BuildContext ctx(WidgetTester tester) => tester.element(find.byType(MediaGrid));

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    await screenshot(tester, boundary, name);
  }

  Future<void> dismiss(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
  }

  for (final (name, size) in [('fold-closed', foldClosed), ('fold-open', foldOpen), ('tab', tabUltra)]) {
    testWidgets('the common screens, on the $name', skip: skip, (tester) async {
      final state = await launch(tester, size);
      await shot(tester, 'audit-grid-$name');

      // The info panel, for a picture with a workflow.
      if (!state.rightOpen) state.toggleRight();
      state.select(indexOf(state, 'girl_in_field.png'));
      await shot(tester, 'audit-info-$name');
      if (state.rightOpen && state.narrowLayout) state.toggleRight();
      await tester.pump();

      openFilters(ctx(tester), state);
      await shot(tester, 'audit-filters-$name');
      await dismiss(tester);

      // Remix, both ways.
      openRemix(ctx(tester), state, item(state, 'girl_in_field.png'));
      await pumpUntil(tester, () => find.byKey(const ValueKey('remix-mode')).evaluate().isNotEmpty, what: 'remix');
      await tester.pump(const Duration(milliseconds: 800));
      await shot(tester, 'audit-remix-t2i-$name');
      await tester.tap(find.text('Image to image'));
      await shot(tester, 'audit-remix-i2i-$name');
      await dismiss(tester);

      // The mask editor, on its mask layer.
      editMask(ctx(tester), path: item(state, 'girl_in_field.png').path, name: 'girl_in_field.png', aspect: 1, ops: const [], state: state, phrases: const ['a woman', 'rice field']);
      await pumpUntil(tester, () => find.byKey(const ValueKey('mask-canvas')).evaluate().isNotEmpty, what: 'the mask editor');
      await shot(tester, 'audit-mask-color-$name');
      await tester.tap(find.text('Mask'));
      await shot(tester, 'audit-mask-$name');
      await tester.tap(find.byKey(const ValueKey('mask-cancel')));
      await settle(tester);

      // Upscale, if this build can.
      openUpscale(ctx(tester), state, item(state, 'girl_in_field.png'));
      await settle(tester);
      await shot(tester, 'audit-upscale-$name');
      await dismiss(tester);

      // Breed from two.
      openBreed(ctx(tester), state, [item(state, 'girl_in_field.png'), item(state, 'fennec_girl_flowers.png')]);
      await pumpUntil(tester, () => find.byKey(const ValueKey('breed-send')).evaluate().isNotEmpty, what: 'breed', timeout: const Duration(seconds: 60));
      await shot(tester, 'audit-breed-$name');
      await dismiss(tester);

      openSettings(ctx(tester), state);
      await shot(tester, 'audit-settings-$name');
      await dismiss(tester);

      // The focus view.
      state.select(indexOf(state, 'girl_in_field.png'));
      state.openFocus(indexOf(state, 'girl_in_field.png'));
      await shot(tester, 'audit-focus-$name');
      await close(tester, state);
    });
  }
}
