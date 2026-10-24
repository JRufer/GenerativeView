// Every remix feature, on every server: one table of what a remix can ask
// for, run against ComfyUI, InvokeAI and Forge alike, each played by a small
// server on this machine that keeps what it is sent. The same checks read
// what each one was sent, so a feature that works for one server and not
// another fails here, and a server left out of a new feature shows up as a
// missing row rather than going unnoticed.
//
// Each feature is tried on three kinds of picture: one the server made
// itself (sent back with its own graph changed in place), an SDXL picture
// from another program, and a Krea 2 picture from another program (a graph
// built from its settings, with the model found by family when the server
// has it under another name).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/backends.dart';
import 'package:generativeview/src/core/lora_edits.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/recipe_graphs.dart';

// ---------------------------------------------------------------- servers

/// The servers, by the key their address is saved under.
const List<String> servers = ['comfyui', 'invokeai', 'forge'];

/// What ComfyUI has installed.
const comfyCheckpoints = ['SDXL/juggernautXL_v9.safetensors'];
const comfyUnets = ['krea2_turbo_fp8_scaled.safetensors'];
const comfyEncoders = ['qwen3vl_4b_fp8_scaled.safetensors', 'clip_l.safetensors'];
const comfyVaes = ['qwen_image_vae.safetensors', 'sdxl_vae.safetensors'];
const comfyLoras = ['xl/fur_detail.safetensors', 'krea2/krea2_style.safetensors'];

/// What InvokeAI has installed: the same models, under InvokeAI's names.
final invokeMains = [
  model('xl', 'juggernautXL_v9', 'sdxl', 'main'),
  model('k2', 'Krea-2-Turbo', 'krea-2', 'main', format: 'diffusers', variant: 'krea2_turbo'),
];
final invokeLoras = [
  model('l1', 'fur_detail', 'sdxl', 'lora'),
  model('l2', 'krea2_style', 'krea-2', 'lora'),
];

InvokeModel model(String key, String name, String base, String type, {String format = 'checkpoint', String variant = ''}) =>
    InvokeModel(key: key, hash: 'blake3:$key', name: name, base: base, type: type, path: '/models/$name.safetensors', format: format, variant: variant);

/// A ComfyUI `/object_info/<node>` reply listing [choices] for [field].
Map<String, dynamic> objectInfo(String node, Map<String, List<String>> fields) => {
      node: {
        'input': {
          'required': {
            for (final MapEntry(:key, :value) in fields.entries) key: [value],
          },
        },
      },
    };

/// A stand-in for one server: answers as the real one does, and keeps what
/// it is asked to make.
class FakeServer {
  FakeServer._(this.kind, this._server, this.base);
  final String kind;
  final HttpServer _server;
  final String base;

  /// What was queued, in each server's own shape: ComfyUI's prompt graph,
  /// InvokeAI's graph, Forge's payload.
  final List<Map<String, dynamic>> sent = [];

  /// Pictures handed over to start from (and masks).
  int uploads = 0;

  Future<void> close() => _server.close(force: true);

  static Future<FakeServer> start(String kind) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeServer._(kind, server, 'http://127.0.0.1:${server.port}');
    server.listen((request) async {
      try {
        await fake._handle(request);
      } catch (e) {
        request.response.statusCode = 500;
        request.response.write('$e');
      }
      await request.response.close();
    });
    return fake;
  }

  void _json(HttpRequest request, Object body) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    switch (kind) {
      case 'comfyui':
        switch (path) {
          case '/object_info/CheckpointLoaderSimple':
            _json(request, objectInfo('CheckpointLoaderSimple', {'ckpt_name': comfyCheckpoints}));
          case '/object_info/LoraLoader':
            _json(request, objectInfo('LoraLoader', {'lora_name': comfyLoras}));
          case '/object_info/UNETLoader':
            _json(request, objectInfo('UNETLoader', {'unet_name': comfyUnets}));
          case '/object_info/CLIPLoader':
            _json(request, objectInfo('CLIPLoader', {
              'clip_name': comfyEncoders,
              'type': ['stable_diffusion', 'qwen_image', 'krea2'],
            }));
          case '/object_info/VAELoader':
            _json(request, objectInfo('VAELoader', {'vae_name': comfyVaes}));
          case '/upload/image':
            await request.drain<void>();
            _json(request, {'name': 'up${++uploads}.png', 'subfolder': '', 'type': 'input'});
          case '/prompt':
            sent.add(((await _body(request))['prompt'] as Map).cast<String, dynamic>());
            _json(request, {'prompt_id': 'p${sent.length}'});
          default:
            // UnetLoaderGGUF without ComfyUI-GGUF: an empty listing.
            if (path.startsWith('/object_info/')) {
              _json(request, {});
            } else {
              request.response.statusCode = 404;
            }
        }
      case 'invokeai':
        switch (path) {
          case '/api/v2/models/':
            final type = request.uri.queryParameters['model_type'];
            final list = switch (type) {
              'main' => invokeMains,
              'lora' => invokeLoras,
              _ => const <InvokeModel>[],
            };
            _json(request, {
              'models': [
                for (final m in list)
                  {...m.identifier, 'path': m.path, 'format': m.format, 'variant': m.variant},
              ],
            });
          case '/api/v1/images/upload':
            await request.drain<void>();
            _json(request, {'image_name': 'up${++uploads}.png'});
          case '/api/v1/queue/default/enqueue_batch':
            final batch = (await _body(request))['batch'] as Map;
            sent.add((batch['graph'] as Map).cast<String, dynamic>());
            _json(request, {'item_ids': [sent.length]});
          default:
            request.response.statusCode = 404;
        }
      case 'forge':
        if (path == '/sdapi/v1/txt2img' || path == '/sdapi/v1/img2img') {
          final payload = await _body(request);
          sent.add({...payload, '_endpoint': path.split('/').last});
          if (payload['init_images'] != null) uploads++;
          if (payload['mask'] != null) uploads++;
          _json(request, {'images': [], 'info': '{}'});
        } else {
          request.response.statusCode = 404;
        }
    }
  }
}

