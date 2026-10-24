// Remixes come back: each backend is played by a small server on this
// machine that answers the way the real one does, and the pictures it hands
// back are checked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/backends.dart';
import 'package:generativeview/src/core/lora_edits.dart';
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

  // ------------------------------------------------ Krea 2 from elsewhere

  /// A Krea 2 picture made in ComfyUI: a single-file model, with the VAE and
  /// text encoder it was loaded with, a LoRA, and Turbo's settings.
  GenInfo comfyKrea2({double cfg = 1}) => GenInfo.fromJson({
        'source': 'comfyui',
        'prompt': 'a red fox in the snow',
        'negative': 'blurry',
        'seed': '7',
        'model': 'kreamania_variant6.safetensors',
        'models': [
          {'kind': 'unet', 'name': 'kreamania_variant6.safetensors', 'hash': ''},
          {'kind': 'vae', 'name': 'qwen_image_vae.safetensors', 'hash': ''},
          {'kind': 'clip', 'name': 'qwen3_vl_4b_fp8.safetensors', 'hash': ''},
        ],
        'loras': [
          {'name': 'krea2/fur_detail.safetensors', 'weight': 0.8},
        ],
        'params': [
          ['Steps', '8'],
          ['CFG', '$cfg'],
          ['Sampler', 'euler'],
        ],
        'width': 832,
        'height': 1216,
      });

  InvokeModel m(String key, String name, String base, String type, {String format = 'checkpoint', String variant = ''}) =>
      InvokeModel(key: key, hash: 'blake3:$key', name: name, base: base, type: type, path: '/models/$name.safetensors', format: format, variant: variant);

  final krea2Main = m('k2', 'kreamania_variant6', 'krea-2', 'main', variant: 'krea2_turbo');
  final krea2Vaes = [
    m('sdv', 'sdxl_vae', 'sdxl', 'vae'),
    m('av', 'other_wan_vae', 'anima', 'vae'),
    m('qv', 'qwen_image_vae', 'qwen-image', 'vae'),
  ];
  final krea2Encoders = [
    m('e8', 'qwen3_vl_8b', 'any', 'qwen3_vl_encoder', variant: 'qwen3_vl_8b'),
    m('e4', 'qwen3_vl_4b_fp8', 'any', 'qwen3_vl_encoder', variant: 'qwen3_vl_4b'),
  ];

  bool joinedIn(List<Map<String, dynamic>> edges, String from, String out, String to, String into) => edges.any((e) =>
      e['source']['node_id'] == from && e['source']['field'] == out && e['destination']['node_id'] == to && e['destination']['field'] == into);

  void wholeGraph(Map<String, dynamic> graph) {
    final nodes = graph['nodes'] as Map<String, dynamic>;
    for (final e in (graph['edges'] as List).cast<Map<String, dynamic>>()) {
      expect(nodes.containsKey(e['source']['node_id']), isTrue, reason: '$e');
      expect(nodes.containsKey(e['destination']['node_id']), isTrue, reason: '$e');
    }
  }

  test('InvokeAI: a Krea 2 picture from elsewhere gets a Krea 2 graph, as InvokeAI builds one', () {
    final info = comfyKrea2();
    final recipe = Recipe.from(info, prompt: info.prompt, negative: info.negative, width: 832, height: 1216);
    expect(recipe.vae, 'qwen_image_vae.safetensors');
    expect(recipe.textEncoder, 'qwen3_vl_4b_fp8.safetensors');
    final skipped = <String>[];
    final graph = invokeGraph(
      recipe,
      7,
      [krea2Main],
      [m('l1', 'fur_detail', 'krea-2', 'lora'), m('l2', 'fur_detail', 'sdxl', 'lora')],
      vaes: krea2Vaes,
      encoders: krea2Encoders,
      skipped: skipped,
    );
    wholeGraph(graph);
    final nodes = graph['nodes'] as Map<String, dynamic>;
    final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();
    final loader = nodes['model_loader'] as Map<String, dynamic>;
    expect(loader['type'], 'krea2_model_loader');
    expect(loader['model']['key'], 'k2');
    // A single-file model: the VAE and encoder the picture names, of those
    // that fit (not the SDXL VAE, not the 8B encoder).
    expect(loader['vae_model']['key'], 'qv');
    expect(loader['qwen3_vl_encoder_model']['key'], 'e4');
    expect(nodes['positive']['type'], 'krea2_text_encoder');
    expect(nodes['positive']['prompt'], 'a red fox in the snow');
    // CFG 1 (Turbo): no negative conditioning at all.
    expect(nodes.containsKey('negative'), isFalse);
    final denoise = nodes['denoise'] as Map<String, dynamic>;
    expect(denoise['type'], 'krea2_denoise');
    expect([denoise['steps'], denoise['cfg_scale'], denoise['seed'], denoise['width'], denoise['height']], [8, 1.0, 7, 832, 1216]);
    expect(denoise['denoising_start'], 0.0);
    expect(nodes['l2i']['type'], 'qwen_image_l2i');
    expect(nodes['l2i']['is_intermediate'], isFalse);
    // The LoRA (the Krea 2 one of that name) through the collection loader,
    // which the transformer and the text encoder both go through.
    expect(nodes['lora_0']['type'], 'lora_selector');
    expect(nodes['lora_0']['lora']['key'], 'l1');
    expect(nodes['lora_0']['weight'], 0.8);
    expect(skipped, isEmpty);
    expect(joinedIn(edges, 'lora_0', 'lora', 'lora_collect', 'item'), isTrue);
    expect(joinedIn(edges, 'lora_collect', 'collection', 'lora_loader', 'loras'), isTrue);
    expect(joinedIn(edges, 'model_loader', 'transformer', 'lora_loader', 'transformer'), isTrue);
    expect(joinedIn(edges, 'lora_loader', 'transformer', 'denoise', 'transformer'), isTrue);
    expect(joinedIn(edges, 'lora_loader', 'qwen3_vl_encoder', 'positive', 'qwen3_vl_encoder'), isTrue);
    expect(joinedIn(edges, 'positive', 'conditioning', 'positive_collect', 'item'), isTrue);
    expect(joinedIn(edges, 'positive_collect', 'collection', 'denoise', 'positive_conditioning'), isTrue);
    expect(joinedIn(edges, 'denoise', 'latents', 'l2i', 'latents'), isTrue);
    expect(joinedIn(edges, 'model_loader', 'vae', 'l2i', 'vae'), isTrue);
    expect(nodes['metadata']['generation_mode'], 'krea2_txt2img');
    expect(nodes['metadata'].containsKey('negative_prompt'), isFalse);
  });

  test('InvokeAI: a Krea 2 hires fix starts from the picture, encoded with the same VAE', () {
    final info = comfyKrea2(cfg: 4);
    final recipe = Recipe.from(info, prompt: info.prompt, negative: info.negative, width: 1664, height: 2432);
    final graph = invokeGraph(
      recipe,
      7,
      [krea2Main],
      const [],
      vaes: krea2Vaes,
      encoders: krea2Encoders,
      init: const GraphInit(image: 'up.png', strength: 0.35),
    );
    wholeGraph(graph);
    final nodes = graph['nodes'] as Map<String, dynamic>;
    final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();
    expect(nodes['i2l']['type'], 'qwen_image_i2l');
    expect(nodes['i2l']['image']['image_name'], 'up.png');
    expect(joinedIn(edges, 'model_loader', 'vae', 'i2l', 'vae'), isTrue);
    expect(joinedIn(edges, 'i2l', 'latents', 'denoise', 'latents'), isTrue);
    expect(nodes['denoise']['denoising_start'], closeTo(0.65, 1e-9));
    expect(nodes['denoise']['width'], 1664);
    expect(nodes['metadata']['generation_mode'], 'krea2_img2img');
    // CFG above 1: the negative prompt is used.
    expect(nodes['negative']['prompt'], 'blurry');
    expect(joinedIn(edges, 'negative', 'conditioning', 'denoise', 'negative_conditioning'), isTrue);
    // No LoRA on the server: left out, and the transformer comes straight
    // from the loader.
    expect(joinedIn(edges, 'model_loader', 'transformer', 'denoise', 'transformer'), isTrue);
  });

  test('InvokeAI: a Krea 2 model installed as Diffusers needs nothing more; one file without a VAE says so', () {
    final info = comfyKrea2();
    final recipe = Recipe.from(info, prompt: info.prompt, negative: info.negative, width: 832, height: 1216);
    final diffusers = m('k2', 'kreamania_variant6', 'krea-2', 'main', format: 'diffusers', variant: 'krea2_base');
    final graph = invokeGraph(recipe, 7, [diffusers], const []);
    final loader = (graph['nodes'] as Map)['model_loader'] as Map;
    expect(loader.containsKey('vae_model'), isFalse);
    expect(loader.containsKey('qwen3_vl_encoder_model'), isFalse);
    expect(
      () => invokeGraph(recipe, 7, [krea2Main], const [], encoders: krea2Encoders),
      throwsA(isA<StateError>().having((e) => e.message, 'message', allOf(contains('Qwen-Image VAE'), isNot(contains('encoder'))))),
    );
    expect(
      () => invokeGraph(recipe, 7, [krea2Main], const []),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('a Qwen-Image VAE and a Qwen3-VL encoder'))),
    );
  });

  test('InvokeAI: a Krea 2 remix asks the server for its VAEs and encoders, and sends the Krea 2 graph', () async {
    final batches = <Map<String, dynamic>>[];
    final asked = <String>[];
    Map<String, dynamic> j(InvokeModel x) =>
        {'key': x.key, 'hash': x.hash, 'name': x.name, 'base': x.base, 'type': x.type, 'path': x.path, 'format': x.format, 'variant': x.variant};
    final (server, base) = await serve((request) async {
      final path = request.uri.path;
      if (path == '/api/v2/models/') {
        final type = request.uri.queryParameters['model_type'] ?? '';
        asked.add(type);
        json(request, {
          'models': switch (type) {
            'main' => [j(krea2Main)],
            'vae' => [for (final v in krea2Vaes) j(v)],
            'qwen3_vl_encoder' => [for (final e in krea2Encoders) j(e)],
            _ => const [],
          },
        });
      } else if (path == '/api/v1/queue/default/enqueue_batch') {
        batches.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        json(request, {'item_ids': [batches.length]});
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final ticket = await sendRemix('invokeai', base, remix(comfyKrea2()));
    expect(ticket.message, contains('made from its settings'));
    expect(asked, containsAll(['main', 'lora', 'vae', 'qwen3_vl_encoder']));
    final graph = (batches.single['batch'] as Map)['graph'] as Map<String, dynamic>;
    final nodes = graph['nodes'] as Map<String, dynamic>;
    expect(nodes['model_loader']['type'], 'krea2_model_loader');
    expect(nodes['model_loader']['vae_model']['key'], 'qv');
    expect(nodes['denoise']['type'], 'krea2_denoise');
    expect(nodes['positive']['prompt'], 'a red fox');
  });

  // ------------------------------------------------ LoRAs set in the panel

  LoraChoice choice(String name, double? weight, {bool enabled = true, double? to, double? clip}) =>
      LoraChoice(LoraRef(name, weight, clip, ''), enabled: enabled, weight: to);

  test('LoRA tags in a prompt follow the switches and sliders', () {
    const prompt = 'a red fox, <lora:fur_detail:0.8>, snow <lora:xl/glow.safetensors:1:0.5>, <lora:untouched:0.3>';
    final out = retagPrompt(prompt, [
      choice('loras/fur_detail.safetensors', 0.8, enabled: false),
      choice('glow', 1, to: 1.25),
    ]);
    expect(out, 'a red fox, snow <lora:xl/glow.safetensors:1.25:0.75>, <lora:untouched:0.3>');
    // At the very start, or alone on a line, nothing is left dangling.
    expect(retagPrompt('<lora:a:1>, a fox', [choice('a', 1, enabled: false)]), 'a fox');
    expect(retagPrompt('a fox\n<lora:a:1>\nsnow', [choice('a', 1, enabled: false)]), 'a fox\n\nsnow');
    // Nothing changed, nothing touched.
    expect(retagPrompt(prompt, [choice('fur_detail', 0.8)]), prompt);
    // For Forge, a LoRA left on that the prompt never named is named; one the
    // user took out of the prompt stays out.
    expect(
      retagPrompt('a fox', [choice('xl/fur_detail.safetensors', 0.8, to: 0.6), choice('off', 1, enabled: false)], addTo: 'a fox'),
      'a fox, <lora:fur_detail:0.6>',
    );
    expect(retagPrompt('a fox', [choice('fur_detail', 0.8)], addTo: 'a fox <lora:fur_detail:0.8>'), 'a fox');
  });

  test('trigger words are found in a prompt and put at its start', () {
    expect(triggerParts('soft fur, fluffy ,'), ['soft fur', 'fluffy']);
    expect(triggerPresent('A red fox, SOFT  fur and fluffy', 'soft fur, fluffy'), isTrue);
    expect(triggerPresent('a red fox, soft fur', 'soft fur, fluffy'), isFalse);
    expect(addTrigger('a red fox', 'furry detail'), 'furry detail, a red fox');
    // Only what is missing is added.
    expect(addTrigger('soft fur, a red fox', 'soft fur, fluffy'), 'fluffy, soft fur, a red fox');
    expect(addTrigger('furry detail, a fox', 'furry detail'), 'furry detail, a fox');
    expect(addTrigger('  ', 'furry detail'), 'furry detail');
  });

  test('a LoRA choice knows how far it has moved, CLIP weight and all', () {
    final c = choice('fur', 0.8, clip: 0.5, to: 1.1);
    expect(c.offset, closeTo(0.3, 1e-9));
    expect(c.clipWeight, closeTo(0.8, 1e-9));
    expect(c.ref.weight, 1.1);
    expect(choice('plain', null).weight, 1, reason: 'no weight given means 1');
    c.reset();
    expect(c.changed, isFalse);
    final remixed = Remix(
      info: info(source: 'a1111'),
      prompt: 'a red fox <lora:fur:0.8>',
      negative: 'blurry',
      seed: 1,
      randomSeed: false,
      count: 1,
      width: 512,
      height: 512,
      loras: [choice('fur', 0.8, enabled: false), choice('glow', 1, to: 0.5)],
    );
    expect(remixed.sentPrompt, 'a red fox');
    expect(remixed.sentLoras.map((l) => (l.name, l.weight)), [('glow', 0.5)]);
  });

  test('ComfyUI: a LoRA turned off leaves the workflow, one moved is reweighted', () {
    final graph = <String, dynamic>{
      '3': {'class_type': 'KSampler', 'inputs': {'model': ['11', 0], 'seed': 1}},
      '4': {'class_type': 'CheckpointLoaderSimple', 'inputs': {'ckpt_name': 'm.safetensors'}},
      '6': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'fox', 'clip': ['11', 1]}},
      '10': {'class_type': 'LoraLoader', 'inputs': {'lora_name': 'fur.safetensors', 'strength_model': 0.8, 'strength_clip': 0.8, 'model': ['4', 0], 'clip': ['4', 1]}},
      '11': {'class_type': 'LoraLoader', 'inputs': {'lora_name': 'glow.safetensors', 'strength_model': 0.5, 'strength_clip': 0.4, 'model': ['10', 0], 'clip': ['10', 1]}},
      '20': {
        'class_type': 'Power Lora Loader (rgthree)',
        'inputs': {
          'lora_1': {'on': true, 'lora': 'sub/spark.safetensors', 'strength': 1.0},
          'lora_2': {'on': true, 'lora': 'keep.safetensors', 'strength': 0.7},
        },
      },
      '30': {
        'class_type': 'LoRA Stacker',
        'inputs': {'lora_name_1': 'stacked.safetensors', 'lora_wt_1': 0.6, 'lora_name_2': 'keep2.safetensors', 'lora_wt_2': 0.9},
      },
    };
    editComfyLoras(graph, [
      choice('fur', 0.8, enabled: false),
      choice('glow', 0.5, clip: 0.4, to: 1.2),
      choice('spark', 1, enabled: false),
      choice('stacked', 0.6, enabled: false),
    ]);
    expect(graph.containsKey('10'), isFalse);
    final glow = graph['11']['inputs'] as Map;
    expect(glow['model'], ['4', 0], reason: 'joined to what came before the one taken out');
    expect(glow['clip'], ['4', 1]);
    expect(glow['strength_model'], 1.2);
    expect(glow['strength_clip'], closeTo(1.1, 1e-9));
    expect(graph['3']['inputs']['model'], ['11', 0]);
    expect(graph['20']['inputs']['lora_1']['on'], isFalse);
    expect(graph['20']['inputs']['lora_2']['on'], isTrue);
    expect(graph['30']['inputs']['lora_wt_1'], 0);
    expect(graph['30']['inputs']['lora_wt_2'], 0.9);

    // Both loaders of a chain out: the sampler goes straight to the model.
    final chain = jsonDecode(jsonEncode(graph)) as Map<String, dynamic>;
    chain['10'] = {'class_type': 'LoraLoader', 'inputs': {'lora_name': 'fur.safetensors', 'strength_model': 0.8, 'strength_clip': 0.8, 'model': ['4', 0], 'clip': ['4', 1]}};
    (chain['11']['inputs'] as Map)['model'] = ['10', 0];
    (chain['11']['inputs'] as Map)['clip'] = ['10', 1];
    editComfyLoras(chain, [choice('glow', 0.5, enabled: false), choice('fur', 0.8, enabled: false)]);
    expect(chain['3']['inputs']['model'], ['4', 0]);
    expect(chain['6']['inputs']['clip'], ['4', 1]);
  });

  test('InvokeAI: a LoRA turned off leaves the graph and its metadata', () {
    Map<String, dynamic> edge(String from, String out, String to, String into) => {
          'source': {'node_id': from, 'field': out},
          'destination': {'node_id': to, 'field': into},
        };
    final graph = <String, dynamic>{
      'nodes': {
        'model_loader': {'id': 'model_loader', 'type': 'sdxl_model_loader'},
        'lora_a': {'id': 'lora_a', 'type': 'sdxl_lora_loader', 'lora': {'name': 'fur'}, 'weight': 0.8},
        'lora_b': {'id': 'lora_b', 'type': 'sdxl_lora_loader', 'lora': {'name': 'glow'}, 'weight': 0.5},
        'denoise': {'id': 'denoise', 'type': 'denoise_latents'},
        'metadata': {
          'id': 'metadata',
          'type': 'core_metadata',
          'loras': [
            {'model': {'name': 'fur'}, 'weight': 0.8},
            {'model': {'name': 'glow'}, 'weight': 0.5},
          ],
        },
      },
      'edges': [
        for (final f in ['unet', 'clip', 'clip2']) ...[
          edge('model_loader', f, 'lora_a', f),
          edge('lora_a', f, 'lora_b', f),
        ],
        edge('lora_b', 'unet', 'denoise', 'unet'),
      ],
    };
    editInvokeLoras(graph, [choice('fur', 0.8, enabled: false), choice('glow', 0.5, to: 1.5)]);
    final nodes = graph['nodes'] as Map<String, dynamic>;
    final edges = (graph['edges'] as List).cast<Map>();
    expect(nodes.containsKey('lora_a'), isFalse);
    expect(nodes['lora_b']['weight'], 1.5);
    for (final f in ['unet', 'clip', 'clip2']) {
      expect(
        edges.any((e) => e['source']['node_id'] == 'model_loader' && e['destination']['node_id'] == 'lora_b' && e['destination']['field'] == f),
        isTrue,
        reason: f,
      );
    }
    for (final e in edges) {
      expect(nodes.containsKey(e['source']['node_id']), isTrue, reason: '$e');
      expect(nodes.containsKey(e['destination']['node_id']), isTrue, reason: '$e');
    }
    expect(nodes['metadata']['loras'], [
      {'model': {'name': 'glow'}, 'weight': 1.5},
    ]);
  });

  test('Forge: the LoRAs as set go in the prompt it is sent', () async {
    late Map<String, dynamic> payload;
    final (server, base) = await serve((request) async {
      payload = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      json(request, {'images': <String>[], 'info': '{}'});
    });
    addTearDown(() => server.close(force: true));
    final ticket = await sendRemix(
      'forge',
      base,
      Remix(
        info: info(source: 'comfyui'),
        prompt: 'a red fox, <lora:fur:0.8>',
        negative: 'blurry',
        seed: 7,
        randomSeed: false,
        count: 1,
        width: 512,
        height: 512,
        loras: [choice('fur', 0.8, enabled: false), choice('loras/glow.safetensors', 1, to: 0.7)],
      ),
    );
    await ticket.results.toList();
    expect(payload['prompt'], 'a red fox, <lora:glow:0.7>');
  });

  test('ComfyUI: a graph built from settings leaves out a LoRA turned off', () {
    final remixed = Remix(
      info: GenInfo.fromJson({
        'source': 'a1111',
        'prompt': 'a fox',
        'model': 'm',
        'loras': [
          {'name': 'fur', 'weight': 0.8},
          {'name': 'glow', 'weight': 0.5},
        ],
      }),
      prompt: 'a fox',
      negative: '',
      seed: 1,
      randomSeed: false,
      count: 1,
      width: 512,
      height: 512,
      loras: [
        choice('fur', 0.8, enabled: false),
        choice('glow', 0.5, to: 1.5),
      ],
    );
    final recipe = Recipe.from(remixed.info, prompt: remixed.sentPrompt, negative: '', width: 512, height: 512, loras: remixed.sentLoras);
    final graph = comfyGraph(recipe, 1, const ComfyModels(['m.safetensors'], ['fur.safetensors', 'glow.safetensors']));
    final loaders = graph.values.cast<Map<String, dynamic>>().where((n) => n['class_type'] == 'LoraLoader').toList();
    expect(loaders, hasLength(1));
    expect(loaders.single['inputs']['lora_name'], 'glow.safetensors');
    expect(loaders.single['inputs']['strength_model'], 1.5);
  });
  // ------------------------------------------------ image to image

  /// A picture to start from: the bytes are only passed along.
  ImageInput start({bool masked = false}) => ImageInput(
        image: tinyPng(3),
        strength: 0.55,
        mask: masked ? tinyPng(4) : null,
        keepMask: masked ? tinyPng(6) : null,
      );

  Remix fromPicture(GenInfo info, {bool masked = false}) => Remix(
        info: info,
        prompt: 'a red fox',
        negative: 'blurry',
        seed: 7,
        randomSeed: false,
        count: 1,
        width: 512,
        height: 512,
        init: start(masked: masked),
      );

  test('ComfyUI: a workflow starts from the picture instead of an empty latent', () {
    final graph = <String, dynamic>{
      '4': {'class_type': 'CheckpointLoaderSimple', 'inputs': {'ckpt_name': 'x.safetensors'}},
      '5': {'class_type': 'EmptyLatentImage', 'inputs': {'width': 512, 'height': 512, 'batch_size': 1}},
      '3': {
        'class_type': 'KSampler',
        'inputs': {'seed': 1, 'denoise': 1.0, 'model': ['4', 0], 'latent_image': ['5', 0]},
      },
      '8': {'class_type': 'VAEDecode', 'inputs': {'samples': ['3', 0], 'vae': ['4', 2]}},
      '9': {'class_type': 'SaveImage', 'inputs': {'images': ['8', 0]}},
    };
    comfyImageToImage(graph, image: 'in.png', mask: 'mask.png', strength: 0.4);
    expect(graph.containsKey('5'), isFalse, reason: 'the empty latent is gone');
    Map<String, dynamic> of(String type) =>
        graph.values.cast<Map<String, dynamic>>().singleWhere((n) => n['class_type'] == type);
    String idOf(String type) => graph.entries.singleWhere((e) => (e.value as Map)['class_type'] == type).key;
    expect(of('LoadImage')['inputs']['image'], 'in.png');
    expect(of('VAEEncode')['inputs']['vae'], ['4', 2], reason: 'encoded with the VAE it decodes with');
    expect(of('VAEEncode')['inputs']['pixels'], [idOf('LoadImage'), 0]);
    expect(of('LoadImageMask')['inputs'], {'image': 'mask.png', 'channel': 'red'});
    expect(of('SetLatentNoiseMask')['inputs']['samples'], [idOf('VAEEncode'), 0]);
    expect(of('KSampler')['inputs']['latent_image'], [idOf('SetLatentNoiseMask'), 0]);
    expect(of('KSampler')['inputs']['denoise'], 0.4);
    // New nodes do not take ids already there.
    expect(graph.keys.toSet(), hasLength(graph.length));
    expect(graph.keys.where((k) => int.parse(k) > 9), hasLength(4));
  });

  test('ComfyUI: an advanced sampler starts part way through its steps', () {
    final graph = <String, dynamic>{
      '1': {'class_type': 'EmptySD3LatentImage', 'inputs': {'width': 1024, 'height': 1024}},
      '2': {
        'class_type': 'KSamplerAdvanced',
        'inputs': {'steps': 30, 'start_at_step': 0, 'add_noise': 'enable', 'latent_image': ['1', 0]},
      },
      '3': {'class_type': 'VAEDecodeTiled', 'inputs': {'samples': ['2', 0], 'vae': ['7', 0]}},
    };
    comfyImageToImage(graph, image: 'in.png', strength: 0.6);
    final sampler = graph['2'] as Map<String, dynamic>;
    expect(sampler['inputs']['start_at_step'], 12);
    expect(graph.values.any((n) => (n as Map)['class_type'] == 'SetLatentNoiseMask'), isFalse,
        reason: 'no mask, no masking');
  });

  test('ComfyUI: a workflow with no empty latent is said plainly', () {
    final graph = <String, dynamic>{
      '1': {'class_type': 'LoadImage', 'inputs': {'image': 'x.png'}},
    };
    expect(
      () => comfyImageToImage(graph, image: 'in.png', strength: 0.5),
      throwsA(isA<BackendException>().having((e) => e.message, 'message', contains('empty picture'))),
    );
  });

  test('ComfyUI: image to image uploads the picture and mask, then queues', () async {
    final uploads = <String>[];
    final queued = <Map<String, dynamic>>[];
    final (server, base) = await serve((request) async {
      final path = request.uri.path;
      if (path == '/upload/image') {
        expect(request.headers.contentType?.mimeType, 'multipart/form-data');
        final body = latin1.decode(await request.fold<List<int>>([], (a, b) => a..addAll(b)));
        final name = RegExp(r'filename="([^"]+)"').firstMatch(body)!.group(1)!;
        expect(body, contains('name="type"'));
        uploads.add(name);
        json(request, {'name': name, 'subfolder': 'up', 'type': 'input'});
      } else if (path == '/prompt') {
        queued.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        json(request, {'prompt_id': 'p1'});
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final graph = jsonEncode({
      '4': {'class_type': 'CheckpointLoaderSimple', 'inputs': {'ckpt_name': 'x.safetensors'}},
      '5': {'class_type': 'EmptyLatentImage', 'inputs': {'width': 512, 'height': 512, 'batch_size': 1}},
      '3': {'class_type': 'KSampler', 'inputs': {'seed': 1, 'denoise': 1.0, 'latent_image': ['5', 0]}},
      '6': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'a red fox'}},
      '8': {'class_type': 'VAEDecode', 'inputs': {'samples': ['3', 0], 'vae': ['4', 2]}},
    });
    final ticket = await sendRemix(
      'comfyui',
      base,
      fromPicture(info(source: 'comfyui', raw: [['prompt', graph]]), masked: true),
    );
    expect(ticket.message, 'Queued 1 picture in ComfyUI, the painted area redrawn at strength 0.55');
    expect(uploads, hasLength(2));
    expect(uploads.first, endsWith('_image.png'));
    expect(uploads.last, endsWith('_mask.png'));
    final sent = queued.single['prompt'] as Map<String, dynamic>;
    final load = sent.values.cast<Map<String, dynamic>>().singleWhere((n) => n['class_type'] == 'LoadImage');
    expect(load['inputs']['image'], 'up/${uploads.first}', reason: 'loaded from the folder it went to');
    final mask = sent.values.cast<Map<String, dynamic>>().singleWhere((n) => n['class_type'] == 'LoadImageMask');
    expect(mask['inputs']['image'], 'up/${uploads.last}');
    expect((sent['3'] as Map)['inputs']['denoise'], 0.55);
  });

  test('InvokeAI: a picture from elsewhere gets a built graph that starts from it', () async {
    final batches = <Map<String, dynamic>>[];
    var uploaded = 0;
    Map<String, dynamic> model(String key, String name, String base, String type) =>
        {'key': key, 'hash': 'blake3:$key', 'name': name, 'base': base, 'type': type, 'path': '/models/$name.safetensors'};
    final (server, base) = await serve((request) async {
      final path = request.uri.path;
      if (path == '/api/v1/images/upload') {
        expect(request.uri.queryParameters['is_intermediate'], 'true');
        await request.drain<void>();
        json(request, {'image_name': 'up${++uploaded}.png'});
      } else if (path == '/api/v2/models/') {
        final type = request.uri.queryParameters['model_type'];
        json(request, {
          'models': type == 'main' ? [model('m2', 'juggernautXL_v9', 'sdxl', 'main')] : [model('l1', 'fur_detail', 'sdxl', 'lora')],
        });
      } else if (path == '/api/v1/queue/default/enqueue_batch') {
        batches.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        json(request, {'item_ids': [1]});
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    // A picture with settings but no InvokeAI graph of its own.
    final own = GenInfo.fromJson({
      'source': 'invokeai',
      'prompt': 'a red fox',
      'negative': 'blurry',
      'seed': '7',
      'model': 'juggernautXL_v9',
      'params': [
        ['Steps', '30'],
      ],
      'width': 512,
      'height': 512,
    });
    final ticket = await sendRemix('invokeai', base, fromPicture(own, masked: true));
    expect(ticket.message, contains('the painted area redrawn at strength 0.55'));
    expect(uploaded, 2);
    final graph = (batches.single['batch'] as Map)['graph'] as Map<String, dynamic>;
    final nodes = graph['nodes'] as Map<String, dynamic>;
    final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();
    expect(graph['id'], 'generativeview_img2img');
    expect(nodes['i2l']['image'], {'image_name': 'up1.png'});
    expect(nodes['denoise_mask']['type'], 'create_denoise_mask');
    expect(nodes['denoise_mask']['mask'], {'image_name': 'up2.png'}, reason: 'the kept-white mask, as InvokeAI reads it');
    expect(nodes['denoise']['denoising_start'], closeTo(0.45, 1e-9));
    expect(nodes['metadata']['generation_mode'], 'sdxl_inpaint');
    expect(nodes['metadata']['strength'], 0.55);
    bool joined(String from, String out, String to, String into) => edges.any((e) =>
        e['source']['node_id'] == from && e['source']['field'] == out && e['destination']['node_id'] == to && e['destination']['field'] == into);
    expect(joined('i2l', 'latents', 'denoise', 'latents'), isTrue);
    expect(joined('model_loader', 'vae', 'i2l', 'vae'), isTrue);
    expect(joined('denoise_mask', 'denoise_mask', 'denoise', 'denoise_mask'), isTrue);
    for (final e in edges) {
      expect(nodes.containsKey(e['source']['node_id']), isTrue, reason: '$e');
      expect(nodes.containsKey(e['destination']['node_id']), isTrue, reason: '$e');
    }
  });

  /// A Krea 2 graph as InvokeAI 7 saves it with a picture, cut down to
  /// what matters here; read from JSON, as a picture's graph always is.
  Map<String, dynamic> krea2Graph() => jsonDecode(jsonEncode({
        'id': 'krea2_graph',
        'nodes': {
          'loader': {'id': 'loader', 'type': 'krea2_model_loader', 'model': {'key': 'k2'}, 'vae_model': {'key': 'qvae'}},
          'pos': {'id': 'pos', 'type': 'krea2_text_encoder', 'prompt': 'a red fox'},
          'denoise': {'id': 'denoise', 'type': 'krea2_denoise', 'steps': 8, 'width': 512, 'height': 512, 'seed': 1, 'denoising_start': 0.0, 'denoising_end': 1.0},
          'l2i': {'id': 'l2i', 'type': 'qwen_image_l2i', 'is_intermediate': false},
        },
        'edges': [
          {'source': {'node_id': 'loader', 'field': 'transformer'}, 'destination': {'node_id': 'denoise', 'field': 'transformer'}},
          {'source': {'node_id': 'pos', 'field': 'conditioning'}, 'destination': {'node_id': 'denoise', 'field': 'positive_conditioning'}},
          {'source': {'node_id': 'loader', 'field': 'vae'}, 'destination': {'node_id': 'l2i', 'field': 'vae'}},
          {'source': {'node_id': 'denoise', 'field': 'latents'}, 'destination': {'node_id': 'l2i', 'field': 'latents'}},
        ],
      })) as Map<String, dynamic>;

  bool joins(List<dynamic> edges, String from, String out, String to, String into) => edges.any((e) =>
      e['source']['node_id'] == from && e['source']['field'] == out && e['destination']['node_id'] == to && e['destination']['field'] == into);

  test('InvokeAI: a Krea 2 graph starts from the picture, encoded by its own VAE', () {
    final graph = krea2Graph();
    invokeImageToImage(graph, image: 'up1.png', keepMask: 'up2.png', strength: 0.4);
    final nodes = graph['nodes'] as Map<String, dynamic>;
    final edges = graph['edges'] as List;
    expect(nodes['generativeview_i2l']['type'], 'qwen_image_i2l', reason: 'the encoder that matches its decoder');
    expect(nodes['generativeview_i2l']['image'], {'image_name': 'up1.png'});
    expect(joins(edges, 'loader', 'vae', 'generativeview_i2l', 'vae'), isTrue, reason: 'the VAE the picture was decoded with');
    expect(joins(edges, 'generativeview_i2l', 'latents', 'denoise', 'latents'), isTrue);
    expect(nodes['generativeview_mask']['type'], 'create_denoise_mask');
    expect(nodes['generativeview_mask']['mask'], {'image_name': 'up2.png'});
    expect(joins(edges, 'generativeview_mask', 'denoise_mask', 'denoise', 'denoise_mask'), isTrue);
    expect(nodes['denoise']['denoising_start'], closeTo(0.6, 1e-9));
    expect((nodes['loader'] as Map)['vae_model'], {'key': 'qvae'}, reason: 'its own loaders are left as they were');
  });

  test('InvokeAI: other families get their matching encoder', () {
    for (final (decoder, encoder) in [('l2i', 'i2l'), ('flux_vae_decode', 'flux_vae_encode'), ('z_image_l2i', 'z_image_i2l')]) {
      final graph = krea2Graph();
      (graph['nodes'] as Map)['l2i']['type'] = decoder;
      (graph['nodes'] as Map)['denoise']['type'] = 'denoise_latents';
      invokeImageToImage(graph, image: 'in.png', strength: 0.5);
      expect((graph['nodes'] as Map)['generativeview_i2l']['type'], encoder);
      expect((graph['nodes'] as Map).containsKey('generativeview_mask'), isFalse, reason: 'no mask, none made');
    }
  });

  test('InvokeAI: image to image of an InvokeAI picture uses its own graph', () async {
    final batches = <Map<String, dynamic>>[];
    var uploaded = 0;
    final (server, base) = await serve((request) async {
      final path = request.uri.path;
      if (path == '/api/v1/images/upload') {
        await request.drain<void>();
        json(request, {'image_name': 'up${++uploaded}.png'});
      } else if (path == '/api/v1/queue/default/enqueue_batch') {
        batches.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        json(request, {'item_ids': [1]});
      } else {
        // No model listing: its own graph needs none.
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final ticket = await sendRemix(
      'invokeai',
      base,
      fromPicture(info(source: 'invokeai', raw: [['invokeai_graph', jsonEncode(krea2Graph())]]), masked: true),
    );
    expect(ticket.message, 'Queued 1 picture in InvokeAI, the painted area redrawn at strength 0.55');
    final graph = (batches.single['batch'] as Map)['graph'] as Map<String, dynamic>;
    final nodes = graph['nodes'] as Map<String, dynamic>;
    expect(nodes['loader']['type'], 'krea2_model_loader');
    expect(nodes['generativeview_i2l']['image'], {'image_name': 'up1.png'});
    expect(nodes['generativeview_mask']['mask'], {'image_name': 'up2.png'});
    expect(nodes['denoise']['seed'], 7, reason: 'the seed asked for');
    expect(nodes['denoise']['denoising_start'], closeTo(0.45, 1e-9));
  });

  test('InvokeAI: each run gets its own seed, though the graph keeps it in a node', () async {
    final batches = <Map<String, dynamic>>[];
    final (server, base) = await serve((request) async {
      if (request.uri.path == '/api/v1/queue/default/enqueue_batch') {
        batches.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        json(request, {'item_ids': [batches.length]});
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    // As InvokeAI 7 saves it: the seed is an integer node wired into the
    // denoise step and the metadata, and the denoise step's own field is
    // left at whatever it was.
    final graph = jsonEncode({
      'nodes': {
        'seed': {'id': 'seed', 'type': 'integer', 'value': 7},
        'pos': {'id': 'pos', 'type': 'krea2_text_encoder', 'prompt': 'a red fox'},
        'denoise': {'id': 'denoise', 'type': 'krea2_denoise', 'seed': 0},
        'rand': {'id': 'rand', 'type': 'rand_int'},
        'variance': {'id': 'variance', 'type': 'krea2_seed_variance'},
        'meta': {'id': 'meta', 'type': 'core_metadata'},
      },
      'edges': [
        {'source': {'node_id': 'seed', 'field': 'value'}, 'destination': {'node_id': 'denoise', 'field': 'seed'}},
        {'source': {'node_id': 'seed', 'field': 'value'}, 'destination': {'node_id': 'meta', 'field': 'seed'}},
        {'source': {'node_id': 'rand', 'field': 'value'}, 'destination': {'node_id': 'variance', 'field': 'seed'}},
      ],
    });
    final ticket = await sendRemix(
      'invokeai',
      base,
      Remix(
        info: info(source: 'invokeai', raw: [['invokeai_graph', graph]]),
        prompt: 'a red fox',
        negative: 'blurry',
        seed: 0,
        randomSeed: true,
        count: 3,
        width: 512,
        height: 512,
      ),
    );
    expect(ticket.count, 3);
    final sent = [
      for (final b in batches) ((b['batch'] as Map)['graph'] as Map)['nodes'] as Map,
    ];
    final seeds = [for (final n in sent) n['seed']['value']];
    expect(seeds.toSet(), hasLength(3), reason: 'a new seed for each run, in the node that is wired in');
    for (var i = 0; i < 3; i++) {
      expect(sent[i]['variance']['seed'], seeds[i], reason: 'a seed from elsewhere is replaced too');
      final edges = ((batches[i]['batch'] as Map)['graph'] as Map)['edges'] as List;
      expect(edges.any((e) => e['source']['node_id'] == 'rand'), isFalse);
    }
  });

  // ------------------------------------------------ steps and CFG

  Remix tuned(GenInfo info, {int? steps, double? cfg}) => Remix(
        info: info,
        prompt: 'a red fox',
        negative: 'blurry',
        seed: 7,
        randomSeed: false,
        count: 1,
        width: 512,
        height: 512,
        steps: steps,
        cfg: cfg,
      );

  test('ComfyUI: steps and CFG set in the sampler, a second pass left alone', () async {
    final queued = <Map<String, dynamic>>[];
    final (server, base) = await serve((request) async {
      if (request.uri.path == '/prompt') {
        queued.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        json(request, {'prompt_id': 'p1'});
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final graph = jsonEncode({
      '3': {'class_type': 'KSampler', 'inputs': {'seed': 1, 'steps': 20, 'cfg': 7, 'denoise': 1}},
      '4': {'class_type': 'KSampler', 'inputs': {'seed': 1, 'steps': 12, 'cfg': 4.5, 'denoise': 0.4}},
      '6': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'a red fox'}},
    });
    final picture = info(source: 'comfyui', raw: [['prompt', graph]]);
    await sendRemix('comfyui', base, tuned(picture, steps: 35, cfg: 3.5));
    final sent = queued.single['prompt'] as Map;
    expect(sent['3']['inputs']['steps'], 35);
    expect(sent['3']['inputs']['cfg'], 3.5);
    expect(sent['4']['inputs']['steps'], 12, reason: 'not the picture\'s own steps');
    expect(sent['4']['inputs']['cfg'], 4.5);

    // Left unset, both are sent as the picture had them.
    queued.clear();
    await sendRemix('comfyui', base, tuned(picture));
    final same = queued.single['prompt'] as Map;
    expect(same['3']['inputs']['steps'], 20);
    expect(same['3']['inputs']['cfg'], 7);
  });

  test('InvokeAI: steps and CFG set, wired in from a node or not, metadata too', () async {
    late Map<String, dynamic> batch;
    final (server, base) = await serve((request) async {
      if (request.uri.path == '/api/v1/queue/default/enqueue_batch') {
        batch = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
        json(request, {'item_ids': [1]});
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final graph = jsonEncode({
      'nodes': {
        'steps': {'id': 'steps', 'type': 'integer', 'value': 20},
        'pos': {'id': 'pos', 'type': 'krea2_text_encoder', 'prompt': 'a red fox'},
        'denoise': {'id': 'denoise', 'type': 'krea2_denoise', 'seed': 0, 'steps': 20, 'cfg_scale': 7},
        'meta': {'id': 'meta', 'type': 'core_metadata', 'steps': 20, 'cfg_scale': 7},
      },
      'edges': [
        {'source': {'node_id': 'steps', 'field': 'value'}, 'destination': {'node_id': 'denoise', 'field': 'steps'}},
      ],
    });
    await sendRemix('invokeai', base, tuned(info(source: 'invokeai', raw: [['invokeai_graph', graph]]), steps: 40, cfg: 4));
    final nodes = (batch['batch'] as Map)['graph']['nodes'] as Map;
    expect(nodes['steps']['value'], 40, reason: 'the node wired in is what counts');
    expect(nodes['denoise']['steps'], 40);
    expect(nodes['denoise']['cfg_scale'], 4);
    expect(nodes['meta']['steps'], 40, reason: 'so the picture records what it was made with');
    expect(nodes['meta']['cfg_scale'], 4);
  });

  test('Forge: steps and CFG as set, else as the picture had them', () async {
    final payloads = <Map<String, dynamic>>[];
    final (server, base) = await serve((request) async {
      payloads.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
      json(request, {'images': <String>[]});
    });
    addTearDown(() => server.close(force: true));
    await (await sendRemix('forge', base, tuned(info(source: 'a1111'), steps: 8, cfg: 2.5))).results.drain<void>();
    await (await sendRemix('forge', base, tuned(info(source: 'a1111')))).results.drain<void>();
    expect(payloads[0]['steps'], 8);
    expect(payloads[0]['cfg_scale'], 2.5);
    expect(payloads[1]['steps'], 20);
    expect(payloads[1]['cfg_scale'], 7);
  });

  test('a built graph takes the steps and CFG as set', () {
    final recipe = Recipe.from(forgePicture(), prompt: 'a red fox', negative: '', width: 832, height: 1216, steps: 12, cfg: 3);
    expect(recipe.steps, 12);
    expect(recipe.cfg, 3);
    final own = Recipe.from(forgePicture(), prompt: 'a red fox', negative: '', width: 832, height: 1216);
    expect(own.steps, 28);
    expect(own.cfg, 6.5);
  });

  // ------------------------------------------------ picked up again

  test('ComfyUI: a remix sent earlier is picked up again by its job', () async {
    final (server, base) = await serve((request) async {
      final path = request.uri.path;
      if (path == '/history/p7') {
        json(request, {
          'p7': {
            'status': {'status_str': 'success'},
            'outputs': {
              '9': {
                'images': [
                  {'filename': 'out.png', 'subfolder': '', 'type': 'output'},
                ],
              },
            },
          },
        });
      } else if (path == '/view') {
        request.response.add(tinyPng(7));
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final ticket = resumeRemix('comfyui', base, ['p7']);
    expect(ticket.jobs, ['p7']);
    final finished = ticket.finished.toList();
    final images = await ticket.results.toList();
    expect(images.single.bytes[28], 7);
    expect(await finished, ['p7'], reason: 'so it is not fetched again');
  });

  test('ComfyUI: a sent remix it no longer has is given up on, not waited for', () async {
    final (server, base) = await serve((request) async {
      final path = request.uri.path;
      if (path.startsWith('/history/')) {
        json(request, {});
      } else if (path == '/queue') {
        json(request, {'queue_running': [], 'queue_pending': []});
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final ticket = resumeRemix('comfyui', base, ['lost']);
    final finished = ticket.finished.toList();
    final errors = <Object>[];
    await ticket.results.handleError(errors.add).toList();
    expect(errors.single.toString(), contains('no longer has'));
    expect(await finished, ['lost']);
  });

  test('InvokeAI: a queue item it no longer has is given up on', () async {
    final (server, base) = await serve((request) async {
      request.response.statusCode = 404;
      request.response.write('{"detail": "Queue item not found"}');
    });
    addTearDown(() => server.close(force: true));
    final ticket = resumeRemix('invokeai', base, ['12']);
    final finished = ticket.finished.toList();
    final errors = <Object>[];
    await ticket.results.handleError(errors.add).toList();
    expect(errors.single.toString(), contains('no longer has'));
    expect(await finished, ['12']);
  });

  test('a ticket says which jobs to pick up again; Forge has none to give', () async {
    final (server, base) = await serve((request) async {
      final path = request.uri.path;
      if (path == '/prompt') {
        await request.drain<void>();
        json(request, {'prompt_id': 'abc'});
      } else if (path == '/sdapi/v1/txt2img') {
        await request.drain<void>();
        json(request, {'images': <String>[]});
      } else {
        request.response.statusCode = 404;
      }
    });
    addTearDown(() => server.close(force: true));
    final graph = jsonEncode({
      '6': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'a red fox'}},
    });
    final comfy = await sendRemix('comfyui', base, remix(info(source: 'comfyui', raw: [['prompt', graph]])));
    expect(comfy.kind, 'comfyui');
    expect(comfy.base, base);
    expect(comfy.jobs, ['abc']);
    final forge = await sendRemix('forge', base, remix(info(source: 'a1111')));
    expect(forge.jobs, isEmpty);
    await forge.results.toList();
    expect(() => resumeRemix('forge', base, ['x']), throwsA(isA<BackendException>()));
  });

  test('Forge: image to image goes to img2img with the picture and mask', () async {
    late String path;
    late Map<String, dynamic> payload;
    final (server, base) = await serve((request) async {
      path = request.uri.path;
      payload = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      json(request, {
        'images': [base64Encode(tinyPng(1))],
        'info': jsonEncode({'infotexts': ['a red fox\nSeed: 7']}),
      });
    });
    addTearDown(() => server.close(force: true));
    final ticket = await sendRemix('forge', base, fromPicture(info(source: 'a1111'), masked: true));
    await ticket.results.toList();
    expect(path, '/sdapi/v1/img2img');
    expect(base64Decode(payload['init_images'][0] as String)[28], 3);
    expect(base64Decode(payload['mask'] as String)[28], 4, reason: 'white where redrawn, as Forge reads it');
    expect(payload['denoising_strength'], 0.55);
    expect(payload['inpainting_mask_invert'], 0);
    expect(payload['inpainting_fill'], 1, reason: 'the masked part starts from the picture, not noise');

    // Without a mask, none is sent.
    final plain = await sendRemix('forge', base, fromPicture(info(source: 'a1111')));
    await plain.results.toList();
    expect(payload.containsKey('mask'), isFalse);
    expect(payload['init_images'], hasLength(1));
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
