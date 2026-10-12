/// Sending a picture's recipe back to the program that made it, to make
/// more like it: ComfyUI, InvokeAI or Forge / A1111, on this machine or
/// another on the network.
///
/// Each takes what it understands best. ComfyUI gets the picture's own
/// workflow graph (the `prompt` block ComfyUI saves) with the prompt, seed
/// and size changed in place; InvokeAI gets its own saved graph the same
/// way; Forge and A1111 get the settings as plain values, which works for a
/// picture from any of them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'models.dart';

/// What to make: the picture's recipe with the user's changes.
class Remix {
  Remix({
    required this.info,
    required this.prompt,
    required this.negative,
    required this.seed,
    required this.randomSeed,
    required this.count,
    required this.width,
    required this.height,
  });

  final GenInfo info;
  final String prompt;
  final String negative;

  /// The seed for the first run, when not random; each further run adds one.
  final int seed;
  final bool randomSeed;

  /// How many pictures to queue.
  final int count;
  final int width;
  final int height;

  int seedFor(int run, math.Random random) =>
      randomSeed ? random.nextInt(1 << 32) : seed + run;
}

class BackendException implements Exception {
  BackendException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The backends, by the key their address is saved under.
const Map<String, String> backendNames = {
  'comfyui': 'ComfyUI',
  'invokeai': 'InvokeAI',
  'forge': 'Forge / A1111',
};

/// Where a backend usually listens.
const Map<String, String> backendDefaults = {
  'comfyui': 'http://127.0.0.1:8188',
  'invokeai': 'http://127.0.0.1:9090',
  'forge': 'http://127.0.0.1:7860',
};

/// The raw text block a picture saved under [key], if any.
String? rawBlock(GenInfo info, String key) {
  for (final r in info.raw) {
    if (r.key == key) return r.value;
  }
  return null;
}

/// Which backends can take [info], and why not where one cannot.
Map<String, String?> backendSupport(GenInfo info) {
  final comfy = rawBlock(info, 'prompt');
  final hasComfy = comfy != null && comfy.trimLeft().startsWith('{');
  final hasInvoke = rawBlock(info, 'invokeai_graph') != null;
  return {
    'comfyui': hasComfy
        ? null
        : 'This picture does not carry a ComfyUI workflow.',
    'invokeai': hasInvoke
        ? null
        : 'This picture does not carry an InvokeAI graph.',
    'forge': info.hasGeneration ? null : 'This picture has no generation data.',
  };
}

/// The setting [names] (any of them, case aside) from [info].
String? param(GenInfo info, List<String> names) {
  for (final p in info.params) {
    if (names.contains(p.key.toLowerCase())) return p.value;
  }
  return null;
}

/// Picture size from the metadata: the image's own, or a "Size" setting.
(int, int) recipeSize(GenInfo info) {
  final size = param(info, ['size']);
  final m = size == null ? null : RegExp(r'(\d+)\s*[x×]\s*(\d+)').firstMatch(size);
  if (m != null) return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  return (info.width, info.height);
}

/// Queue [remix] on the backend [kind] at [base]. Returns a line saying
/// what was queued.
Future<String> sendRemix(String kind, String base, Remix remix) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    return switch (kind) {
      'comfyui' => await _comfy(client, base, remix),
      'invokeai' => await _invoke(client, base, remix),
      'forge' => await _forge(client, base, remix),
      _ => throw BackendException('Unknown backend $kind'),
    };
  } on SocketException catch (e) {
    throw BackendException('Could not reach ${backendNames[kind]} at $base (${e.message}).');
  } on TimeoutException {
    throw BackendException('${backendNames[kind]} at $base did not answer.');
  } finally {
    // Not forced: Forge may still be sending its answer.
    client.close();
  }
}

/// Check that a backend answers at [base]: a short description of what is
/// there.
Future<String> probeBackend(String kind, String base) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final path = switch (kind) {
    'comfyui' => '/system_stats',
    'invokeai' => '/api/v1/app/version',
    _ => '/sdapi/v1/options',
  };
  try {
    final reply = await _get(client, '$base$path').timeout(const Duration(seconds: 8));
    return switch (kind) {
      'comfyui' => 'ComfyUI ${(reply['system'] as Map?)?['comfyui_version'] ?? ''}'.trim(),
      'invokeai' => 'InvokeAI ${reply['version'] ?? ''}'.trim(),
      _ => 'Model: ${reply['sd_model_checkpoint'] ?? 'unknown'}',
    };
  } on SocketException catch (e) {
    throw BackendException('Could not reach $base (${e.message}).');
  } on TimeoutException {
    throw BackendException('$base did not answer.');
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _get(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close().timeout(const Duration(seconds: 10));
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode >= 300) {
    throw BackendException('$url answered ${response.statusCode}.');
  }
  final decoded = jsonDecode(body);
  return decoded is Map<String, dynamic> ? decoded : {'value': decoded};
}

Future<Map<String, dynamic>> _post(
  HttpClient client,
  String url,
  Object body, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final request = await client.postUrl(Uri.parse(url));
  request.headers.contentType = ContentType.json;
  request.add(utf8.encode(jsonEncode(body)));
  final response = await request.close().timeout(timeout);
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode >= 300) {
    var detail = text;
    try {
      final j = jsonDecode(text);
      if (j is Map) {
        detail = '${j['error'] ?? j['detail'] ?? j['message'] ?? text}';
      }
    } catch (_) {}
    if (detail.length > 300) detail = '${detail.substring(0, 300)}…';
    throw BackendException('$url answered ${response.statusCode}: $detail');
  }
  if (text.trim().isEmpty) return const {};
  final decoded = jsonDecode(text);
  return decoded is Map<String, dynamic> ? decoded : {'value': decoded};
}

