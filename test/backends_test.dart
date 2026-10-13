// Remixes come back: each backend is played by a small server on this
// machine that answers the way the real one does, and the pictures it hands
// back are checked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/backends.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/recipe_graphs.dart';

/// The smallest PNG there is: signature, a 1×1 header, no pixels, the end.
/// Enough for the code under test, which only looks at its chunks.
Uint8List tinyPng([int marker = 0]) {
  final b = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    // IHDR: length 13, type, 13 bytes, crc (not checked here).
    ..add(const [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
    ..add([0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, marker])
    ..add(const [0, 0, 0, 0])
    // IEND.
    ..add(const [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]);
  return b.toBytes();
}

/// The chunks of a PNG, as (type, data).
List<(String, Uint8List)> chunks(Uint8List png) {
  final out = <(String, Uint8List)>[];
  final view = ByteData.sublistView(png);
  var at = 8;
  while (at + 8 <= png.length) {
    final length = view.getUint32(at);
    out.add((
      String.fromCharCodes(png.sublist(at + 4, at + 8)),
      png.sublist(at + 8, at + 8 + length),
    ));
    at += 12 + length;
  }
  return out;
}

GenInfo info({required String source, List<List<String>> raw = const []}) =>
    GenInfo.fromJson({
      'source': source,
      'prompt': 'a red fox',
      'negative': 'blurry',
      'seed': '7',
      'params': [
        ['Steps', '20'],
        ['CFG scale', '7'],
      ],
      'raw': raw,
      'width': 512,
      'height': 512,
    });

Remix remix(GenInfo info, {int count = 1}) => Remix(
  info: info,
  prompt: 'a red fox',
  negative: 'blurry',
  seed: 7,
  randomSeed: false,
  count: count,
  width: 512,
  height: 512,
);

/// A server answering [handle] on a free port of this machine.
Future<(HttpServer, String)> serve(
  FutureOr<void> Function(HttpRequest request) handle,
) async {
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

void main() {
  setUp(() => remixPollEvery = const Duration(milliseconds: 20));

  test('picture types are told apart by their bytes', () {
    expect(imageExtension(tinyPng()), 'png');
    expect(imageExtension([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]), 'jpg');
    expect(
      imageExtension([...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBPVP8 ')]),
      'webp',
    );
  });

  test('settings are written into a PNG that lacks them, once', () {
    final png = tinyPng();
    const text = 'a red fox, ünïcode\nSteps: 20, Seed: 7';
    final out = withParameters(png, text);
    final list = chunks(out);
    expect(list.map((c) => c.$1), ['IHDR', 'iTXt', 'IEND']);
    final data = list[1].$2;
    expect(latin1.decode(data.sublist(0, 10)), 'parameters');
    expect(data.sublist(10, 15), [0, 0, 0, 0, 0]);
    expect(utf8.decode(data.sublist(15)), text);
    // The chunk's checksum is the standard CRC-32 of its type and data.
    final view = ByteData.sublistView(out);
    const at = 8 + 25;
    final crc = view.getUint32(at + 8 + data.length);
    expect(crc, crc32([...ascii.encode('iTXt'), ...data]));
    // A second time changes nothing; nor does it touch a JPEG.
    expect(withParameters(out, 'other'), out);
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(40, 0)]);
    expect(withParameters(jpeg, text), jpeg);
  });

  test('ComfyUI: queued, waited for, and what Save wrote fetched', () async {
    var asked = 0;
    final queued = <Map<String, dynamic>>[];
    final (server, base) = await serve((request) async {
      final path = request.uri.path;
      if (path == '/prompt') {
        queued.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        json(request, {'prompt_id': 'p${queued.length}'});
      } else if (path.startsWith('/history/')) {
        final id = path.split('/').last;
        // Not done the first couple of times it is asked.
        if (++asked < 3) {
          json(request, {});
          return;
        }
        json(request, {
          id: {
            'status': {'status_str': 'success', 'completed': true},
            'outputs': {
              '9': {
                'images': [
                  {'filename': '${id}_out.png', 'subfolder': 'gv', 'type': 'output'},
                  {'filename': '${id}_preview.png', 'subfolder': '', 'type': 'temp'},
                ],
              },
            },
          },
        });
      } else if (path == '/view') {
        final q = request.uri.queryParameters;
        expect(q['type'], 'output');
        expect(q['subfolder'], 'gv');
        request.response.add(tinyPng(q['filename'] == 'p1_out.png' ? 1 : 2));
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final graph = jsonEncode({
      '3': {'class_type': 'KSampler', 'inputs': {'seed': 1, 'steps': 20}},
      '6': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'a red fox'}},
      '9': {'class_type': 'SaveImage', 'inputs': {'filename_prefix': 'gv'}},
    });
    final ticket = await sendRemix(
      'comfyui',
      base,
      remix(info(source: 'comfyui', raw: [['prompt', graph]]), count: 2),
    );
    expect(ticket.message, 'Queued 2 pictures in ComfyUI');
    final images = await ticket.results.toList();
    expect(images, hasLength(2), reason: 'previews are not kept');
    expect(images.map((i) => i.bytes[28]), [1, 2]);
    expect(images.first.extension, 'png');
  });

  test('ComfyUI: a failed run is reported', () async {
    final (server, base) = await serve((request) async {
      if (request.uri.path == '/prompt') {
        json(request, {'prompt_id': 'x'});
        return;
      }
      json(request, {
        'x': {
          'status': {
            'status_str': 'error',
            'messages': [
              ['execution_error', {'exception_message': 'Out of memory '}],
            ],
          },
          'outputs': {},
        },
      });
    });
    addTearDown(() => server.close(force: true));
    final graph = jsonEncode({
      '6': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'a red fox'}},
    });
    final ticket = await sendRemix('comfyui', base, remix(info(source: 'comfyui', raw: [['prompt', graph]])));
    await expectLater(
      ticket.results.toList(),
      throwsA(isA<BackendException>().having((e) => e.message, 'message', 'ComfyUI: Out of memory')),
    );
  });

  test('InvokeAI: queue items waited for, kept pictures fetched', () async {
    var polls = 0;
    final (server, base) = await serve((request) async {
      final path = Uri.decodeFull(request.uri.path);
      if (path.endsWith('/enqueue_batch')) {
        json(request, {
          'batch': {'batch_id': 'b1'},
          'item_ids': [41],
        });
      } else if (path == '/api/v1/queue/default/i/41') {
        json(request, {
          'item_id': 41,
          'status': ++polls < 3 ? 'in_progress' : 'completed',
          'session': {
            'results': {
              'noise': {'type': 'noise_output'},
              'l2i_mid': {'type': 'image_output', 'image': {'image_name': 'mid.png'}},
              'l2i': {'type': 'image_output', 'image': {'image_name': 'final one.png'}},
            },
          },
        });
      } else if (path == '/api/v1/images/i/mid.png') {
        json(request, {'image_name': 'mid.png', 'is_intermediate': true});
      } else if (path == '/api/v1/images/i/final one.png') {
        json(request, {'image_name': 'final one.png', 'is_intermediate': false});
      } else if (path == '/api/v1/images/i/final one.png/full') {
        request.response.add(tinyPng(5));
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final graph = jsonEncode({
      'nodes': {
        'pos': {'id': 'pos', 'type': 'compel', 'prompt': 'a red fox'},
        'noise': {'id': 'noise', 'type': 'noise', 'seed': 1},
      },
    });
    final ticket = await sendRemix(
      'invokeai',
      base,
      remix(info(source: 'invokeai', raw: [['invokeai_graph', graph]])),
    );
    expect(ticket.message, 'Queued 1 picture in InvokeAI');
    final images = await ticket.results.toList();
    expect(images, hasLength(1), reason: 'intermediate pictures are not kept');
    expect(images.single.bytes[28], 5);
  });

  test('Forge: the pictures in its answer, with their settings', () async {
    late Map<String, dynamic> payload;
    final (server, base) = await serve((request) async {
      payload = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      // Slower than the four seconds it is given to start.
      await Future<void>.delayed(const Duration(seconds: 5));
      json(request, {
        // A grid of both first, as A1111 sends with several pictures.
        'images': [for (final m in [9, 1, 2]) base64Encode(tinyPng(m))],
        'info': jsonEncode({
          'infotexts': ['a red fox\nSeed: 7', 'a red fox\nSeed: 8'],
        }),
      });
    });
    addTearDown(() => server.close(force: true));
    final ticket = await sendRemix('forge', base, remix(info(source: 'a1111'), count: 2));
    expect(ticket.message, 'Sent 2 pictures to Forge / A1111');
    final images = await ticket.results.toList();
    expect(payload['send_images'], isTrue);
    expect(images, hasLength(2), reason: 'the grid is left out');
    expect(images.map((i) => i.bytes[28]), [1, 2]);
    final text = chunks(images[1].bytes).firstWhere((c) => c.$1 == 'iTXt').$2;
    expect(utf8.decode(text.sublist(15)), 'a red fox\nSeed: 8');
  });

  // ------------------------------------------------ pictures from elsewhere

  /// A picture made in Forge / A1111: settings, no graph of any program's.
  GenInfo forgePicture() => GenInfo.fromJson({
        'source': 'a1111',
        'prompt': 'a red fox',
        'negative': 'blurry',
        'seed': '7',
        'model': 'juggernautXL_v9',
        'loras': [
          {'name': 'fur_detail', 'weight': 0.8},
          {'name': 'not_installed', 'weight': 0.5},
        ],
        'params': [
          ['Steps', '28'],
          ['CFG scale', '6.5'],
          ['Sampler', 'DPM++ 2M Karras'],
          ['Clip skip', '2'],
        ],
        'raw': [
          ['parameters', 'a red fox\nSteps: 28'],
        ],
        'width': 832,
        'height': 1216,
      });

  test('any picture with settings can go to every server', () {
    final support = backendSupport(forgePicture());
    expect(support.values, everyElement(isNull));
    expect(carriesGraph('comfyui', forgePicture()), isFalse);
    expect(carriesGraph('invokeai', forgePicture()), isFalse);
    expect(backendSupport(info(source: '')).values, everyElement(isNotNull));
  });

  test('samplers are understood in each program\'s words', () {
    expect(canonicalSampler('DPM++ 2M Karras', null), ('dpmpp_2m', 'karras'));
    expect(canonicalSampler('DPM++ 2M', 'Karras'), ('dpmpp_2m', 'karras'));
    expect(canonicalSampler('Euler a', null), ('euler_ancestral', null));
    expect(canonicalSampler('dpmpp_2m_sde_k', null), ('dpmpp_2m_sde', 'karras'));
    expect(canonicalSampler('euler_ancestral', 'normal'), ('euler_ancestral', 'normal'));
    expect(canonicalSampler('something new', null), (null, null));
    // InvokeAI's one setting names both.
    expect(canonicalSampler(null, 'dpmpp_2m_k'), ('dpmpp_2m', 'karras'));
    expect(canonicalSampler(null, 'euler_a'), ('euler_ancestral', null));
    expect(invokeScheduler('dpmpp_2m', 'karras'), 'dpmpp_2m_k');
    expect(invokeScheduler('euler_ancestral', null), 'euler_a');
    expect(invokeScheduler('uni_pc', 'normal'), 'unipc');
    expect(modelKey('SDXL/juggernautXL_v9.safetensors [a1b2c3]'), 'juggernautxl_v9');
  });

  test('ComfyUI: a picture from elsewhere gets a workflow built from its settings', () async {
    final queued = <Map<String, dynamic>>[];
    final (server, base) = await serve((request) async {
      final path = request.uri.path;
      if (path == '/object_info/CheckpointLoaderSimple') {
        json(request, {
          'CheckpointLoaderSimple': {
            'input': {
              'required': {
                'ckpt_name': [
                  ['sd15/dreamshaper_8.safetensors', 'SDXL/juggernautXL_v9.safetensors'],
                ],
              },
            },
          },
        });
      } else if (path == '/object_info/LoraLoader') {
        // The newer shape of a list of choices.
        json(request, {
          'LoraLoader': {
            'input': {
              'required': {
                'lora_name': [
                  'COMBO',
                  {
                    'options': ['xl/fur_detail.safetensors'],
                  },
                ],
              },
            },
          },
        });
      } else if (path == '/prompt') {
        queued.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        json(request, {'prompt_id': 'p${queued.length}'});
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final ticket = await sendRemix('comfyui', base, remix(forgePicture(), count: 2));
    expect(ticket.message, contains('made from its settings'));
    expect(ticket.message, contains('not_installed'), reason: 'the missing LoRA is named');
    expect(queued, hasLength(2));
    final graph = queued.first['prompt'] as Map<String, dynamic>;
    Map<String, dynamic> one(String type) =>
        graph.values.cast<Map<String, dynamic>>().singleWhere((n) => n['class_type'] == type)['inputs'] as Map<String, dynamic>;
    expect(one('CheckpointLoaderSimple')['ckpt_name'], 'SDXL/juggernautXL_v9.safetensors');
    expect(one('LoraLoader')['lora_name'], 'xl/fur_detail.safetensors');
    expect(one('LoraLoader')['strength_model'], 0.8);
    expect(one('CLIPSetLastLayer')['stop_at_clip_layer'], -2);
    final sampler = one('KSampler');
    expect(sampler['seed'], 7);
    expect(sampler['steps'], 28);
    expect(sampler['cfg'], 6.5);
    expect(sampler['sampler_name'], 'dpmpp_2m');
    expect(sampler['scheduler'], 'karras');
    expect(one('EmptyLatentImage'), containsPair('width', 512));
    final texts = graph.values.cast<Map<String, dynamic>>().where((n) => n['class_type'] == 'CLIPTextEncode').map((n) => n['inputs']['text']);
    expect(texts, ['a red fox', 'blurry']);
    expect(graph.values.cast<Map<String, dynamic>>().where((n) => n['class_type'] == 'SaveImage'), hasLength(1));
    // The next picture, the next seed.
    final second = queued[1]['prompt'] as Map<String, dynamic>;
    expect(second.values.cast<Map<String, dynamic>>().singleWhere((n) => n['class_type'] == 'KSampler')['inputs']['seed'], 8);
    // Every link points at a node that is there.
    for (final node in graph.values.cast<Map<String, dynamic>>()) {
      for (final v in (node['inputs'] as Map).values) {
        if (v is List && v.length == 2 && v.first is String) expect(graph.containsKey(v.first), isTrue, reason: '$v');
      }
    }
  });

  test('ComfyUI: a model it does not have is said plainly', () async {
    final (server, base) = await serve((request) async {
      json(request, {
        'CheckpointLoaderSimple': {
          'input': {
            'required': {
              'ckpt_name': [
                ['other.safetensors'],
              ],
            },
          },
        },
        'LoraLoader': {
          'input': {
            'required': {
              'lora_name': [<String>[]],
            },
          },
        },
      });
    });
    addTearDown(() => server.close(force: true));
    await expectLater(
      sendRemix('comfyui', base, remix(forgePicture())),
      throwsA(isA<BackendException>().having((e) => e.message, 'message', contains('juggernautXL_v9'))),
    );
  });

  test('InvokeAI: a picture from elsewhere gets an SDXL graph built from its settings', () async {
    final batches = <Map<String, dynamic>>[];
    Map<String, dynamic> model(String key, String name, String base, String type) =>
        {'key': key, 'hash': 'blake3:$key', 'name': name, 'base': base, 'type': type, 'path': '/models/$name.safetensors'};
    final (server, base) = await serve((request) async {
      final path = request.uri.path;
      if (path == '/api/v2/models/') {
        final type = request.uri.queryParameters['model_type'];
        json(request, {
          'models': type == 'main'
              ? [model('m1', 'dreamshaper_8', 'sd-1', 'main'), model('m2', 'juggernautXL_v9', 'sdxl', 'main')]
              : [model('l1', 'fur_detail', 'sdxl', 'lora'), model('l2', 'fur_detail', 'sd-1', 'lora')],
        });
      } else if (path == '/api/v1/queue/default/enqueue_batch') {
        batches.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        json(request, {'item_ids': [batches.length]});
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final ticket = await sendRemix('invokeai', base, remix(forgePicture()));
    expect(ticket.message, contains('made from its settings'));
    final graph = (batches.single['batch'] as Map)['graph'] as Map<String, dynamic>;
    final nodes = graph['nodes'] as Map<String, dynamic>;
    final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();
    expect(nodes['model_loader']['type'], 'sdxl_model_loader');
    expect(nodes['model_loader']['model']['key'], 'm2');
    final lora = nodes.values.cast<Map<String, dynamic>>().singleWhere((n) => n['type'] == 'sdxl_lora_loader');
    expect(lora['lora']['key'], 'l1', reason: 'the SDXL one, not the SD 1.5 one of the same name');
    expect(lora['weight'], 0.8);
    expect(nodes['positive']['type'], 'sdxl_compel_prompt');
    expect(nodes['positive']['prompt'], 'a red fox');
    expect(nodes['negative']['prompt'], 'blurry');
    expect(nodes['noise']['seed'], 7);
    expect(nodes['noise']['width'], 512);
    expect(nodes['denoise']['scheduler'], 'dpmpp_2m_k');
    expect(nodes['denoise']['steps'], 28);
    expect(nodes['denoise']['cfg_scale'], 6.5);
    expect(nodes['l2i']['is_intermediate'], isFalse);
    expect(nodes['metadata']['type'], 'core_metadata');
    expect(nodes['metadata']['positive_prompt'], 'a red fox');
    // Every edge joins two nodes that are there.
    for (final e in edges) {
      expect(nodes.containsKey(e['source']['node_id']), isTrue, reason: '$e');
      expect(nodes.containsKey(e['destination']['node_id']), isTrue, reason: '$e');
    }
    bool joined(String from, String out, String to, String into) => edges.any((e) =>
        e['source']['node_id'] == from && e['source']['field'] == out && e['destination']['node_id'] == to && e['destination']['field'] == into);
    expect(joined('positive', 'conditioning', 'denoise', 'positive_conditioning'), isTrue);
    expect(joined('denoise', 'latents', 'l2i', 'latents'), isTrue);
    expect(joined('model_loader', 'vae', 'l2i', 'vae'), isTrue);
    expect(joined('metadata', 'metadata', 'l2i', 'metadata'), isTrue);
  });

  test('InvokeAI: a kind of model it cannot build for is said plainly', () {
    final recipe = Recipe.from(forgePicture(), prompt: 'p', negative: 'n', width: 512, height: 512);
    const flux = InvokeModel(key: 'f', hash: '', name: 'juggernautXL_v9', base: 'flux', type: 'main');
    expect(
      () => invokeGraph(recipe, 1, [flux], const []),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('flux'))),
    );
  });
}

/// Standard CRC-32, written out here so the test does not lean on the code
/// it checks.
int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
