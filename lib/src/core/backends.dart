/// Sending a picture's recipe back to the program that made it, to make
/// more like it: ComfyUI, InvokeAI or Forge / A1111, on this machine or
/// another on the network.
///
/// Each takes what it understands best. ComfyUI gets the picture's own
/// workflow graph (the `prompt` block ComfyUI saves) with the prompt, seed
/// and size changed in place; InvokeAI gets its own saved graph the same
/// way; Forge and A1111 get the settings as plain values, which works for a
/// picture from any of them.
///
/// Whatever is queued is then waited for: ComfyUI and InvokeAI are asked
/// every couple of seconds whether the job is done, and Forge sends the
/// pictures back in its answer. The finished pictures come back as
/// [RemixImage]s, for the app to save beside the original.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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

/// A finished picture from a backend, as the file it should be saved as.
class RemixImage {
  RemixImage(this.bytes) : extension = imageExtension(bytes);
  final Uint8List bytes;

  /// png, jpg or webp, by what the bytes are.
  final String extension;
}

/// What [sendRemix] queued: a line to show, and the pictures as they finish.
class RemixTicket {
  RemixTicket(this.message, this.count, this.results);
  final String message;

  /// How many pictures were asked for.
  final int count;

  /// Each picture as it is done; an error for a run that failed. Closes
  /// when every run has finished or failed.
  final Stream<RemixImage> results;
}

/// How long to keep waiting for a backend to finish what was queued.
const Duration remixPatience = Duration(hours: 3);

/// How often to ask ComfyUI or InvokeAI whether it is done.
Duration remixPollEvery = const Duration(seconds: 2);

/// The file extension for an image's [bytes]: png, jpg or webp.
String imageExtension(List<int> bytes) {
  bool starts(List<int> magic, [int at = 0]) {
    if (bytes.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[at + i] != magic[i]) return false;
    }
    return true;
  }

  if (starts(const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
      starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'webp';
  }
  return 'png';
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

/// Queue [remix] on the backend [kind] at [base]. The ticket says what was
/// queued, and brings the pictures back as they finish.
Future<RemixTicket> sendRemix(String kind, String base, Remix remix) async {
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

/// The body of [url], as bytes.
Future<Uint8List> _bytes(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close().timeout(const Duration(seconds: 30));
  if (response.statusCode >= 300) {
    await response.drain<void>();
    throw BackendException('$url answered ${response.statusCode}.');
  }
  final builder = BytesBuilder(copy: false);
  await for (final part in response.timeout(const Duration(minutes: 2))) {
    builder.add(part);
  }
  return builder.takeBytes();
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
  return RemixTicket(
    'Queued ${_count(remix.count)} in ComfyUI',
    remix.count,
    _comfyResults(base, ids),
  );
}

/// Wait for each of the ComfyUI prompts [ids] and fetch what it saved.
Stream<RemixImage> _comfyResults(String base, List<String> ids) async* {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    for (final id in ids) {
      if (id.isEmpty) continue;
      final deadline = DateTime.now().add(remixPatience);
      Map<String, dynamic>? entry;
      while (entry == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw BackendException('ComfyUI did not finish within ${remixPatience.inHours} hours.');
        }
        await Future<void>.delayed(remixPollEvery);
        try {
          final history = await _get(client, '$base/history/$id');
          final found = history[id];
          if (found is Map<String, dynamic>) entry = found;
        } on SocketException {
          // The server may be restarting: keep asking until the deadline.
        } on TimeoutException {
          // As above.
        }
      }
      final status = entry['status'];
      if (status is Map && status['status_str'] == 'error') {
        yield* Stream.error(BackendException(_comfyError(status)));
        continue;
      }
      final outputs = entry['outputs'];
      if (outputs is! Map) continue;
      for (final output in outputs.values) {
        final images = output is Map ? output['images'] : null;
        if (images is! List) continue;
        for (final image in images) {
          // Previews are temp files; only what a Save node wrote is kept.
          if (image is! Map || image['type'] != 'output') continue;
          final query = Uri(queryParameters: {
            'filename': '${image['filename']}',
            'subfolder': '${image['subfolder'] ?? ''}',
            'type': 'output',
          }).query;
          yield RemixImage(await _bytes(client, '$base/view?$query'));
        }
      }
    }
  } finally {
    client.close(force: true);
  }
}