/// Change a node graph in place: text inputs equal to the old prompts get
/// the new ones; seeds, sizes and batch sizes get the new values. Works on
/// ComfyUI's `{id: {class_type, inputs}}` and InvokeAI's `{nodes: {id:
/// {...fields}}}` alike, since both keep these as plain fields of a node.
/// Returns how many prompt fields were found.
int _patchGraph(
  Map<String, dynamic> nodes,
  Remix remix,
  int seed, {
  required Map<String, dynamic> Function(Map<String, dynamic> node) fields,
}) {
  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final oldPrompt = norm(remix.info.prompt);
  final oldNegative = norm(remix.info.negative);
  final (oldW, oldH) = recipeSize(remix.info);
  var found = 0;
  for (final node in nodes.values) {
    if (node is! Map<String, dynamic>) continue;
    final f = fields(node);
    for (final key in f.keys.toList()) {
      final v = f[key];
      if (v is String) {
        final n = norm(v);
        if (oldPrompt.isNotEmpty && n == oldPrompt) {
          f[key] = remix.prompt;
          found++;
        } else if (oldNegative.isNotEmpty && n == oldNegative) {
          f[key] = remix.negative;
        }
      } else if (v is num) {
        switch (key) {
          case 'seed' || 'noise_seed':
            f[key] = seed;
          case 'width':
            if (oldW == 0 || v == oldW) f[key] = remix.width;
          case 'height':
            if (oldH == 0 || v == oldH) f[key] = remix.height;
        }
      }
    }
  }
  return found;
}

void _requirePrompt(int found, Remix remix) {
  final changed = remix.prompt.trim() != remix.info.prompt.trim();
  if (found == 0 && changed) {
    throw BackendException(
      'The edited prompt could not be put into this workflow: its prompt is '
      'built from several pieces. Send it unchanged, or edit it in the app '
      'that made it.',
    );
  }
}

Future<String> _comfy(HttpClient client, String base, Remix remix) async {
  final raw = rawBlock(remix.info, 'prompt');
  if (raw == null) throw BackendException(backendSupport(remix.info)['comfyui']!);
  final random = math.Random();
  final ids = <String>[];
  for (var run = 0; run < remix.count; run++) {
    final graph = jsonDecode(raw) as Map<String, dynamic>;
    final found = _patchGraph(
      graph,
      remix,
      remix.seedFor(run, random),
      fields: (node) => (node['inputs'] as Map<String, dynamic>?) ?? {},
    );
    if (run == 0) _requirePrompt(found, remix);
    final reply = await _post(client, '$base/prompt', {
      'prompt': graph,
      'client_id': 'generativeview',
    });
    ids.add('${reply['prompt_id'] ?? ''}');
  }
  return 'Queued ${_count(remix.count)} in ComfyUI';
}

Future<String> _invoke(HttpClient client, String base, Remix remix) async {
  final raw = rawBlock(remix.info, 'invokeai_graph');
  if (raw == null) throw BackendException(backendSupport(remix.info)['invokeai']!);
  final random = math.Random();
  for (var run = 0; run < remix.count; run++) {
    final graph = jsonDecode(raw) as Map<String, dynamic>;
    final nodes = (graph['nodes'] as Map<String, dynamic>?) ?? {};
    final found = _patchGraph(nodes, remix, remix.seedFor(run, random), fields: (node) => node);
    if (run == 0) _requirePrompt(found, remix);
    await _post(client, '$base/api/v1/queue/default/enqueue_batch', {
      'batch': {'graph': graph, 'runs': 1},
      'prepend': false,
    });
  }
  return 'Queued ${_count(remix.count)} in InvokeAI';
}

Future<String> _forge(HttpClient client, String base, Remix remix) async {
  final info = remix.info;
  double? number(List<String> names) => double.tryParse(param(info, names) ?? '');
  final sampler = param(info, ['sampler', 'sampler_name']);
  final scheduler = param(info, ['schedule type', 'scheduler']);
  final payload = <String, Object?>{
    'prompt': remix.prompt,
    'negative_prompt': remix.negative,
    'seed': remix.randomSeed ? -1 : remix.seed,
    'n_iter': remix.count,
    'batch_size': 1,
    'width': remix.width,
    'height': remix.height,
    'steps': ?number(['steps'])?.round(),
    'cfg_scale': ?number(['cfg scale', 'cfg']),
    'sampler_name': ?sampler,
    'scheduler': ?scheduler,
    'save_images': true,
    'send_images': false,
    if (info.model.isNotEmpty)
      'override_settings': {'sd_model_checkpoint': info.model},
  };
  // Forge answers when the pictures are done; that can take a while, so
  // only wait long enough to know it started.
  final pending = _post(client, '$base/sdapi/v1/txt2img', payload, timeout: const Duration(minutes: 30));
  try {
    await pending.timeout(const Duration(seconds: 4));
  } on TimeoutException {
    // Still working on it: queued.
    unawaited(pending.then((_) {}, onError: (Object _) {}));
  }
  return 'Sent ${_count(remix.count)} to Forge / A1111';
}

String _count(int n) => n == 1 ? '1 picture' : '$n pictures';