// ---------------------------------------------------------------- what was sent

/// What one queued job asks the server for, read from any server's shape.
class Sent {
  Sent({
    required this.prompts,
    required this.model,
    this.seed,
    this.runs = 1,
    this.steps,
    this.cfg,
    this.width,
    this.height,
    this.strength = 1,
    this.masked = false,
    this.loras = const {},
  });

  /// Every prompt text in it (positive and negative).
  final Set<String> prompts;

  /// The main model, by [modelKey].
  final String model;
  final int? seed;

  /// How many pictures this one job makes (Forge makes them all in one).
  final int runs;
  final int? steps;
  final double? cfg;

  /// The size it is made at; null where the picture it starts from sets it.
  final int? width;
  final int? height;

  /// How much is redrawn: 1 from noise, less from a picture.
  final double strength;
  final bool masked;

  /// LoRA (by [modelKey]) to weight, of those loaded.
  final Map<String, double> loras;

  @override
  String toString() => 'Sent(model: $model, seed: $seed, runs: $runs, steps: $steps, cfg: $cfg, '
      'size: ${width}x$height, strength: $strength, masked: $masked, loras: $loras, prompts: $prompts)';
}

/// What [kind] was sent, in [payload], as a [Sent].
Sent read(String kind, Map<String, dynamic> payload) => switch (kind) {
      'comfyui' => readComfy(payload),
      'invokeai' => readInvoke(payload),
      _ => readForge(payload),
    };

Sent readComfy(Map<String, dynamic> graph) {
  final nodes = graph.values.whereType<Map<String, dynamic>>().toList();
  Map<String, dynamic> inputs(Map<String, dynamic> n) => (n['inputs'] as Map).cast<String, dynamic>();
  Iterable<Map<String, dynamic>> of(Set<String> types) => nodes.where((n) => types.contains(n['class_type'])).map(inputs);
  final sampler = of({'KSampler', 'KSamplerAdvanced'}).single;
  final empty = of({'EmptyLatentImage', 'EmptySD3LatentImage'}).firstOrNull;
  final loader = of({'CheckpointLoaderSimple', 'UNETLoader', 'UnetLoaderGGUF'}).single;
  final steps = (sampler['steps'] as num?)?.toInt();
  final start = sampler['start_at_step'];
  return Sent(
    prompts: {for (final t in of({'CLIPTextEncode'})) '${t['text']}'},
    model: modelKey('${loader['ckpt_name'] ?? loader['unet_name']}'),
    seed: ((sampler['seed'] ?? sampler['noise_seed']) as num?)?.toInt(),
    steps: steps,
    cfg: (sampler['cfg'] as num?)?.toDouble(),
    width: (empty?['width'] as num?)?.toInt(),
    height: (empty?['height'] as num?)?.toInt(),
    strength: start is num && steps != null && steps > 0
        ? 1 - start / steps
        : (sampler['denoise'] as num? ?? 1).toDouble(),
    masked: of({'SetLatentNoiseMask'}).isNotEmpty,
    loras: {
      for (final l in of({'LoraLoader', 'LoraLoaderModelOnly'}))
        modelKey('${l['lora_name']}'): (l['strength_model'] as num).toDouble(),
    },
  );
}

