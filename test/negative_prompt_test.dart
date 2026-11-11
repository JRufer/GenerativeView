// The negative prompt reaches the server: a picture's own workflow takes an
// edited one wherever its wiring says the negative goes, not only where the
// old text happened to sit, and says so when it has no place for it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/backends.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/negative_edits.dart';

/// A graph as it comes out of a picture: plain JSON.
Map<String, dynamic> g(Object graph) => jsonDecode(jsonEncode(graph)) as Map<String, dynamic>;

/// A ComfyUI workflow with one sampler; [negative] is the node its
/// negative input is wired to, and [more] any further nodes.
Map<String, dynamic> comfy({String negative = '7', Map<String, Object> more = const {}}) => g({
      '3': {
        'class_type': 'KSampler',
        'inputs': {'seed': 1, 'steps': 20, 'cfg': 7, 'positive': ['6', 0], 'negative': [negative, 0]},
      },
      '4': {'class_type': 'CheckpointLoaderSimple', 'inputs': {'ckpt_name': 'm.safetensors'}},
      '6': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'a red fox', 'clip': ['4', 1]}},
      ...more,
    });

Map<String, dynamic> edge(String from, String out, String to, String into) => {
      'source': {'node_id': from, 'field': out},
      'destination': {'node_id': to, 'field': into},
    };

/// An InvokeAI Krea 2 graph as made with CFG off: no negative encoder.
Map<String, dynamic> krea2() => g({
      'nodes': {
        'loader': {'id': 'loader', 'type': 'krea2_model_loader'},
        'pos': {'id': 'pos', 'type': 'krea2_text_encoder', 'prompt': 'a red fox'},
        'pos_collect': {'id': 'pos_collect', 'type': 'collect'},
        'denoise': {'id': 'denoise', 'type': 'krea2_denoise', 'seed': 1, 'steps': 8, 'cfg_scale': 1},
        'meta': {'id': 'meta', 'type': 'core_metadata', 'positive_prompt': 'a red fox', 'cfg_scale': 1},
      },
      'edges': [
        edge('loader', 'transformer', 'denoise', 'transformer'),
        edge('loader', 'qwen3_vl_encoder', 'pos', 'qwen3_vl_encoder'),
        edge('pos', 'conditioning', 'pos_collect', 'item'),
        edge('pos_collect', 'collection', 'denoise', 'positive_conditioning'),
      ],
    });

bool joins(List<dynamic> edges, String from, String out, String to, String into) => edges.any((e) =>
    e['source']['node_id'] == from && e['source']['field'] == out && e['destination']['node_id'] == to && e['destination']['field'] == into);

GenInfo picture(String source, String key, Map<String, dynamic> graph, {String negative = '', String cfg = '7'}) => GenInfo.fromJson({
      'source': source,
      'prompt': 'a red fox',
      'negative': negative,
      'seed': '7',
      'params': [
        ['Steps', '20'],
        ['CFG scale', cfg],
      ],
      'raw': [
        [key, jsonEncode(graph)],
      ],
      'width': 512,
      'height': 512,
    });

Remix remix(GenInfo info, String negative, {double? cfg, bool optional = false}) => Remix(
      info: info,
      prompt: 'a red fox',
      negative: negative,
      seed: 7,
      randomSeed: false,
      count: 1,
      width: 512,
      height: 512,
      cfg: cfg,
      negativeOptional: optional,
    );

/// A server that takes what is queued at [path] and answers [reply].
Future<(String, List<Map<String, dynamic>>)> queue(String path, Object reply) async {
  final taken = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.uri.path == path) {
      taken.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(reply));
    } else {
      request.response.statusCode = 404;
    }
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return ('http://127.0.0.1:${server.port}', taken);
}

