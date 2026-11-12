// Renders asked for while their server is offline: offered a place in the
// queue, shown on the round button, sent when the server answers (by a
// check asked for, here), cancelled, and kept between runs of the app.
// The real app against the real core, with a small Forge on this machine.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/backends.dart';
import 'package:generativeview/src/core/detail_pass.dart';
import 'package:generativeview/src/core/lora_edits.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/render_queue.dart';
import 'package:generativeview/src/ui/media_grid.dart';
import 'package:generativeview/src/ui/remix_dialog.dart';
import 'package:generativeview/src/ui/upscale_dialog.dart' show ServerUpscalePlan;

import 'support.dart';

void main() {
  test('how often the server is looked for, as it is said', () {
    expect(everyText(15), '15 s');
    expect(everyText(60), '1 min');
    expect(everyText(90), '90 s');
    expect(everyText(900), '15 min');
    expect(queuePollChoices, contains(queuePollDefault));
  });

  test('a recipe kept as JSON reads back the same', () {
    final info = GenInfo.fromJson({
      'source': 'comfyui',
      'prompt': 'a red fox',
      'negative': 'blurry',
      'seed': '42',
      'model': 'sdxl.safetensors',
      'models': [
        {'kind': 'checkpoint', 'name': 'sdxl.safetensors', 'hash': 'abc'},
      ],
      'loras': [
        {'name': 'fur.safetensors', 'weight': 0.8, 'weight_clip': 0.6, 'hash': 'def'},
        {'name': 'plain.safetensors', 'hash': ''},
      ],
      'params': [
        ['steps', '24'],
        ['cfg', '6.5'],
      ],
      'nodes': [
        {
          'id': '3',
          'class': 'KSampler',
          'title': 'Sampler',
          'inputs': [
            ['seed', '42'],
          ],
        },
      ],
      'raw': [
        ['prompt', '{"3": {}}'],
      ],
      'width': 832,
      'height': 1216,
      'duration_ms': 0,
    });
    final back = GenInfo.fromJson(jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>);
    expect(back.source, 'comfyui');
    expect(back.prompt, 'a red fox');
    expect(back.negative, 'blurry');
    expect(back.seed, '42');
    expect(back.model, 'sdxl.safetensors');
    expect(back.models.single.hash, 'abc');
    expect([for (final l in back.loras) (l.name, l.weight, l.weightClip, l.hash)], [
      ('fur.safetensors', 0.8, 0.6, 'def'),
      ('plain.safetensors', null, null, ''),
    ]);
    expect([for (final p in back.params) (p.key, p.value)], [('steps', '24'), ('cfg', '6.5')]);
    expect(back.nodes.single.type, 'KSampler');
    expect(back.nodes.single.inputs.single.value, '42');
    expect(back.raw.single.value, '{"3": {}}');
    expect((back.width, back.height), (832, 1216));
  });

  test('a hires plan kept as JSON reads back the same', () {
    const item = MediaItem(id: 7, dir: '/pictures', name: 'heron.png', isVideo: false, width: 320, height: 480, mtime: 5, size: 9, durationMs: 0, generated: false);
    const plan = ServerUpscalePlan(
      items: [item],
      server: 'invokeai',
      refine: true,
      model: 'realesr',
      factor: 2,
      keepMetadata: false,
      strength: 0.3,
      scale: 2,
      tiles: TileMode.tiles,
      tile: 768,
      overlap: 64,
      detail: DetailPass(faces: true, strength: 0.5, extra: 'detailed eyes', skipped: {1}),
      skip: [DetailRegion(DetailKind.hand, Rect.fromLTRB(0.1, 0.2, 0.3, 0.4), 0.9)],
    );
    final back = ServerUpscalePlan.fromJson(jsonDecode(jsonEncode(plan.toJson())) as Map<String, dynamic>);
    expect(back.items.single.path, item.path);
    expect((back.items.single.width, back.items.single.height, back.items.single.generated), (320, 480, false));
    expect((back.server, back.refine, back.model, back.factor, back.keepMetadata), ('invokeai', true, 'realesr', 2.0, false));
    expect((back.strength, back.scale, back.tiles, back.tile, back.overlap), (0.3, 2.0, TileMode.tiles, 768, 64));
    expect((back.detail!.faces, back.detail!.hands, back.detail!.strength, back.detail!.extra), (true, false, 0.5, 'detailed eyes'));
    expect(back.detail!.skipped, {1});
    expect((back.skip.single.kind, back.skip.single.box, back.skip.single.score), (DetailKind.hand, const Rect.fromLTRB(0.1, 0.2, 0.3, 0.4), 0.9));
  });

  group('with the app', () {
    late Directory scratch;
    late Directory library;
    late NativeCore core;

    setUpAll(() async {
      await loadAppFonts();
      scratch = Directory.systemTemp.createTempSync('gv-queue-test-');
      library = Directory('${scratch.path}/library')..createSync();
      File('${library.path}/heron.png').writeAsBytesSync(pngWithText(320, 320, 5, {'parameters': a1111Parameters('a brass heron, studio light', seed: 5)}));
      File('${library.path}/fox.png').writeAsBytesSync(pngWithText(320, 320, 10, {'parameters': a1111Parameters('a red fox in the snow', seed: 6)}));
      core = NativeCore.start(dataDir: '${scratch.path}/data', cacheDir: '${scratch.path}/cache', libraryPath: coreLibraryPath());
    });

    tearDownAll(() {
      try {
        scratch.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<AppState> launch(WidgetTester tester, {String? queueDir}) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = saved);
      final state = AppState(core: core, thumbs: ThumbCache(core, maxBytes: 64 << 20), queueDir: queueDir);
      await tester.pumpWidget(GenerativeViewApp(state: state));
      var done = false;
      state.restore(initialFolder: library.path).whenComplete(() => done = true);
      await pumpUntil(tester, () => done, what: 'the folder to open');
      await pumpUntil(tester, () => state.items.length >= 2, what: 'the listing');
      return state;
    }

    Future<void> close(WidgetTester tester, AppState state) async {
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      await tester.pump(const Duration(seconds: 5));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// Long enough for a toast to have gone from over the round button.
    Future<void> pastToast(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await settle(tester);
    }

    bool there(String key) => find.byKey(ValueKey<String>(key)).evaluate().isNotEmpty;

    MediaItem named(AppState state, String name) => [for (var i = 0; i < state.items.length; i++) state.items[i]].firstWhere((i) => i.name == name);

    /// An address on this machine nothing answers at.
    Future<String> nowhere(WidgetTester tester) async {
      final port = (await tester.runAsync(() async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = server.port;
        await server.close();
        return port;
      }))!;
      return 'http://127.0.0.1:$port';
    }

    /// A Forge that answers whatever it is asked with a picture, and keeps
    /// what it was asked.
    Future<(String, List<String>, List<Map<String, dynamic>>)> forge(WidgetTester tester) async {
      final paths = <String>[];
      final bodies = <Map<String, dynamic>>[];
      final picture = base64Encode(File('${library.path}/heron.png').readAsBytesSync());
      final server = (await tester.runAsync(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          paths.add(request.uri.path);
          final body = await utf8.decoder.bind(request).join();
          if (body.isNotEmpty) bodies.add(jsonDecode(body) as Map<String, dynamic>);
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'images': [picture], 'info': '{}'}));
          await request.response.close();
        });
        return server;
      }))!;
      addTearDown(() => server.close(force: true));
      return ('http://127.0.0.1:${server.port}', paths, bodies);
    }

    testWidgets('a remix for a server that is off is offered the queue, and sent once the server is back', (tester) async {
      final state = await launch(tester);
      state.setBackendUrl('forge', await nowhere(tester));
      // Only looked for when asked here, so the test decides when.
      state.setPref(queueAutoPref, false);
      await tester.pump();
      expect(there('activity-button'), isFalse);

      // ---- sent to a server that is not there: the offer, and "Not now" ----
      final heron = named(state, 'heron.png');
      unawaited(openRemix(tester.element(find.byType(MediaGrid)), state, heron));
      await pumpUntil(tester, () => there('remix-send'), what: 'the Remix panel');
      await settle(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('remix-send')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('remix-send')));
      await pumpUntil(tester, () => there('queue-offer'), what: 'the offer to queue');
      expect(find.text('Forge / A1111 is not online'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('queue-offer-no')));
      await settle(tester);
      // Not queued: the panel stays, saying why it was not sent.
      expect(state.renderQueue.queued.value, isEmpty);
      expect(there('remix-send'), isTrue);
      expect(find.textContaining('Could not reach Forge / A1111'), findsOneWidget);

      // ---- again, and queued ---------------------------------------------
      await tester.ensureVisible(find.byKey(const ValueKey('remix-send')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('remix-send')));
      await pumpUntil(tester, () => there('queue-offer'), what: 'the offer to queue, again');
      await tester.tap(find.byKey(const ValueKey('queue-offer-yes')));
      await pumpUntil(tester, () => state.renderQueue.queued.value.isNotEmpty, what: 'the render in the queue');
      await pumpUntil(tester, () => !there('remix-send'), what: 'the Remix panel to close');
      final entry = state.renderQueue.queued.value.single;
      expect((entry.kind, entry.type, entry.label, entry.name, entry.renders), ('forge', 'remix', 'remix', 'heron.png', 1));
      expect(entry.title, 'Remix of heron.png');
      expect(state.remixes.value, isEmpty);

      // ---- on the round button: waiting, counted, with a way to check -----
      await pastToast(tester);
      expect(there('activity-button'), isTrue);
      expect(there('activity-queued-icon'), isTrue);
      expect(find.descendant(of: find.byKey(const ValueKey('activity-count')), matching: find.text('1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('activity-button')));
      await settle(tester);
      expect(there('activity-queued'), isTrue);
      expect(find.text('1 render queued'), findsOneWidget);
      expect(find.textContaining('Not checked automatically'), findsOneWidget);
      expect(there('activity-queued-${entry.id}'), isTrue);

      // ---- checked while still off: it stays -----------------------------
      await tester.tap(find.byKey(const ValueKey('activity-queued-check')));
      await pumpUntil(tester, () => !state.renderQueue.checking.value, what: 'the check to finish');
      expect(state.renderQueue.queued.value, hasLength(1));
      expect(state.remixes.value, isEmpty);

      // ---- the server comes up: the next check sends it -------------------
      final (base, paths, bodies) = await forge(tester);
      state.setBackendUrl('forge', base);
      await pastToast(tester);
      if (!there('activity-queued-check')) {
        await tester.tap(find.byKey(const ValueKey('activity-button')));
        await settle(tester);
      }
      await tester.tap(find.byKey(const ValueKey('activity-queued-check')));
      await pumpUntil(tester, () => state.remixes.value.any((j) => !j.running && j.saved.isNotEmpty), what: 'the queued remix to come back', timeout: const Duration(seconds: 60));
      expect(state.renderQueue.queued.value, isEmpty);
      expect(paths, contains('/sdapi/v1/txt2img'));
      expect(bodies.where((b) => b.containsKey('prompt')).single['prompt'], contains('a brass heron, studio light'));
      final saved = state.remixes.value.single.saved.single.replaceAll(r'\', '/');
      expect(saved, endsWith('/heron_remix1.png'));
      expect(File(saved).existsSync(), isTrue);
      state.dismissDoneRemixes();
      File(saved).deleteSync();

      state.setBackendUrl('forge', '');
      state.setPref(queueAutoPref, true);
      await close(tester, state);
    });

    testWidgets('queued renders are kept between runs of the app, pictures and all, until cancelled', (tester) async {
      final dir = Directory('${scratch.path}/queue')..createSync();
      var state = await launch(tester, queueDir: dir.path);
      state.setBackendUrl('forge', await nowhere(tester));
      state.setPref(queueAutoPref, false);
      final fox = named(state, 'fox.png');
      final info = (await tester.runAsync(() => state.metadata(fox)))!;
      final picture = File(fox.path).readAsBytesSync();
      final group = state.renderQueue.newGroup();
      state.renderQueue.addRemix(
        'forge',
        Remix(
          info: info,
          prompt: 'a red fox at dusk',
          negative: 'blurry',
          seed: 11,
          randomSeed: false,
          count: 2,
          width: 512,
          height: 768,
          steps: 20,
          cfg: 5.5,
          loras: [LoraChoice(const LoraRef('fur.safetensors', 0.8, null, ''), enabled: false, weight: 1.2)],
          init: ImageInput(image: picture, strength: 0.45, mask: picture),
        ),
        path: fox.path,
        name: fox.name,
        group: group,
        detail: const DetailPass(faces: true),
      );
      state.renderQueue.addUpscale(ServerUpscalePlan(items: [fox], server: 'forge', refine: true, scale: 1));
      expect(state.renderQueue.queued.value, hasLength(2));
      expect(state.renderQueue.renders, 3);
      // On disk: each render, and the first one's picture and mask.
      List<String> kept() => [for (final f in dir.listSync()) f.uri.pathSegments.last]..sort();
      final first = state.renderQueue.queued.value.first;
      expect(kept(), containsAll(['${first.id}.json', '${first.id}-init.png', '${first.id}-mask.png']));
      expect(kept(), hasLength(4));
      await close(tester, state);

      // ---- the next run: back as they were --------------------------------
      state = await launch(tester, queueDir: dir.path);
      final back = state.renderQueue.queued.value;
      expect([for (final e in back) (e.kind, e.type, e.label, e.name, e.renders)], [
        ('forge', 'remix', 'remix', 'fox.png', 2),
        ('forge', 'upscale', 'hires', 'fox.png', 1),
      ]);
      expect(back.first.group, group);
      expect(back.first.id, first.id);
      final remix = back.first.body['remix'] as Map<String, dynamic>;
      expect((remix['prompt'], remix['seed'], remix['count'], remix['width'], remix['height'], remix['steps'], remix['cfg']), ('a red fox at dusk', 11, 2, 512, 768, 20, 5.5));
      expect(((remix['loras'] as List).single as Map)['on'], isFalse);
      expect((remix['init'] as Map)['strength'], 0.45);
      expect(((remix['info'] as Map)['prompt'] as String), contains('a red fox in the snow'));
      expect((back.first.body['detail'] as Map)['faces'], isTrue);
      expect(back.first.body['path'], fox.path);
      // Shown on the round button, the pair as two runs.
      await pastToast(tester);
      expect(there('activity-queued-icon'), isTrue);
      await tester.tap(find.byKey(const ValueKey('activity-button')));
      await settle(tester);
      expect(find.text('3 renders queued'), findsOneWidget);
      expect(find.text('Remix of fox.png, 2 queued'), findsOneWidget);
      expect(find.text('Hires fix of fox.png'), findsOneWidget);

      // ---- one cancelled, then the rest: nothing left, on disk either -----
      await tester.tap(find.descendant(of: find.byKey(ValueKey('activity-queued-${back.last.id}')), matching: find.byType(IconButton)));
      await settle(tester);
      expect(state.renderQueue.queued.value.single.id, first.id);
      expect(kept(), hasLength(3));
      state.renderQueue.cancelAll();
      await settle(tester);
      expect(state.renderQueue.queued.value, isEmpty);
      expect(kept(), isEmpty);
      expect(there('activity-button'), isFalse);

      state.setBackendUrl('forge', '');
      state.setPref(queueAutoPref, true);
      await close(tester, state);
    });
  });
}
