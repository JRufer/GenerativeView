// A new picture, made from a prompt, a model and settings alone: the panel
// with the server's models grouped by kind and only the LoRAs that fit the
// one chosen, sent to a stand-in Forge and saved in the open folder. Shown
// as screenshots at the sizes of a Galaxy Z Fold 8 (closed and open) and a
// Galaxy Tab S10 Ultra when GV_SCREENSHOT_DIR and GV_SAMPLE_DIR are set.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/ui/media_grid.dart' show MediaGrid;
import 'package:generativeview/src/ui/model_picker.dart';
import 'package:generativeview/src/ui/remix_dialog.dart' show openNewPicture;

import 'support.dart';
import 'ui_audit_test.dart' show foldClosed, foldOpen, sampleLibrary, tabUltra;

/// What the stand-in Forge has installed, as Forge lists it.
const _checkpoints = [
  ('SDXL/juggernautXL_v9.safetensors', 'aa11bb22cc'),
  ('SDXL/animagineXL_v31.safetensors', 'aa11bb22cd'),
  ('SDXL/ponyDiffusionV6XL.safetensors', 'aa11bb22ce'),
  ('Krea2/krea2_turbo_fp8_scaled.safetensors', 'aa11bb22cf'),
  ('Krea2/krea2_raw_fp8_scaled.safetensors', 'aa11bb22d0'),
  ('Flux/flux1-dev-fp8.safetensors', 'aa11bb22d1'),
  ('sd15/dreamshaper_8.safetensors', 'aa11bb22d2'),
  ('mystery_mix_v3.safetensors', 'aa11bb22d3'),
];