Sent readInvoke(Map<String, dynamic> graph) {
  final nodes = (graph['nodes'] as Map).values.whereType<Map>().map((n) => n.cast<String, dynamic>()).toList();
  String type(Map<String, dynamic> n) => '${n['type'] ?? ''}';
  final denoise = nodes.singleWhere((n) => type(n) == 'denoise_latents' || type(n).endsWith('_denoise'));
  final noise = nodes.where((n) => type(n) == 'noise').firstOrNull;
  // A seed kept in a node of its own, wired into the denoise step, is
  // what counts; the field's own value is the fallback.
  final edges = (graph['edges'] as List).whereType<Map>().toList();
  int? wired(Map<String, dynamic> into, String field) {
    for (final e in edges) {
      final d = e['destination'] as Map;
      if (d['node_id'] == into['id'] && d['field'] == field) {
        final from = nodes.where((n) => n['id'] == (e['source'] as Map)['node_id']).firstOrNull;
        if (from != null && from['value'] is num) return (from['value'] as num).toInt();
      }
    }
    return null;
  }

  final seedNode = denoise['seed'] is num || wired(denoise, 'seed') != null ? denoise : noise;
  final loader = nodes.firstWhere((n) => type(n).endsWith('model_loader'));
  final start = (denoise['denoising_start'] as num? ?? 0).toDouble();
  return Sent(
    prompts: {
      for (final n in nodes)
        if (n['prompt'] is String && type(n) != 'core_metadata') n['prompt'] as String,
    },
    model: modelKey('${(loader['model'] as Map)['name']}'),
    seed: seedNode == null ? null : wired(seedNode, 'seed') ?? (seedNode['seed'] as num?)?.toInt(),
    steps: wired(denoise, 'steps') ?? (denoise['steps'] as num?)?.toInt(),
    cfg: (denoise['cfg_scale'] as num?)?.toDouble(),
    width: ((denoise['width'] ?? noise?['width']) as num?)?.toInt(),
    height: ((denoise['height'] ?? noise?['height']) as num?)?.toInt(),
    strength: 1 - start,
    masked: nodes.any((n) => n['mask'] is Map),
    loras: {
      for (final n in nodes)
        if (n['lora'] is Map && n['weight'] is num) modelKey('${(n['lora'] as Map)['name']}'): (n['weight'] as num).toDouble(),
    },
  );
}

Sent readForge(Map<String, dynamic> payload) {
  final prompt = '${payload['prompt']}';
  final tag = RegExp(r'<lora:([^:>]+):([-\d.]+)>');
  return Sent(
    prompts: {
      prompt.replaceAll(tag, '').replaceAll(RegExp(r'[,\s]+$'), '').trim(),
      '${payload['negative_prompt']}',
    },
    model: modelKey('${(payload['override_settings'] as Map?)?['sd_model_checkpoint'] ?? ''}'),
    seed: (payload['seed'] as num?)?.toInt(),
    runs: (payload['n_iter'] as num? ?? 1).toInt(),
    steps: (payload['steps'] as num?)?.toInt(),
    cfg: (payload['cfg_scale'] as num?)?.toDouble(),
    width: (payload['width'] as num?)?.toInt(),
    height: (payload['height'] as num?)?.toInt(),
    strength: (payload['denoising_strength'] as num? ?? 1).toDouble(),
    masked: payload['mask'] != null,
    loras: {for (final m in tag.allMatches(prompt)) modelKey(m.group(1)!): double.parse(m.group(2)!)},
  );
}

// ---------------------------------------------------------------- pictures

/// The kinds of picture each feature is tried on.
enum Picture { own, sdxlElsewhere, krea2Elsewhere }

/// An SDXL picture's settings, as [source] would record them.
Map<String, dynamic> sdxlSettings(String source) => {
      'source': source,
      'prompt': 'a red fox',
      'negative': 'blurry',
      'seed': '7',
      'model': 'juggernautXL_v9',
      'loras': [
        {'name': 'fur_detail', 'weight': 0.8},
      ],
      'params': [
        ['Steps', '28'],
        ['CFG scale', '6.5'],
        ['Sampler', 'DPM++ 2M Karras'],
      ],
      'width': 832,
      'height': 1216,
    };