void main() {
  // ------------------------------------------------------------- ComfyUI

  test('ComfyUI: a picture with no negative prompt takes one, in the negative encoder', () {
    final graph = comfy(more: {
      '7': {'class_type': 'CLIPTextEncode', 'inputs': {'text': '', 'clip': ['4', 1]}},
    });
    expect(placeComfyNegative(graph, 'blurry', old: ''), isTrue);
    expect(graph['7']['inputs']['text'], 'blurry');
    expect(graph['6']['inputs']['text'], 'a red fox', reason: 'the prompt is left alone');
  });

  test('ComfyUI: a negative kept in a string node is changed there', () {
    final graph = comfy(more: {
      '7': {'class_type': 'CLIPTextEncode', 'inputs': {'text': ['12', 0], 'clip': ['4', 1]}},
      '12': {'class_type': 'PrimitiveString', 'inputs': {'value': 'old words'}},
    });
    expect(placeComfyNegative(graph, 'blurry', old: 'old words'), isTrue);
    expect(graph['12']['inputs']['value'], 'blurry');
    expect(graph['7']['inputs']['text'], ['12', 0]);
  });

  test('ComfyUI: a negative built from several nodes takes a part each, or says it cannot', () {
    Map<String, dynamic> pieces() => comfy(negative: '8', more: {
          '7': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'blurry', 'clip': ['4', 1]}},
          '9': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'lowres', 'clip': ['4', 1]}},
          '8': {'class_type': 'ConditioningCombine', 'inputs': {'conditioning_1': ['7', 0], 'conditioning_2': ['9', 0]}},
        });
    final graph = pieces();
    expect(placeComfyNegative(graph, 'soft\n\ngrainy', old: 'blurry\n\nlowres'), isTrue);
    expect(graph['7']['inputs']['text'], 'soft');
    expect(graph['9']['inputs']['text'], 'grainy');

    // One piece for two places: not guessed at.
    final same = pieces();
    expect(placeComfyNegative(same, 'soft', old: 'blurry\n\nlowres'), isFalse);
    expect(same['7']['inputs']['text'], 'blurry');
    expect(same['9']['inputs']['text'], 'lowres');
  });

  test('ComfyUI: a negative that was the positive zeroed out gets an encoder of its own', () {
    Map<String, dynamic> zeroed() => comfy(more: {
          '7': {'class_type': 'ConditioningZeroOut', 'inputs': {'conditioning': ['6', 0]}},
        });
    final graph = zeroed();
    expect(placeComfyNegative(graph, 'blurry', old: ''), isTrue);
    final added = graph['generativeview_negative'] as Map;
    expect(added['class_type'], 'CLIPTextEncode');
    expect(added['inputs'], {'text': 'blurry', 'clip': ['4', 1]});
    expect(graph['3']['inputs']['negative'], ['generativeview_negative', 0]);
    expect(graph['6']['inputs']['text'], 'a red fox', reason: 'never written over the prompt');

    // With CFG off there is no use adding one.
    final off = zeroed();
    expect(placeComfyNegative(off, 'blurry', old: '', add: false), isFalse);
    expect(off.containsKey('generativeview_negative'), isFalse);
  });

  test('ComfyUI: a remix of a picture with no negative prompt sends the one typed', () async {
    final (base, queued) = await queue('/prompt', {'prompt_id': 'p1'});
    final graph = comfy(more: {
      '7': {'class_type': 'CLIPTextEncode', 'inputs': {'text': '', 'clip': ['4', 1]}},
    });
    final ticket = await sendRemix('comfyui', base, remix(picture('comfyui', 'prompt', graph), 'blurry, lowres'));
    expect(ticket.message, 'Queued 1 picture in ComfyUI');
    final sent = queued.single['prompt'] as Map;
    expect(sent['7']['inputs']['text'], 'blurry, lowres');
    expect(sent['6']['inputs']['text'], 'a red fox');
  });

  test('ComfyUI: a workflow with no negative prompt at all says so, unless the words were the app\'s own', () async {
    final (base, queued) = await queue('/prompt', {'prompt_id': 'p1'});
    // FLUX-style: a guider that takes the prompt alone.
    final graph = g({
      '6': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'a red fox', 'clip': ['4', 1]}},
      '4': {'class_type': 'DualCLIPLoader', 'inputs': <String, Object>{}},
      '22': {'class_type': 'BasicGuider', 'inputs': {'conditioning': ['6', 0]}},
    });
    final own = picture('comfyui', 'prompt', graph);
    await expectLater(
      sendRemix('comfyui', base, remix(own, 'blurry')),
      throwsA(isA<BackendException>().having((e) => e.message, 'message', contains('negative prompt could not be put'))),
    );
    expect(queued, isEmpty, reason: 'nothing is queued without it');

    await sendRemix('comfyui', base, remix(own, 'blurry', optional: true));
    expect(queued, hasLength(1));

    // Left as the picture had it, nothing is asked of the workflow.
    await sendRemix('comfyui', base, remix(own, ''));
    expect(queued, hasLength(2));
  });

  // ------------------------------------------------------------ InvokeAI

  test('InvokeAI: an empty negative kept in a string node takes the one typed, metadata too', () {
    final graph = g({
      'nodes': {
        'pos_text': {'id': 'pos_text', 'type': 'string', 'value': 'a red fox'},
        'neg_text': {'id': 'neg_text', 'type': 'string', 'value': ''},
        'pos': {'id': 'pos', 'type': 'sdxl_compel_prompt'},
        'neg': {'id': 'neg', 'type': 'sdxl_compel_prompt'},
        'denoise': {'id': 'denoise', 'type': 'denoise_latents', 'cfg_scale': 7},
        'meta': {'id': 'meta', 'type': 'core_metadata', 'positive_prompt': 'a red fox', 'negative_prompt': ''},
      },
      'edges': [
        edge('pos_text', 'value', 'pos', 'prompt'),
        edge('pos_text', 'value', 'pos', 'style'),
        edge('neg_text', 'value', 'neg', 'prompt'),
        edge('neg_text', 'value', 'neg', 'style'),
        edge('pos', 'conditioning', 'denoise', 'positive_conditioning'),
        edge('neg', 'conditioning', 'denoise', 'negative_conditioning'),
      ],
    });
    expect(placeInvokeNegative(graph, 'blurry', old: ''), isTrue);
    final nodes = graph['nodes'] as Map;
    expect(nodes['neg_text']['value'], 'blurry');
    expect(nodes['pos_text']['value'], 'a red fox');
    expect(nodes['meta']['negative_prompt'], 'blurry');
    expect(nodes['meta']['positive_prompt'], 'a red fox');
  });

  test('InvokeAI: an SDXL negative set in the encoder takes its style along', () {
    final graph = g({
      'nodes': {
        'pos': {'id': 'pos', 'type': 'sdxl_compel_prompt', 'prompt': 'a red fox', 'style': 'a red fox'},
        'neg': {'id': 'neg', 'type': 'sdxl_compel_prompt', 'prompt': '', 'style': ''},
        'denoise': {'id': 'denoise', 'type': 'denoise_latents', 'cfg_scale': 7},
      },
      'edges': [
        edge('pos', 'conditioning', 'denoise', 'positive_conditioning'),
        edge('neg', 'conditioning', 'denoise', 'negative_conditioning'),
      ],
    });
    expect(placeInvokeNegative(graph, 'blurry', old: ''), isTrue);
    final nodes = graph['nodes'] as Map;
    expect(nodes['neg']['prompt'], 'blurry');
    expect(nodes['neg']['style'], 'blurry');
    expect(nodes['pos']['prompt'], 'a red fox');
  });

  test('InvokeAI: a Krea 2 graph made with CFG off gets a negative encoder like its positive one', () {
    final graph = krea2();
    expect(placeInvokeNegative(graph, 'blurry', old: ''), isTrue);
    final nodes = graph['nodes'] as Map;
    final edges = graph['edges'] as List;
    final added = nodes['generativeview_negative'] as Map;
    expect(added['type'], 'krea2_text_encoder');
    expect(added['id'], 'generativeview_negative');
    expect(added['prompt'], 'blurry');
    expect(joins(edges, 'loader', 'qwen3_vl_encoder', 'generativeview_negative', 'qwen3_vl_encoder'), isTrue);
    expect(joins(edges, 'generativeview_negative', 'conditioning', 'denoise', 'negative_conditioning'), isTrue);
    expect(nodes['pos']['prompt'], 'a red fox');
    expect(nodes['meta']['negative_prompt'], 'blurry');

    final off = krea2();
    expect(placeInvokeNegative(off, 'blurry', old: '', add: false), isFalse);
    expect((off['nodes'] as Map).containsKey('generativeview_negative'), isFalse);
  });

  test('InvokeAI: a Krea 2 remix at CFG 1 says the negative is not used; with CFG raised it is sent', () async {
    final (base, queued) = await queue('/api/v1/queue/default/enqueue_batch', {'item_ids': [1]});
    final own = picture('invokeai', 'invokeai_graph', krea2(), cfg: '1');

    final ticket = await sendRemix('invokeai', base, remix(own, 'blurry'));
    expect(ticket.message, 'Queued 1 picture in InvokeAI; the negative prompt is not used at CFG 1 or below');
    var graph = (queued.last['batch'] as Map)['graph'] as Map;
    expect((graph['nodes'] as Map).containsKey('generativeview_negative'), isFalse);

    final raised = await sendRemix('invokeai', base, remix(own, 'blurry', cfg: 4));
    expect(raised.message, 'Queued 1 picture in InvokeAI');
    graph = (queued.last['batch'] as Map)['graph'] as Map;
    final nodes = graph['nodes'] as Map;
    expect(nodes['denoise']['cfg_scale'], 4);
    expect(nodes['generativeview_negative']['prompt'], 'blurry');
    expect(joins(graph['edges'] as List, 'generativeview_negative', 'conditioning', 'denoise', 'negative_conditioning'), isTrue);
  });

  test('InvokeAI: a changed negative is still swapped in where the old one sat', () async {
    final (base, queued) = await queue('/api/v1/queue/default/enqueue_batch', {'item_ids': [1]});
    final graph = g({
      'nodes': {
        'pos': {'id': 'pos', 'type': 'compel', 'prompt': 'a red fox'},
        'neg': {'id': 'neg', 'type': 'compel', 'prompt': 'blurry'},
        'denoise': {'id': 'denoise', 'type': 'denoise_latents', 'cfg_scale': 7},
        'meta': {'id': 'meta', 'type': 'core_metadata', 'negative_prompt': 'blurry'},
      },
      'edges': [
        edge('pos', 'conditioning', 'denoise', 'positive_conditioning'),
        edge('neg', 'conditioning', 'denoise', 'negative_conditioning'),
      ],
    });
    await sendRemix('invokeai', base, remix(picture('invokeai', 'invokeai_graph', graph, negative: 'blurry'), 'blurry, extra fingers'));
    final nodes = ((queued.single['batch'] as Map)['graph'] as Map)['nodes'] as Map;
    expect(nodes['neg']['prompt'], 'blurry, extra fingers');
    expect(nodes['meta']['negative_prompt'], 'blurry, extra fingers');
    expect(nodes['pos']['prompt'], 'a red fox');
  });
}
