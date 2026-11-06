// The server's LoRAs, listed with the kind of model each was made for. Each
// backend is played by a small server on this machine that answers the way
// the real one does. No widget tests here: their binding turns every HTTP
// request into a 400 (see lora_picker_test.dart for the panel).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/server_loras.dart';

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
}