const _loras = [
  ('detail_tweaker_xl', 'SDXL/detail_tweaker_xl.safetensors', {'ss_base_model_version': 'sdxl_base_v1-0'}),
  ('painted_world_xl', 'SDXL/painted_world_xl.safetensors', {'ss_base_model_version': 'sdxl_base_v1-0'}),
  ('krea2_film_grain', 'Krea2/krea2_film_grain.safetensors', <String, String>{}),
  ('flux_realism', 'Flux/flux_realism.safetensors', {'modelspec.architecture': 'flux-1-dev/lora'}),
  ('add_detail', 'sd15/add_detail.safetensors', {'ss_base_model_version': 'sd_v1'}),
  ('old_favourite', 'old_favourite.safetensors', <String, String>{}),
];

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
    scratch = Directory.systemTemp.createTempSync('gv-new-');
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
    await pumpUntil(tester, () => state.items.length >= 8 && !state.scan.value.running, what: 'the pictures', timeout: const Duration(minutes: 2));
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

  bool there(String key) => find.byKey(ValueKey<String>(key)).evaluate().isNotEmpty;

  /// A Forge that lists [_checkpoints] and [_loras], and answers a
  /// text-to-image request with one of the sample pictures.
  Future<(HttpServer, List<Map<String, dynamic>>)> forge(WidgetTester tester) async {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = saved);
    final asked = <Map<String, dynamic>>[];
    final picture = base64Encode(File('${library.path}/girl_in_field.png').readAsBytesSync());
    final server = (await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final path = request.uri.path;
        final body = await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        if (path.endsWith('/sd-models')) {
          request.response.write(jsonEncode([
            for (final (file, hash) in _checkpoints)
              {'title': '${file.split('/').last} [$hash]', 'model_name': file.split('/').last.split('.').first, 'filename': '/models/Stable-diffusion/$file'},
          ]));
        } else if (path.endsWith('/loras')) {
          request.response.write(jsonEncode([
            for (final (name, file, meta) in _loras) {'name': name, 'alias': name, 'path': '/models/Lora/$file', 'metadata': meta},
          ]));
        } else if (path.endsWith('/txt2img')) {
          asked.add(jsonDecode(body) as Map<String, dynamic>);
          request.response.write(jsonEncode({'images': [picture], 'info': '{}'}));
        } else {
          request.response.write('{}');
        }
        await request.response.close();
      });
      return server;
    }))!;
    addTearDown(() => server.close(force: true));
    return (server, asked);
  }

  for (final (name, size) in [('fold-closed', foldClosed), ('fold-open', foldOpen), ('tab', tabUltra)]) {
    testWidgets('a new picture, on the $name', skip: skip, (tester) async {
      final (server, asked) = await forge(tester);
      final state = await launch(tester, size);
      state.setBackendUrl('forge', 'http://127.0.0.1:${server.port}');
      // As on a first run: no model remembered from the last new picture.
      state.setPref('pref_new_model_forge', '');
      await tester.pump();
      if (name != 'fold-closed') await shot(tester, 'new-0-grid-$name');

      openNewPicture(ctx(tester), state);
      await pumpUntil(tester, () => there('remix-model'), what: 'the server\'s models');
      // Nothing behind it: no image to image, and a model still to choose.
      expect(find.byKey(const ValueKey('remix-mode')), findsNothing);
      expect(find.text('Choose a model'), findsOneWidget);
      await shot(tester, 'new-1-empty-$name');

      // The models, grouped by kind.
      await tap(tester, find.byKey(const ValueKey('remix-model')));
      expect(find.byType(ModelPicker), findsOneWidget);
      for (final kind in ['sd-1', 'sdxl', 'flux', 'krea-2', 'unknown']) {
        expect(find.byKey(ValueKey('model-kind-$kind')), findsOneWidget, reason: kind);
      }
      await shot(tester, 'new-2-models-$name');
      await tap(tester, find.byKey(const ValueKey('model-kind-sdxl')));
      expect(find.text('juggernautXL_v9'), findsOneWidget);
      expect(find.text('krea2_turbo_fp8_scaled'), findsNothing);
      await shot(tester, 'new-3-models-sdxl-$name');
      await tap(tester, find.text('juggernautXL_v9'));
      expect(find.byType(ModelPicker), findsNothing);
      await pumpUntil(tester, () => find.text('Only LoRAs made for SDXL are offered.').evaluate().isNotEmpty, what: 'the model\'s kind');
      expect(find.text('SDXL'), findsOneWidget);

      // Only the LoRAs made for that kind are offered.
      await tap(tester, find.byKey(const ValueKey('remix-loras')));
      await tap(tester, find.byKey(const ValueKey('remix-lora-add')));
      await pumpUntil(tester, () => there('lora-picker-note'), what: 'the server\'s LoRAs');
      expect(find.text('detail_tweaker_xl'), findsOneWidget);
      expect(find.text('painted_world_xl'), findsOneWidget);
      expect(find.text('flux_realism'), findsNothing);
      expect(find.text('krea2_film_grain'), findsNothing);
      expect(find.text('add_detail'), findsNothing);
      await shot(tester, 'new-4-loras-$name');
      await tap(tester, find.text('detail_tweaker_xl'));

      final prompt = find.descendant(of: find.byKey(const ValueKey('remix-prompt')), matching: find.byType(EditableText));
      await tester.ensureVisible(prompt);
      await tester.enterText(prompt, 'a red fox in the snow, golden hour');
      await shot(tester, 'new-5-ready-$name');

      await tap(tester, find.byKey(const ValueKey('remix-send')));
      await pumpUntil(tester, () => state.remixes.value.any((j) => !j.running && j.saved.isNotEmpty), what: 'the new picture', timeout: const Duration(seconds: 60));
      expect(asked, hasLength(1));
      expect(asked.single['prompt'], contains('a red fox in the snow, golden hour'));
      expect(asked.single['prompt'], contains('<lora:detail_tweaker_xl:'));
      expect((asked.single['override_settings'] as Map)['sd_model_checkpoint'], startsWith('juggernautXL_v9'));
      expect((asked.single['width'], asked.single['height']), (1024, 1024));
      expect(asked.single.containsKey('init_images'), isFalse);
      final job = state.remixes.value.single;
      final saved = job.saved.single.replaceAll(r'\', '/');
      expect(saved, startsWith(library.path.replaceAll(r'\', '/')));
      expect(saved, endsWith('/a-red-fox-in-the_new1.png'));
      expect(File(saved).existsSync(), isTrue);
      // In a collection of its own, which the done button goes to.
      final notes = jsonDecode(File('${library.path}/.generativeview.json').readAsStringSync()) as Map<String, dynamic>;
      expect(((notes['images'] as Map)['a-red-fox-in-the_new1.png'] as Map)['collections'], [AppState.newCollection]);
      var shown = false;
      state.showRemixes().whenComplete(() => shown = true);
      await pumpUntil(tester, () => shown && state.query.contains(AppState.newCollection), what: 'the New collection');
      expect(state.query, isNot(contains(AppState.remixCollection)));
      expect(state.remixes.value, isEmpty);
      await shot(tester, 'new-6-collection-$name');
      // The next one starts on the same model.
      expect(state.prefText('pref_new_model_forge', ''), startsWith('juggernautXL_v9'));
      File(saved).deleteSync();
      await close(tester, state);
    });
  }

  testWidgets('a new picture needs a model and a prompt, and SD 1.x starts at 512', skip: skip, (tester) async {
    final (server, asked) = await forge(tester);
    final state = await launch(tester, tabUltra);
    state.setBackendUrl('forge', 'http://127.0.0.1:${server.port}');
    state.setPref('pref_new_model_forge', '');
    openNewPicture(ctx(tester), state);
    await pumpUntil(tester, () => there('remix-model'), what: 'the server\'s models');
    await tap(tester, find.byKey(const ValueKey('remix-send')));
    expect(find.textContaining('Choose a model to make the picture with.'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('remix-model')));
    await tap(tester, find.text('dreamshaper_8'));
    await pumpUntil(tester, () => find.text('Only LoRAs made for SD 1.x are offered.').evaluate().isNotEmpty, what: 'the model\'s kind');
    await settle(tester);
    await tap(tester, find.byKey(const ValueKey('remix-send')));
    expect(find.textContaining('Write a prompt to make the picture from.'), findsOneWidget);
    expect(asked, isEmpty);
    final prompt = find.descendant(of: find.byKey(const ValueKey('remix-prompt')), matching: find.byType(EditableText));
    await tester.ensureVisible(prompt);
    await tester.enterText(prompt, 'a lighthouse');
    await tap(tester, find.byKey(const ValueKey('remix-send')));
    await pumpUntil(tester, () => state.remixes.value.any((j) => !j.running && j.saved.isNotEmpty), what: 'the new picture', timeout: const Duration(seconds: 60));
    // SD 1.x is made for 512, so that is the size it started at.
    expect((asked.single['width'], asked.single['height']), (512, 512));
    for (final path in state.remixes.value.expand((j) => j.saved)) {
      File(path).deleteSync();
    }
    await close(tester, state);
  });
}