String _comfyError(Map<dynamic, dynamic> status) {
  final messages = status['messages'];
  if (messages is List) {
    for (final m in messages) {
      if (m is List && m.length > 1 && m[0] == 'execution_error') {
        final detail = m[1];
        if (detail is Map && detail['exception_message'] != null) {
          return 'ComfyUI: ${'${detail['exception_message']}'.trim()}';
        }
      }
    }
  }
  return 'ComfyUI could not run the workflow.';
}

Future<String> _invoke(HttpClient client, String base, Remix remix) async {
  final raw = rawBlock(remix.info, 'invokeai_graph');
  if (raw == null) throw BackendException(backendSupport(remix.info)['invokeai']!);
  final random = math.Random();
  final ids = <int>[];
  var fetchable = true;
  for (var run = 0; run < remix.count; run++) {
    final graph = jsonDecode(raw) as Map<String, dynamic>;
    final nodes = (graph['nodes'] as Map<String, dynamic>?) ?? {};
    final found = _patchGraph(nodes, remix, remix.seedFor(run, random), fields: (node) => node);
    if (run == 0) _requirePrompt(found, remix);
    final reply = await _post(client, '$base/api/v1/queue/default/enqueue_batch', {
      'batch': {'graph': graph, 'runs': 1},
      'prepend': false,
    });
    final items = reply['item_ids'];
    if (items is List) {
      ids.addAll(items.whereType<num>().map((n) => n.toInt()));
    } else {
      fetchable = false;
    }
  }
  return RemixTicket(
    'Queued ${_count(remix.count)} in InvokeAI',
    remix.count,
    fetchable
        ? _invokeResults(base, ids)
        : Stream.error(BackendException(
            'This InvokeAI does not say which queue items it made, so the '
            'pictures stay in its gallery. Updating InvokeAI fixes this.',
          )),
  );
}

/// Wait for each of the InvokeAI queue items [ids] and fetch the pictures
/// it kept (not its intermediate steps).
Stream<RemixImage> _invokeResults(String base, List<int> ids) async* {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final api = '$base/api/v1';
  try {
    for (final id in ids) {
      final deadline = DateTime.now().add(remixPatience);
      Map<String, dynamic>? item;
      while (item == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw BackendException('InvokeAI did not finish within ${remixPatience.inHours} hours.');
        }
        await Future<void>.delayed(remixPollEvery);
        try {
          final got = await _get(client, '$api/queue/default/i/$id');
          if (const {'completed', 'failed', 'canceled'}.contains(got['status'])) {
            item = got;
          }
        } on SocketException {
          // Restarting, perhaps: keep asking until the deadline.
        } on TimeoutException {
          // As above.
        }
      }
      switch (item['status']) {
        case 'canceled':
          yield* Stream.error(BackendException('A remix was cancelled in InvokeAI.'));
          continue;
        case 'failed':
          final why = item['error_message'] ?? item['error_type'] ?? item['error'];
          yield* Stream.error(BackendException(
            why == null ? 'InvokeAI could not run the graph.' : 'InvokeAI: ${'$why'.trim().split('\n').first}',
          ));
          continue;
      }
      final session = item['session'];
      final results = session is Map ? session['results'] : null;
      if (results is! Map) continue;
      final names = <String>{};
      for (final result in results.values) {
        if (result is! Map) continue;
        final image = result['image'];
        if (image is Map && image['image_name'] is String) {
          names.add(image['image_name'] as String);
        }
      }
      for (final name in names) {
        final path = Uri.encodeComponent(name);
        final dto = await _get(client, '$api/images/i/$path');
        if (dto['is_intermediate'] == true) continue;
        yield RemixImage(await _bytes(client, '$api/images/i/$path/full'));
      }
    }
  } finally {
    client.close(force: true);
  }
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
    'send_images': true,
    if (info.model.isNotEmpty)
      'override_settings': {'sd_model_checkpoint': info.model},
  };
  // Forge answers when the pictures are done, with them in the answer.
  // That can take a while, so only wait long enough to know it started; the
  // rest is waited for in the background. Its own client, since the one
  // passed in is closed as soon as this returns.
  final own = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final pending = _post(own, '$base/sdapi/v1/txt2img', payload, timeout: remixPatience)
      .whenComplete(() => own.close(force: true));
  // Read by the stream below, or (if this throws first) not at all.
  pending.ignore();
  try {
    await pending.timeout(const Duration(seconds: 4));
  } on TimeoutException {
    // Still working on it: queued.
  }
  return RemixTicket(
    'Sent ${_count(remix.count)} to Forge / A1111',
    remix.count,
    _forgeResults(pending),
  );
}