/// A Krea 2 picture's settings, as [source] would record them: each
/// program names the same model its own way.
Map<String, dynamic> krea2Settings(String source) => {
      'source': source,
      'prompt': 'a lighthouse in fog',
      'negative': '',
      'seed': '7',
      'model': source == 'invokeai' ? 'Krea-2-Turbo' : 'krea2_turbo_fp8_scaled.safetensors',
      'models': [
        if (source == 'invokeai')
          {'kind': 'qwen3_vl_encoder', 'name': 'Qwen3-VL 4B', 'hash': ''}
        else
          {'kind': 'clip', 'name': 'qwen3vl_4b_fp8_scaled.safetensors', 'hash': ''},
      ],
      'loras': [
        {'name': 'krea2_style', 'weight': 0.7},
      ],
      'params': [
        ['Steps', '8'],
        ['CFG scale', '1'],
        ['Sampler', 'euler'],
      ],
      'width': 1024,
      'height': 1024,
    };

/// The picture [kind] is sent for [picture]. A picture made by [kind]
/// itself carries the graph [kind] would have made for it, as the real
/// program saves it.
GenInfo picture(String kind, Picture picture, {bool krea2 = false}) {
  switch (picture) {
    case Picture.sdxlElsewhere:
      // From whichever program is not this one.
      return GenInfo.fromJson(sdxlSettings(kind == 'forge' ? 'invokeai' : 'a1111'));
    case Picture.krea2Elsewhere:
      return GenInfo.fromJson(krea2Settings(kind == 'invokeai' ? 'comfyui' : 'invokeai'));
    case Picture.own:
      final settings = krea2 ? krea2Settings(kind) : sdxlSettings(kind);
      final plain = GenInfo.fromJson(settings);
      final recipe = Recipe.from(plain, prompt: plain.prompt, negative: plain.negative, width: plain.width, height: plain.height);
      final raw = switch (kind) {
        'comfyui' => [
            'prompt',
            jsonEncode(comfyGraph(
              recipe,
              7,
              const ComfyModels(
                comfyCheckpoints,
                comfyLoras,
                unets: comfyUnets,
                encoders: comfyEncoders,
                encoderTypes: ['krea2'],
                vaes: comfyVaes,
              ),
            )),
          ],
        'invokeai' => ['invokeai_graph', jsonEncode(invokeGraph(recipe, 7, invokeMains, invokeLoras))],
        _ => ['parameters', '${plain.prompt}\nSteps: 28'],
      };
      return GenInfo.fromJson({
        ...settings,
        'raw': [raw],
      });
  }
}

// ---------------------------------------------------------------- features

/// A feature of the remix panel, as a change to make and what the server
/// must then be sent.
class Feature {
  const Feature(this.name, this.make, this.check);
  final String name;

  /// The remix of [info] that uses it.
  final Remix Function(GenInfo info) make;

  /// What each job sent must show. [all] is every job, in order.
  final void Function(GenInfo info, List<Sent> all) check;
}

/// The size the picture is made at: its own, kept to what servers take.
int side(int v) => (v / 16).round() * 16;

/// A remix of [info] as the panel makes one, changed by the arguments.
Remix remixOf(
  GenInfo info, {
  String? prompt,
  int seed = 7,
  int count = 1,
  int? width,
  int? height,
  int? steps,
  double? cfg,
  List<LoraChoice>? loras,
  ImageInput? init,
}) => Remix(
  info: info,
  prompt: prompt ?? info.prompt,
  negative: info.negative,
  seed: seed,
  randomSeed: false,
  count: count,
  width: width ?? info.width,
  height: height ?? info.height,
  steps: steps,
  cfg: cfg,
  loras: loras,
  init: init,
);

/// A PNG to start from, and a mask the same size, both ways round.
final Uint8List startPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

ImageInput startFrom({required double strength, bool masked = false}) => ImageInput(
  image: startPng,
  strength: strength,
  mask: masked ? startPng : null,
  keepMask: masked ? startPng : null,
);

/// The LoRA [info] loads first, turned to [weight] (or off).
List<LoraChoice> loraSet(GenInfo info, {double? weight, bool enabled = true}) => [
  for (final (i, l) in info.loras.indexed)
    LoraChoice(l, enabled: i == 0 ? enabled : true, weight: i == 0 ? weight : null),
];

