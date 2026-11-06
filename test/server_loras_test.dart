// Adding a LoRA in the remix panel: the server's LoRAs are listed with the
// kind of model each was made for, and only those that fit the model being
// rendered with are offered. Each backend is played by a small server on this
// machine that answers the way the real one does.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/lora_edits.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/server_loras.dart';
import 'package:generativeview/src/ui/lora_picker.dart';
import 'package:generativeview/src/ui/remix_dialog.dart' show LoraSection;

Future<(HttpServer, String)> serve(FutureOr<void> Function(HttpRequest request) handle) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      await handle(request);
    } catch (e) {
      request.response.statusCode = 500;
      request.response.write('$e');
    }
    await request.response.close();
  });
  return (server, 'http://127.0.0.1:${server.port}');
}

void json(HttpRequest request, Object body) {
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
}

GenInfo picture({String model = '', List<List<String>> raw = const [], List<Map<String, Object?>> loras = const []}) =>
    GenInfo.fromJson({
      'source': 'invokeai',
      'prompt': 'a red fox',
      'negative': '',
      'seed': '7',
      'model': model,
      'loras': loras,
      'raw': raw,
      'width': 1024,
      'height': 1024,
    });

void main() {
  group('family', () {
    test('from a file\'s metadata', () {
      expect(familyFromMetadata({'modelspec.architecture': 'stable-diffusion-xl-v1-base/lora'}), 'sdxl');
      expect(familyFromMetadata({'modelspec.architecture': 'stable-diffusion-v1/lora'}), 'sd-1');
      expect(familyFromMetadata({'modelspec.architecture': 'flux-1-dev/lora'}), 'flux');
      expect(familyFromMetadata({'ss_base_model_version': 'sdxl_base_v1-0', 'ss_network_module': 'networks.lora'}), 'sdxl');
      expect(familyFromMetadata({'ss_base_model_version': 'sd_v1'}), 'sd-1');
      expect(familyFromMetadata({'ss_base_model_version': 'flux1'}), 'flux');
      // Older kohya: no base model version, only whether it was SD 2.
      expect(familyFromMetadata({'ss_network_module': 'networks.lora', 'ss_v2': 'False'}), 'sd-1');
      expect(familyFromMetadata({'ss_network_module': 'networks.lora', 'ss_v2': 'True'}), 'sd-2');
      expect(familyFromMetadata({'trained_on': 'Krea-2-Raw'}), 'krea-2');
      expect(familyFromMetadata({'format': 'pt'}), isNull);
    });

    test('from a file or folder name, when that is all there is', () {
      expect(familyFromName('SDXL/detail_tweaker.safetensors'), 'sdxl');
      expect(familyFromName('add_detail_xl.safetensors'), 'sdxl');
      expect(familyFromName('juggernautXL_v9.safetensors'), 'sdxl');
      expect(familyFromName('ponyDiffusionV6.safetensors'), 'sdxl');
      expect(familyFromName('flux/realism_lora.safetensors'), 'flux');
      expect(familyFromName('krea2_turbo_fp8_scaled.safetensors'), 'krea-2');
      expect(familyFromName('sd15/epi_noiseoffset.safetensors'), 'sd-1');
      expect(familyFromName('v1-5-pruned-emaonly.safetensors [6ce0161689]'), isNull);
      expect(familyFromName('fur_detail.safetensors'), isNull);
    });

    test('a picture\'s own model, from its InvokeAI metadata', () {
      final info = picture(model: 'mystery', raw: [
        ['invokeai_metadata', jsonEncode({'model': {'name': 'mystery', 'base': 'sdxl', 'type': 'main'}})],
      ]);
      expect(recordedFamily(info), 'sdxl');
      expect(recordedFamily(picture(model: 'Krea-2-Turbo')), 'krea-2');
      expect(recordedFamily(picture(model: 'mystery')), isNull);
    });

    test('LoRAs sorted into those that fit, those that cannot be told, and the rest', () {
      const loras = [
        ServerModel('b_xl', 'sdxl'),
        ServerModel('a_xl', 'sdxl'),
        ServerModel('flux_one', 'flux'),
        ServerModel('who_knows'),
      ];
      final xl = sortLoras(loras, 'sdxl');
      expect([for (final l in xl.fitting) l.name], ['a_xl', 'b_xl']);
      expect([for (final l in xl.unknown) l.name], ['who_knows']);
      expect(xl.other, 1);
      // The model's kind not known: every one is listed as unchecked.
      final any = sortLoras(loras, null);
      expect(any.fitting, isEmpty);
      expect(any.unknown, hasLength(4));
    });
  });

  group('serverLoras', () {
    test('InvokeAI says each LoRA\'s base', () async {
      final (server, base) = await serve((r) {
        expect(r.uri.path, '/api/v2/models/');
        expect(r.uri.queryParameters['model_type'], 'lora');
        json(r, {
          'models': [
            {'key': 'a', 'hash': 'h', 'name': 'Detail XL', 'base': 'sdxl', 'type': 'lora'},
            {'key': 'b', 'hash': 'h', 'name': 'Krea Style', 'base': 'krea-2', 'type': 'lora'},
            {'key': 'c', 'hash': 'h', 'name': 'Whatever', 'base': 'any', 'type': 'lora'},
          ],
        });
      });
      addTearDown(() => server.close(force: true));
      final loras = await serverLoras('invokeai', base);
      expect([for (final l in loras) (l.name, l.family)], [('Detail XL', 'sdxl'), ('Krea Style', 'krea-2'), ('Whatever', null)]);
    });

    test('ComfyUI: each file\'s metadata, then its name', () async {
      final asked = <String>[];
      final (server, base) = await serve((r) {
        if (r.uri.path == '/object_info/LoraLoader') {
          json(r, {
            'LoraLoader': {
              'input': {
                'required': {
                  'lora_name': [
                    ['styles/painted.safetensors', 'flux/realism.safetensors', 'mystery.safetensors'],
                  ],
                },
              },
            },
          });
        } else if (r.uri.path == '/view_metadata/loras') {
          final file = r.uri.queryParameters['filename']!;
          asked.add(file);
          if (file == 'styles/painted.safetensors') {
            json(r, {'modelspec.architecture': 'stable-diffusion-xl-v1-base/lora'});
          } else {
            r.response.statusCode = 404;
          }
        } else {
          r.response.statusCode = 404;
        }
      });
      addTearDown(() => server.close(force: true));
      final loras = await serverLoras('comfyui', base);
      expect([for (final l in loras) (l.name, l.family)], [
        ('styles/painted.safetensors', 'sdxl'),
        ('flux/realism.safetensors', 'flux'),
        ('mystery.safetensors', null),
      ]);
      expect(asked, hasLength(3));
      // Asked once while the app is open.
      await serverLoras('comfyui', base);
      expect(asked, hasLength(3));
    });

    test('Forge lists each LoRA with its metadata', () async {
      final (server, base) = await serve((r) {
        expect(r.uri.path, '/sdapi/v1/loras');
        json(r, [
          {'name': 'add_detail', 'path': '/models/Lora/add_detail.safetensors', 'metadata': {'ss_base_model_version': 'sd_v1'}},
          {'name': 'xl_more_art', 'path': '/models/Lora/SDXL/xl_more_art.safetensors', 'metadata': <String, Object>{}},
        ]);
      });
      addTearDown(() => server.close(force: true));
      final loras = await serverLoras('forge', base);
      expect([for (final l in loras) (l.name, l.family)], [('add_detail', 'sd-1'), ('xl_more_art', 'sdxl')]);
    });

    test('the picture\'s own model on InvokeAI takes its base from the listing', () async {
      final (server, base) = await serve((r) {
        json(r, {
          'models': [
            {'key': 'm', 'hash': 'h', 'name': 'Krea-2-Turbo', 'base': 'krea-2', 'type': 'main'},
            {'key': 'n', 'hash': 'h', 'name': 'Juggernaut', 'base': 'sdxl', 'type': 'main'},
          ],
        });
      });
      addTearDown(() => server.close(force: true));
      final mains = await serverMainModels('invokeai', base);
      expect(await pictureModelFamily('invokeai', base, picture(model: 'Juggernaut'), mains, () async => const []), 'sdxl');
      expect(await modelFamily('invokeai', base, mains.first), 'krea-2');
    });

    test('when nothing else says, the picture\'s LoRAs on the server tell its model\'s kind', () async {
      final info = picture(model: 'mystery', loras: [
        {'name': 'painted', 'weight': 0.8},
      ]);
      final family = await pictureModelFamily('forge', 'http://127.0.0.1:1', info, const [], () async => const [ServerModel('painted', 'sdxl')]);
      expect(family, 'sdxl');
    });
  });

  group('picker', () {
    const loras = [
      ServerModel('SDXL/detail_xl.safetensors', 'sdxl'),
      ServerModel('styles/painted.safetensors', 'sdxl'),
      ServerModel('flux/realism.safetensors', 'flux'),
      ServerModel('mystery.safetensors'),
    ];

    Future<void> open(WidgetTester tester, {String? family, Set<String> have = const {}}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickLora(context, loras: Future.value(loras), family: family, model: 'juggernautXL_v9.safetensors', have: have),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists only those made for the model\'s kind', (tester) async {
      await open(tester, family: 'sdxl', have: {'painted'});
      expect(find.text('detail_xl'), findsOneWidget);
      expect(find.text('painted'), findsOneWidget);
      expect(find.text('realism'), findsNothing);
      expect(find.text('mystery'), findsNothing);
      expect(find.textContaining('2 made for SDXL, like juggernautXL_v9'), findsOneWidget);
      expect(find.textContaining('1 for other kinds hidden'), findsOneWidget);
      // The one already in the remix cannot be added twice.
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('lora-picker-painted'))).enabled, isFalse);
      // Those that cannot be checked are behind a switch.
      await tester.tap(find.byKey(const ValueKey('lora-picker-unknown')));
      await tester.pumpAndSettle();
      expect(find.text('mystery'), findsOneWidget);
      expect(find.text('realism'), findsNothing);
    });

    testWidgets('picking one closes the picker with it', (tester) async {
      ServerModel? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await pickLora(context, loras: Future.value(loras), family: 'sdxl', model: 'x', have: const {}),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('detail_xl'));
      await tester.pumpAndSettle();
      expect(picked?.name, 'SDXL/detail_xl.safetensors');
      expect(find.byType(LoraPicker), findsNothing);
    });

    testWidgets('a model of unknown kind lists every LoRA, and says so', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('lora-picker-note')), findsOneWidget);
      expect(find.textContaining('Could not tell what kind of model'), findsOneWidget);
      for (final name in ['detail_xl', 'painted', 'realism', 'mystery']) {
        expect(find.text(name), findsOneWidget);
      }
    });
  });

  testWidgets('an added LoRA is marked, can be taken out, and the section offers Add', (tester) async {
    final loras = [
      LoraChoice(const LoraRef('fur_detail.safetensors', 0.8, null, '')),
      LoraChoice(const LoraRef('SDXL/detail_xl.safetensors', 1.0, null, '')),
    ];
    final addedKey = loras[1].key;
    var adds = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Center(
            child: SizedBox(
              width: 424,
              child: LoraSection(
                loras: loras,
                added: {for (final l in loras) if (l.key == addedKey) l.key},
                notes: {addedKey: 'Made for FLUX.1, not SDXL; the server will skip it'},
                onAddLora: () => adds++,
                onRemove: (i) => setState(() => loras.removeAt(i)),
              ),
            ),
          ),
        ),
      ),
    ));
    expect(tester.widget<Text>(find.byKey(const ValueKey('remix-loras-summary'))).data, '2 · 1 added');
    await tester.tap(find.byKey(const ValueKey('remix-loras')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remix-lora-added-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('remix-lora-added-0')), findsNothing);
    expect(find.byKey(const ValueKey('remix-lora-note-1')), findsOneWidget);
    // Only an added one can be taken out; the picture's own are switched off.
    expect(find.byKey(const ValueKey('remix-lora-remove-0')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('remix-lora-add')));
    expect(adds, 1);
    await tester.tap(find.byKey(const ValueKey('remix-lora-remove-1')));
    await tester.pumpAndSettle();
    expect(loras, hasLength(1));
    expect(find.text('detail_xl'), findsNothing);
  });
}