/// The pictures in Forge's answer, each with its settings written in if
/// Forge left them out.
Stream<RemixImage> _forgeResults(Future<Map<String, dynamic>> pending) async* {
  final reply = await pending;
  final images = (reply['images'] as List?)?.whereType<String>().toList() ?? const [];
  var infotexts = const <String>[];
  try {
    final info = jsonDecode('${reply['info'] ?? ''}');
    if (info is Map && info['infotexts'] is List) {
      infotexts = (info['infotexts'] as List).map((t) => '$t').toList();
    }
  } catch (_) {}
  // With several pictures a grid of them all may come first.
  final skip = infotexts.isNotEmpty && images.length > infotexts.length
      ? images.length - infotexts.length
      : 0;
  for (var i = skip; i < images.length; i++) {
    var data = images[i];
    final comma = data.indexOf(',');
    if (data.startsWith('data:') && comma > 0) data = data.substring(comma + 1);
    var bytes = base64Decode(data);
    final text = i - skip < infotexts.length ? infotexts[i - skip] : null;
    if (text != null && text.isNotEmpty) bytes = withParameters(bytes, text);
    yield RemixImage(bytes);
  }
}

/// [png] with a `parameters` text chunk saying [text], as A1111 writes it,
/// unless it already has one. Anything but a PNG is returned as it is.
Uint8List withParameters(Uint8List png, String text) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (png.length < 33) return png;
  for (var i = 0; i < 8; i++) {
    if (png[i] != signature[i]) return png;
  }
  // Already there?
  var at = 8;
  final view = ByteData.sublistView(png);
  while (at + 8 <= png.length) {
    final length = view.getUint32(at);
    final type = String.fromCharCodes(png.sublist(at + 4, at + 8));
    if (type == 'IDAT' || type == 'IEND') break;
    if ((type == 'tEXt' || type == 'iTXt') && at + 8 + 10 <= png.length) {
      final keyword = String.fromCharCodes(png.sublist(at + 8, at + 8 + 10));
      if (keyword == 'parameters') return png;
    }
    at += 12 + length;
  }
  // iTXt, uncompressed, so any characters survive.
  final data = BytesBuilder()
    ..add(latin1.encode('parameters'))
    ..add(const [0, 0, 0, 0, 0])
    ..add(utf8.encode(text));
  final body = data.toBytes();
  final chunk = BytesBuilder();
  final head = ByteData(8)
    ..setUint32(0, body.length)
    ..setUint8(4, 0x69) // i
    ..setUint8(5, 0x54) // T
    ..setUint8(6, 0x58) // X
    ..setUint8(7, 0x74); // t
  chunk.add(head.buffer.asUint8List());
  chunk.add(body);
  final crc = ByteData(4)
    ..setUint32(0, _crc32([...head.buffer.asUint8List(4, 4), ...body]));
  chunk.add(crc.buffer.asUint8List());
  // After IHDR, which is always first and always 13 bytes.
  const afterHeader = 8 + 12 + 13;
  return (BytesBuilder()
        ..add(png.sublist(0, afterHeader))
        ..add(chunk.toBytes())
        ..add(png.sublist(afterHeader)))
      .toBytes();
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

String _count(int n) => n == 1 ? '1 picture' : '$n pictures';