final List<Feature> features = [
  Feature(
    'text to image: the prompt as edited',
    (info) => remixOf(info, prompt: '${info.prompt}, at dawn'),
    (info, all) => expect(all.single.prompts, contains('${info.prompt}, at dawn')),
  ),
  Feature(
    'text to image: the seed asked for, then one more per picture',
    (info) => remixOf(info, seed: 42, count: 3),
    (info, all) {
      expect(all.fold<int>(0, (n, s) => n + s.runs), 3, reason: 'three pictures in all');
      expect(all.first.seed, 42);
      if (all.length > 1) expect([for (final s in all) s.seed], [42, 43, 44]);
    },
  ),
  Feature(
    'text to image: the size set',
    (info) => remixOf(info, width: 768, height: 1344),
    (info, all) => expect([all.single.width, all.single.height], [768, 1344]),
  ),
  Feature(
    'text to image: steps and CFG set',
    (info) => remixOf(info, steps: 30, cfg: 4.5),
    (info, all) => expect([all.single.steps, all.single.cfg], [30, 4.5]),
  ),
  Feature(
    'text to image: the model the picture was made with',
    (info) => remixOf(info),
    (info, all) => expect(all.single.model, info.model.toLowerCase().contains('krea') ? contains('krea') : 'juggernautxl_v9'),
  ),
  Feature(
    'LoRA: its weight moved',
    (info) => remixOf(info, loras: loraSet(info, weight: 1.25)),
    (info, all) => expect(all.single.loras[modelKey(info.loras.first.name)], 1.25),
  ),
  Feature(
    'LoRA: switched off',
    (info) => remixOf(info, loras: loraSet(info, enabled: false)),
    (info, all) => expect(all.single.loras.keys, isNot(contains(modelKey(info.loras.first.name)))),
  ),
  Feature(
    'image to image: started from the picture at the strength set',
    (info) => remixOf(info, init: startFrom(strength: 0.6)),
    (info, all) {
      expect(all.single.strength, closeTo(0.6, 0.05));
      expect(all.single.masked, isFalse);
    },
  ),
  Feature(
    'image to image: only the painted area redrawn',
    (info) => remixOf(info, init: startFrom(strength: 0.55, masked: true)),
    (info, all) {
      expect(all.single.strength, closeTo(0.55, 0.05));
      expect(all.single.masked, isTrue);
    },
  ),
  Feature(
    'hires fix: twice the size, refined at low strength',
    (info) => remixOf(
      info,
      width: side(info.width * 2),
      height: side(info.height * 2),
      init: startFrom(strength: 0.35),
    ),
    (info, all) {
      expect(all.single.strength, closeTo(0.35, 0.05));
      // Where the server still sets a size, it is the bigger one.
      if (all.single.width != null) expect(all.single.width, side(info.width * 2));
    },
  ),
];

/// Combinations that cannot work, and why: each must say so here rather
/// than be left out quietly. Keyed `server/picture/feature`; `*` for any.
const Map<String, String> notApplicable = {};

String? whyNot(String kind, Picture p, Feature f) {
  for (final key in ['$kind/${p.name}/${f.name}', '$kind/${p.name}/*', '$kind/*/${f.name}', '*/${p.name}/${f.name}']) {
    if (notApplicable[key] != null) return notApplicable[key];
  }
  return null;
}

// ---------------------------------------------------------------- the table

void main() {
  setUp(() => remixPollEvery = const Duration(milliseconds: 20));

  for (final kind in servers) {
    group(backendNames[kind]!, () {
      for (final (p, krea2) in [
        (Picture.own, false),
        (Picture.own, true),
        (Picture.sdxlElsewhere, false),
        (Picture.krea2Elsewhere, true),
      ]) {
        final label = switch (p) {
          Picture.own => krea2 ? 'its own Krea 2 picture' : 'its own SDXL picture',
          Picture.sdxlElsewhere => 'an SDXL picture from elsewhere',
          Picture.krea2Elsewhere => 'a Krea 2 picture from elsewhere',
        };
        group(label, () {
          for (final f in features) {
            final skip = whyNot(kind, p, f);
            test(f.name, skip: skip, () async {
              final server = await FakeServer.start(kind);
              addTearDown(server.close);
              final info = picture(kind, p, krea2: krea2);
              final remix = f.make(info);
              final ticket = await sendRemix(kind, server.base, remix);
              expect(ticket.count, remix.count);
              expect(server.sent, isNotEmpty, reason: 'something was queued');
              if (remix.init != null) {
                expect(server.uploads, remix.init!.masked ? 2 : 1, reason: 'the picture (and mask) handed over');
              }
              final all = [for (final s in server.sent) read(kind, s)];
              f.check(info, all);
            });
          }
        });
      }
    });
  }

  test('every server is in the table', () {
    expect(servers.toSet(), backendNames.keys.toSet(), reason: 'a new server needs its fake and its reader here');
  });

  test('a picture from elsewhere can go to every server', () {
    for (final kind in servers) {
      for (final p in [Picture.sdxlElsewhere, Picture.krea2Elsewhere]) {
        expect(backendSupport(picture(kind, p))[kind], isNull, reason: '$kind, ${p.name}');
      }
    }
  });
}
