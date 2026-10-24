/// Sending a picture's recipe back to the program that made it, to make
/// more like it: ComfyUI, InvokeAI or Forge / A1111, on this machine or
/// another on the network.
///
/// Each takes what it understands best. ComfyUI gets the picture's own
/// workflow graph (the `prompt` block ComfyUI saves) with the prompt, seed
/// and size changed in place; InvokeAI gets its own saved graph the same
/// way; Forge and A1111 get the settings as plain values, which works for a
/// picture from any of them. A picture from another program can still go to
/// ComfyUI or InvokeAI: a plain text-to-image graph is built from its
/// settings (see recipe_graphs.dart), with the model and LoRAs matched by
/// name against what that server has installed.
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

import 'lora_edits.dart';
import 'models.dart';
import 'recipe_graphs.dart';

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
    this.steps,
    this.cfg,
    this.loras,
    this.init,
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

  /// Sampling steps and CFG scale as the user set them; null to send them
  /// as the picture had them.
  final int? steps;
  final double? cfg;

  /// The picture's LoRAs as the user has set them (on or off, and how
  /// strong); null to send them as the picture had them.
  final List<LoraChoice>? loras;

  /// The picture to start from, for image to image; null to start from
  /// noise (text to image).
  final ImageInput? init;

  /// [prompt] with its LoRA tags following [loras].
  String get sentPrompt => loras == null ? prompt : retagPrompt(prompt, loras!);

  /// [negative] likewise.
  String get sentNegative => loras == null ? negative : retagPrompt(negative, loras!);

  /// The LoRAs a graph built from the settings should load: those left on,
  /// at the weights set.
  List<LoraRef> get sentLoras => loras == null
      ? info.loras
      : [
          for (final c in loras!)
            if (c.enabled) c.ref,
        ];

  int seedFor(int run, math.Random random) =>
      randomSeed ? random.nextInt(1 << 32) : seed + run;
}

/// The picture a remix starts from, for image to image: the picture itself,
/// how much of it to redraw, and where.
class ImageInput {
  ImageInput({required this.image, required this.strength, this.mask, this.keepMask});

  /// The picture as a PNG, already at the remix's width and height.
  final Uint8List image;

  /// How much is redrawn, from 0 (nothing) to 1 (all of it, as though from
  /// noise): the denoising strength.
  final double strength;

  /// Where to redraw, as a PNG the same size: white where the picture is
  /// redrawn, black where it is kept. Null to redraw all of it.
  final Uint8List? mask;

  /// [mask] the other way round (white kept, black redrawn), as InvokeAI
  /// takes it. Made alongside [mask], since only the app can draw.
  final Uint8List? keepMask;

  bool get masked => mask != null;
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
  RemixTicket(
    this.message,
    this.count,
    this.results, {
    this.kind = '',
    this.base = '',
    this.jobs = const [],
    Stream<String>? finished,
  }) : finished = finished ?? const Stream.empty();
  final String message;

  /// How many pictures were asked for.
  final int count;

  /// Each picture as it is done; an error for a run that failed. Closes
  /// when every run has finished or failed.
  final Stream<RemixImage> results;

  /// Where it was queued, and the server's names for the jobs: enough to
  /// pick the wait up again with [resumeRemix] after the app was closed.
  /// No jobs for a server that cannot be asked later (Forge).
  final String kind;
  final String base;
  final List<String> jobs;

  /// Each of [jobs] once it is dealt with (its pictures handed on, or its
  /// failure), so a wait picked up later does not fetch it again.
  final Stream<String> finished;
}

/// Wait again for [jobs] queued on the backend [kind] at [base] by an
/// earlier [sendRemix], after the app was closed: the same as the ticket
/// it gave, without queueing anything. Only ComfyUI and InvokeAI keep jobs
/// to be asked about later.
RemixTicket resumeRemix(String kind, String base, List<String> jobs) {
  final done = StreamController<String>();
  final results = switch (kind) {
    'comfyui' => _comfyResults(base, jobs, done),
    'invokeai' => _invokeResults(base, [for (final j in jobs) ?int.tryParse(j)], done),
    _ => throw BackendException('${backendNames[kind] ?? kind} remixes cannot be picked up again.'),
  };
  return RemixTicket('', jobs.length, results, kind: kind, base: base, jobs: jobs, finished: done.stream);
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
    if (r.key.toLowerCase() == key) return r.value;
  }
  return null;
}

/// Whether [info] carries [kind]'s own graph, to be sent back as it is
/// (changed in place) rather than one built from its settings.
bool carriesGraph(String kind, GenInfo info) => switch (kind) {
      'comfyui' => rawBlock(info, 'prompt')?.trimLeft().startsWith('{') ?? false,
      'invokeai' => rawBlock(info, 'invokeai_graph') != null,
      _ => false,
    };

/// Which backends can take [info], and why not where one cannot.
///
/// ComfyUI and InvokeAI take their own graph when the picture carries one,
/// and otherwise a graph built from its settings, so all three take any
/// picture with generation data.
Map<String, String?> backendSupport(GenInfo info) {
  const none = 'This picture has no generation data to remix.';
  return {
    'comfyui': carriesGraph('comfyui', info) || info.hasGeneration ? null : none,
    'invokeai': carriesGraph('invokeai', info) || info.hasGeneration ? null : none,
    'forge': info.hasGeneration ? null : none,
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

/// Sampling steps from the metadata, if it says.
int? recipeSteps(GenInfo info) {
  final v = param(info, ['steps'])?.trim() ?? '';
  return int.tryParse(v) ?? double.tryParse(v)?.round();
}

/// CFG scale from the metadata, if it says.
double? recipeCfg(GenInfo info) =>
    double.tryParse(param(info, ['cfg scale', 'cfg', 'cfg_scale'])?.trim() ?? '');

/// The node fields that hold sampling steps, and CFG scale, in ComfyUI's
/// and InvokeAI's graphs.
const Set<String> _stepFields = {'steps', 'num_steps'};
const Set<String> _cfgFields = {'cfg', 'cfg_scale'};

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
  return _answer(url, response);
}

/// Send [bytes] to [url] as the file [filename] in the form field [field],
/// alongside the plain [fields]: how ComfyUI and InvokeAI take pictures.
Future<Map<String, dynamic>> _upload(
  HttpClient client,
  String url, {
  required String field,
  required String filename,
  required Uint8List bytes,
  Map<String, String> fields = const {},
}) async {
  final boundary = '----generativeview${DateTime.now().microsecondsSinceEpoch}';
  final body = BytesBuilder(copy: false);
  void text(String s) => body.add(utf8.encode(s));
  for (final MapEntry(:key, :value) in fields.entries) {
    text('--$boundary\r\nContent-Disposition: form-data; name="$key"\r\n\r\n$value\r\n');
  }
  text('--$boundary\r\nContent-Disposition: form-data; name="$field"; filename="$filename"\r\n'
      'Content-Type: image/png\r\n\r\n');
  body.add(bytes);
  text('\r\n--$boundary--\r\n');
  final data = body.takeBytes();
  final request = await client.postUrl(Uri.parse(url));
  request.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
  request.contentLength = data.length;
  request.add(data);
  final response = await request.close().timeout(const Duration(minutes: 2));
  return _answer(url, response);
}

/// A server's JSON answer to a request to [url]; its message, if it says no.
Future<Map<String, dynamic>> _answer(String url, HttpClientResponse response) async {
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
/// the new ones; seeds, sizes, steps and CFG get the new values. Works on
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
  final oldSteps = recipeSteps(remix.info);
  final oldCfg = recipeCfg(remix.info);
  var found = 0;
  for (final node in nodes.values) {
    if (node is! Map<String, dynamic>) continue;
    final f = fields(node);
    for (final key in f.keys.toList()) {
      final v = f[key];
      if (v is String) {
        final n = norm(v);
        if (oldPrompt.isNotEmpty && n == oldPrompt) {
          f[key] = remix.sentPrompt;
          found++;
        } else if (oldNegative.isNotEmpty && n == oldNegative) {
          f[key] = remix.sentNegative;
        }
      } else if (v is num) {
        switch (key) {
          case 'seed' || 'noise_seed':
            f[key] = seed;
          case 'width':
            if (oldW == 0 || v == oldW) f[key] = remix.width;
          case 'height':
            if (oldH == 0 || v == oldH) f[key] = remix.height;
          // Only where it is the picture's own, so a second pass (a
          // refiner, an upscale) with settings of its own keeps them.
          case _ when _stepFields.contains(key):
            if (remix.steps != null && (oldSteps == null || v == oldSteps)) f[key] = remix.steps;
          case _ when _cfgFields.contains(key):
            if (remix.cfg != null && (oldCfg == null || (v - oldCfg).abs() < 1e-6)) f[key] = remix.cfg;
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

Future<RemixTicket> _comfy(HttpClient client, String base, Remix remix) async {
  final raw = carriesGraph('comfyui', remix.info) ? rawBlock(remix.info, 'prompt') : null;
  final random = math.Random();
  final ids = <String>[];
  final skipped = <String>[];
  // For image to image, the picture (and mask) go up first, under names
  // of their own so two remixes at once do not take each other's.
  final init = remix.init;
  String? image;
  String? mask;
  if (init != null) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    image = await _comfyUpload(client, base, init.image, 'generativeview_${stamp}_image.png');
    if (init.mask != null) {
      mask = await _comfyUpload(client, base, init.mask!, 'generativeview_${stamp}_mask.png');
    }
  }
  ComfyModels? installed;
  if (raw == null) {
    if (!remix.info.hasGeneration) throw BackendException(backendSupport(remix.info)['comfyui']!);
    final checkpoints = await _get(client, '$base/object_info/CheckpointLoaderSimple');
    final loras = remix.sentLoras.isEmpty ? const <String, dynamic>{} : await _get(client, '$base/object_info/LoraLoader');
    installed = ComfyModels(
      ComfyModels.options(checkpoints, 'CheckpointLoaderSimple', 'ckpt_name'),
      ComfyModels.options(loras, 'LoraLoader', 'lora_name'),
    );
  }
  final recipe = Recipe.from(
    remix.info,
    prompt: remix.sentPrompt,
    negative: remix.sentNegative,
    width: remix.width,
    height: remix.height,
    steps: remix.steps,
    cfg: remix.cfg,
    loras: remix.sentLoras,
  );
  for (var run = 0; run < remix.count; run++) {
    final seed = remix.seedFor(run, random);
    late final Map<String, dynamic> graph;
    if (raw != null) {
      graph = jsonDecode(raw) as Map<String, dynamic>;
      final found = _patchGraph(
        graph,
        remix,
        seed,
        fields: (node) => (node['inputs'] as Map<String, dynamic>?) ?? {},
      );
      if (run == 0) _requirePrompt(found, remix);
      if (remix.loras != null) editComfyLoras(graph, remix.loras!);
    } else {
      try {
        graph = comfyGraph(recipe, seed, installed!, skipped: run == 0 ? skipped : null);
      } on StateError catch (e) {
        throw BackendException(e.message);
      }
    }
    if (init != null) comfyImageToImage(graph, image: image!, mask: mask, strength: init.strength);
    final reply = await _post(client, '$base/prompt', {
      'prompt': graph,
      'client_id': 'generativeview',
    });
    ids.add('${reply['prompt_id'] ?? ''}');
  }
  final done = StreamController<String>();
  return RemixTicket(
    'Queued ${_count(remix.count)} in ComfyUI${_mode(remix)}${_built(raw == null, skipped)}',
    remix.count,
    _comfyResults(base, ids, done),
    kind: 'comfyui',
    base: base,
    jobs: [for (final id in ids) if (id.isNotEmpty) id],
    finished: done.stream,
  );
}

/// What to add to the "queued" line for image to image.
String _mode(Remix remix) {
  final init = remix.init;
  if (init == null) return '';
  final what = init.masked ? 'the painted area redrawn' : 'image to image';
  return ', $what at strength ${init.strength.toStringAsFixed(2)}';
}

/// Put [bytes] in ComfyUI's input folder as [name]; the name to load it by.
Future<String> _comfyUpload(HttpClient client, String base, Uint8List bytes, String name) async {
  final reply = await _upload(
    client,
    '$base/upload/image',
    field: 'image',
    filename: name,
    bytes: bytes,
    fields: const {'type': 'input', 'overwrite': 'true'},
  );
  final saved = '${reply['name'] ?? name}';
  final folder = '${reply['subfolder'] ?? ''}';
  return folder.isEmpty ? saved : '$folder/$saved';
}

/// Make a ComfyUI API graph start from the uploaded picture [image] rather
/// than an empty one: each empty latent is replaced by the picture, encoded
/// with the VAE the graph decodes with, and every sampler's denoise is set
/// to [strength]. With [mask] (uploaded, white where the picture is to be
/// redrawn), only that part is redrawn.
///
/// Works on the picture's own workflow and on a built one alike. Throws a
/// [BackendException] for a workflow it cannot do this to.
void comfyImageToImage(
  Map<String, dynamic> graph, {
  required String image,
  String? mask,
  required double strength,
}) {
  String type(Object? node) => node is Map ? '${node['class_type'] ?? ''}' : '';
  Map<String, dynamic> inputs(Object? node) =>
      node is Map<String, dynamic> ? (node['inputs'] as Map<String, dynamic>? ?? <String, dynamic>{}) : <String, dynamic>{};

  final empties = {
    for (final e in graph.entries)
      if (RegExp(r'^Empty.*Latent').hasMatch(type(e.value))) e.key,
  };
  if (empties.isEmpty) {
    throw BackendException(
      'This workflow does not start from an empty picture, so it cannot be '
      'given one to start from. Try text to image, or another server.',
    );
  }
  // The VAE the graph decodes its result with is the one to encode with.
  Object? vae;
  for (final node in graph.values) {
    if (type(node).startsWith('VAEDecode')) {
      vae = inputs(node)['vae'];
      if (vae is List) break;
    }
  }
  if (vae is! List) {
    throw BackendException('This workflow has no VAE Decode node, so the picture cannot be encoded to start from.');
  }

  var next = 1;
  for (final id in graph.keys) {
    final n = int.tryParse(id);
    if (n != null && n >= next) next = n + 1;
  }
  String add(String type, Map<String, dynamic> inputs) {
    final id = '${next++}';
    graph[id] = {'class_type': type, 'inputs': inputs};
    return id;
  }

  final load = add('LoadImage', {'image': image});
  final encode = add('VAEEncode', {'pixels': [load, 0], 'vae': List<Object?>.of(vae)});
  var latent = <Object>[encode, 0];
  if (mask != null) {
    final m = add('LoadImageMask', {'image': mask, 'channel': 'red'});
    final noise = add('SetLatentNoiseMask', {'samples': latent, 'mask': [m, 0]});
    latent = [noise, 0];
  }

  // Whatever took an empty latent takes the picture instead.
  for (final node in graph.values) {
    final f = inputs(node);
    for (final key in f.keys.toList()) {
      final v = f[key];
      if (v is List && v.length == 2 && empties.contains('${v[0]}')) f[key] = List<Object>.of(latent);
    }
  }
  for (final id in empties) {
    graph.remove(id);
  }

  // How much of it is redrawn.
  var set = 0;
  for (final node in graph.values) {
    final f = inputs(node);
    if (f['denoise'] is num) {
      f['denoise'] = strength;
      set++;
    } else if (type(node) == 'KSamplerAdvanced' && f['steps'] is num) {
      // No denoise here: it starts that far into its steps instead.
      final steps = (f['steps'] as num).toInt();
      f['start_at_step'] = ((1 - strength) * steps).round().clamp(0, steps);
      f['add_noise'] = 'enable';
      set++;
    }
  }
  if (set == 0) {
    throw BackendException(
      'This workflow\'s sampler has no denoise setting, so how much of the '
      'picture to redraw cannot be set. Try text to image, or another server.',
    );
  }
}

/// What to add to the "queued" line when a graph was built rather than the
/// picture's own sent back.
String _built(bool built, List<String> skipped) {
  if (!built) return '';
  final note = ' (a text-to-image graph made from its settings';
  if (skipped.isEmpty) return '$note)';
  final names = skipped.map((n) => modelKey(n)).join(', ');
  return '$note; without ${skipped.length == 1 ? 'the LoRA' : 'the LoRAs'} $names, which the server does not have)';
}

/// How many times a job is asked about, not yet done, before checking
/// that the server still has it at all.
const int _checkGoneEvery = 5;

/// Wait for each of the ComfyUI prompts [ids] and fetch what it saved,
/// telling [done] as each is dealt with.
Stream<RemixImage> _comfyResults(String base, List<String> ids, [StreamController<String>? done]) async* {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    for (final id in ids) {
      if (id.isEmpty) continue;
      final deadline = DateTime.now().add(remixPatience);
      Map<String, dynamic>? entry;
      var asked = 0;
      var gone = false;
      while (entry == null && !gone) {
        if (DateTime.now().isAfter(deadline)) {
          throw BackendException('ComfyUI did not finish within ${remixPatience.inHours} hours.');
        }
        await Future<void>.delayed(remixPollEvery);
        try {
          final history = await _get(client, '$base/history/$id');
          final found = history[id];
          if (found is Map<String, dynamic>) {
            entry = found;
          } else if (++asked % _checkGoneEvery == 0) {
            // Neither done nor waiting: ComfyUI was restarted, or its
            // queue cleared, since this was sent.
            gone = !await _comfyHas(client, base, id);
          }
        } on SocketException {
          // The server may be restarting: keep asking until the deadline.
        } on TimeoutException {
          // As above.
        }
      }
      if (entry == null) {
        yield* Stream.error(BackendException('ComfyUI no longer has a remix that was sent to it (it was restarted, or its queue cleared).'));
        done?.add(id);
        continue;
      }
      final status = entry['status'];
      if (status is Map && status['status_str'] == 'error') {
        yield* Stream.error(BackendException(_comfyError(status)));
        done?.add(id);
        continue;
      }
      final outputs = entry['outputs'];
      if (outputs is! Map) {
        done?.add(id);
        continue;
      }
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
      done?.add(id);
    }
  } finally {
    client.close(force: true);
    // Not waited for: with no one listening it would never finish.
    if (done != null) unawaited(done.close());
  }
}

/// Whether ComfyUI has the prompt [id] running or waiting, or has kept it
/// in its history after all. True when it cannot tell, so as not to give
/// up on a job for want of an answer.
Future<bool> _comfyHas(HttpClient client, String base, String id) async {
  try {
    final queue = await _get(client, '$base/queue');
    bool listed(Object? jobs) => jobs is List && jobs.any((j) => j is List && j.length > 1 && '${j[1]}' == id);
    if (listed(queue['queue_running']) || listed(queue['queue_pending'])) return true;
    // It may have finished between the two questions.
    final history = await _get(client, '$base/history/$id');
    return history[id] is Map;
  } catch (_) {
    return true;
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

Future<RemixTicket> _invoke(HttpClient client, String base, Remix remix) async {
  // The picture's own graph when it has one, for image to image too: it
  // names the right loaders for any kind of model (Krea 2's separate VAE
  // and text encoder, say), which a graph built from settings cannot.
  final init = remix.init;
  final raw = carriesGraph('invokeai', remix.info) ? rawBlock(remix.info, 'invokeai_graph') : null;
  final random = math.Random();
  final ids = <int>[];
  final skipped = <String>[];
  var fetchable = true;
  var mains = const <InvokeModel>[];
  var loras = const <InvokeModel>[];
  var vaes = const <InvokeModel>[];
  var encoders = const <InvokeModel>[];
  if (raw == null) {
    if (!remix.info.hasGeneration) throw BackendException(backendSupport(remix.info)['invokeai']!);
    List<InvokeModel> listed(Map<String, dynamic> reply) => [
          for (final m in (reply['models'] as List? ?? const []))
            if (m is Map<String, dynamic>) InvokeModel.fromJson(m),
        ];
    mains = listed(await _get(client, '$base/api/v2/models/?model_type=main'));
    if (remix.sentLoras.isNotEmpty) {
      loras = listed(await _get(client, '$base/api/v2/models/?model_type=lora'));
    }
    // A single-file Krea 2 model needs its VAE and text encoder chosen.
    final main = findModel(remix.info.model, mains, (m) => m.names);
    if (main != null && krea2NeedsParts(main)) {
      Future<List<InvokeModel>> some(String type) async {
        try {
          return listed(await _get(client, '$base/api/v2/models/?model_type=$type'));
        } on BackendException {
          return const [];
        }
      }

      vaes = await some('vae');
      encoders = await some('qwen3_vl_encoder');
    }
  }
  GraphInit? start;
  if (init != null) {
    start = GraphInit(
      image: await _invokeUpload(client, base, init.image),
      mask: init.keepMask == null ? null : await _invokeUpload(client, base, init.keepMask!),
      strength: init.strength,
    );
  }
  final recipe = Recipe.from(
    remix.info,
    prompt: remix.sentPrompt,
    negative: remix.sentNegative,
    width: remix.width,
    height: remix.height,
    steps: remix.steps,
    cfg: remix.cfg,
    loras: remix.sentLoras,
  );
  for (var run = 0; run < remix.count; run++) {
    final seed = remix.seedFor(run, random);
    late final Map<String, dynamic> graph;
    if (raw != null) {
      graph = jsonDecode(raw) as Map<String, dynamic>;
      final nodes = (graph['nodes'] as Map<String, dynamic>?) ?? {};
      final found = _patchGraph(nodes, remix, seed, fields: (node) => node);
      invokeSeed(graph, seed);
      if (remix.steps case final steps?) invokeSetting(graph, _stepFields, steps, old: recipeSteps(remix.info));
      if (remix.cfg case final cfg?) invokeSetting(graph, _cfgFields, cfg, old: recipeCfg(remix.info));
      if (run == 0) _requirePrompt(found, remix);
      if (remix.loras != null) editInvokeLoras(graph, remix.loras!);
      if (start != null) invokeImageToImage(graph, image: start.image, keepMask: start.mask, strength: start.strength);
    } else {
      try {
        graph = invokeGraph(
          recipe,
          seed,
          mains,
          loras,
          skipped: run == 0 ? skipped : null,
          init: start,
          vaes: vaes,
          encoders: encoders,
        );
      } on StateError catch (e) {
        throw BackendException(e.message);
      }
    }
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
  final done = StreamController<String>();
  return RemixTicket(
    'Queued ${_count(remix.count)} in InvokeAI${_mode(remix)}${_built(raw == null, skipped)}',
    remix.count,
    kind: 'invokeai',
    base: base,
    jobs: fetchable ? [for (final id in ids) '$id'] : const [],
    finished: done.stream,
    fetchable
        ? _invokeResults(base, ids, done)
        : Stream.error(BackendException(
            'This InvokeAI does not say which queue items it made, so the '
            'pictures stay in its gallery. Updating InvokeAI fixes this.',
          )),
  );
}

/// The seed inputs of InvokeAI nodes.
const Set<String> _seedFields = {'seed', 'noise_seed', 'variance_seed'};

/// Give an InvokeAI graph [seed] wherever it takes one. InvokeAI's own
/// graphs (InvokeAI 4 and later, and 7's new canvas) keep the seed in an
/// `integer` node of its own, whose value is wired into the denoise or
/// noise step, the metadata and the like; a value wired in wins over the
/// field's own, so that node is the one to change. A seed wired from
/// anything else (a random-number node) is cut off and set directly.
void invokeSeed(Map<String, dynamic> graph, int seed) {
  final nodes = graph['nodes'];
  final edges = graph['edges'];
  if (nodes is! Map || edges is! List) return;
  final cut = <Object?>[];
  for (final e in edges) {
    if (e is! Map) continue;
    final from = e['source'];
    final to = e['destination'];
    if (from is! Map || to is! Map || !_seedFields.contains(to['field'])) continue;
    final source = nodes[from['node_id']];
    if (source is Map && source['type'] == 'integer' && from['field'] == 'value') {
      source['value'] = seed;
    } else {
      cut.add(e);
      final target = nodes[to['node_id']];
      if (target is Map) target[to['field']] = seed;
    }
  }
  edges.removeWhere(cut.contains);
}

/// Give an InvokeAI graph [value] where one of [fields] is wired in from an
/// `integer` or `float` node holding the picture's own value [old] (or
/// any, when [old] is not known): that node's value is what counts, as with
/// [invokeSeed]. Fields set directly are left to [_patchGraph].
void invokeSetting(Map<String, dynamic> graph, Set<String> fields, num value, {num? old}) {
  final nodes = graph['nodes'];
  final edges = graph['edges'];
  if (nodes is! Map || edges is! List) return;
  for (final e in edges) {
    if (e is! Map) continue;
    final from = e['source'];
    final to = e['destination'];
    if (from is! Map || to is! Map || !fields.contains(to['field'])) continue;
    final source = nodes[from['node_id']];
    if (source is! Map || from['field'] != 'value') continue;
    if (source['type'] != 'integer' && source['type'] != 'float') continue;
    final v = source['value'];
    if (old != null && v is num && (v - old).abs() > 1e-6) continue;
    source['value'] = source['type'] == 'integer' ? value.round() : value.toDouble();
  }
}

/// Make an InvokeAI graph (the picture's own, as InvokeAI saved it) start
/// from the uploaded picture [image]: the picture is encoded by the
/// image-to-latents node that matches the graph's latents-to-image node
/// (`i2l` for `l2i`, `qwen_image_i2l` for Krea 2's `qwen_image_l2i`,
/// `flux_vae_encode` for `flux_vae_decode`, and so on) with the same VAE,
/// and fed to the denoise node, which starts [strength] of the way from the
/// end. With [keepMask] (uploaded, white where the picture is kept), only
/// the rest is redrawn. How InvokeAI's own canvas does it, for any model.
///
/// Throws a [BackendException] for a graph it cannot do this to.
void invokeImageToImage(
  Map<String, dynamic> graph, {
  required String image,
  String? keepMask,
  required double strength,
}) {
  final nodes = graph['nodes'];
  final edges = graph['edges'];
  if (nodes is! Map<String, dynamic> || edges is! List) {
    throw BackendException('This picture\'s InvokeAI graph is not one this app can read.');
  }
  String type(String id) => '${(nodes[id] as Map?)?['type'] ?? ''}';
  Map<String, dynamic>? into(String node, String field) {
    for (final e in edges) {
      if (e is Map<String, dynamic> && (e['destination'] as Map?)?['node_id'] == node && (e['destination'] as Map?)?['field'] == field) {
        return e;
      }
    }
    return null;
  }

  // The node that makes the picture: the one kept, if there are several.
  final decoders = [
    for (final MapEntry(:key, :value) in nodes.entries)
      if (RegExp(r'(^|_)l2i$|_vae_decode$').hasMatch(type(key)) && value is Map) key,
  ];
  if (decoders.isEmpty) {
    throw BackendException('This InvokeAI graph has no latents-to-image node, so it cannot be started from a picture.');
  }
  final decode = decoders.firstWhere((id) => (nodes[id] as Map)['is_intermediate'] == false, orElse: () => decoders.last);
  final encodeType = type(decode).endsWith('l2i')
      ? '${type(decode).substring(0, type(decode).length - 3)}i2l'
      : type(decode).replaceFirst(RegExp(r'_vae_decode$'), '_vae_encode');

  final vae = into(decode, 'vae')?['source'] as Map?;
  final latents = into(decode, 'latents')?['source'] as Map?;
  final denoise = latents?['node_id'] as String?;
  if (vae == null || denoise == null || !type(denoise).contains('denoise')) {
    throw BackendException('This InvokeAI graph does not decode straight from its denoise step, so it cannot be started from a picture.');
  }

  // Replace whatever the denoise step started from before, and its mask.
  edges.removeWhere((e) {
    final d = e is Map ? e['destination'] as Map? : null;
    return d?['node_id'] == denoise && (d?['field'] == 'latents' || d?['field'] == 'denoise_mask');
  });
  void node(String id, Map<String, dynamic> fields) =>
      nodes[id] = {'id': id, 'is_intermediate': true, 'use_cache': false, ...fields};
  void edge(Object? from, String out, String to, String field) => edges.add({
        'source': {'node_id': from, 'field': out},
        'destination': {'node_id': to, 'field': field},
      });

  node('generativeview_i2l', {'type': encodeType, 'image': {'image_name': image}});
  edge(vae['node_id'], '${vae['field']}', 'generativeview_i2l', 'vae');
  edge('generativeview_i2l', 'latents', denoise, 'latents');
  if (keepMask != null) {
    node('generativeview_mask', {'type': 'create_denoise_mask', 'mask': {'image_name': keepMask}});
    edge(vae['node_id'], '${vae['field']}', 'generativeview_mask', 'vae');
    edge('generativeview_mask', 'denoise_mask', denoise, 'denoise_mask');
  }
  final step = nodes[denoise] as Map<String, dynamic>;
  step['denoising_start'] = 1 - strength.clamp(0.0, 1.0);
  step['denoising_end'] ??= 1.0;
}

/// Put [bytes] among InvokeAI's images, out of sight in its gallery; the
/// name to use it by.
Future<String> _invokeUpload(HttpClient client, String base, Uint8List bytes) async {
  final reply = await _upload(
    client,
    '$base/api/v1/images/upload?image_category=general&is_intermediate=true',
    field: 'file',
    filename: 'generativeview.png',
    bytes: bytes,
  );
  final name = reply['image_name'];
  if (name is! String || name.isEmpty) {
    throw BackendException('InvokeAI took the picture but did not say what it called it.');
  }
  return name;
}

/// Wait for each of the InvokeAI queue items [ids] and fetch the pictures
/// it kept (not its intermediate steps), telling [done] as each is dealt
/// with.
Stream<RemixImage> _invokeResults(String base, List<int> ids, [StreamController<String>? done]) async* {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final api = '$base/api/v1';
  try {
    for (final id in ids) {
      final deadline = DateTime.now().add(remixPatience);
      Map<String, dynamic>? item;
      var gone = false;
      while (item == null && !gone) {
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
        } on BackendException catch (e) {
          // Asked for one it does not have (its queue was cleared), or
          // some other refusal: no use asking again.
          if (e.message.contains(' 404')) {
            gone = true;
          } else {
            rethrow;
          }
        }
      }
      if (item == null) {
        yield* Stream.error(BackendException('InvokeAI no longer has a remix that was sent to it (its queue was cleared).'));
        done?.add('$id');
        continue;
      }
      switch (item['status']) {
        case 'canceled':
          yield* Stream.error(BackendException('A remix was cancelled in InvokeAI.'));
          done?.add('$id');
          continue;
        case 'failed':
          final why = item['error_message'] ?? item['error_type'] ?? item['error'];
          yield* Stream.error(BackendException(
            why == null ? 'InvokeAI could not run the graph.' : 'InvokeAI: ${'$why'.trim().split('\n').first}',
          ));
          done?.add('$id');
          continue;
      }
      final session = item['session'];
      final results = session is Map ? session['results'] : null;
      if (results is! Map) {
        done?.add('$id');
        continue;
      }
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
      done?.add('$id');
    }
  } finally {
    client.close(force: true);
    // Not waited for: with no one listening it would never finish.
    if (done != null) unawaited(done.close());
  }
}

Future<RemixTicket> _forge(HttpClient client, String base, Remix remix) async {
  final info = remix.info;
  double? number(List<String> names) => double.tryParse(param(info, names) ?? '');
  final sampler = param(info, ['sampler', 'sampler_name']);
  final scheduler = param(info, ['schedule type', 'scheduler']);
  // Forge loads only the LoRAs its prompt names, so those left on that the
  // prompt does not name are named in it.
  final loras = remix.loras;
  final payload = <String, Object?>{
    'prompt': loras == null ? remix.prompt : retagPrompt(remix.prompt, loras, addTo: info.prompt),
    'negative_prompt': remix.sentNegative,
    'seed': remix.randomSeed ? -1 : remix.seed,
    'n_iter': remix.count,
    'batch_size': 1,
    'width': remix.width,
    'height': remix.height,
    'steps': ?(remix.steps ?? number(['steps'])?.round()),
    'cfg_scale': ?(remix.cfg ?? number(['cfg scale', 'cfg'])),
    'sampler_name': ?sampler,
    'scheduler': ?scheduler,
    'save_images': true,
    'send_images': true,
    if (info.model.isNotEmpty)
      'override_settings': {'sd_model_checkpoint': info.model},
    // Image to image: the picture, how much of it to redraw, and where
    // (white in the mask), the rest left as it was.
    if (remix.init case final init?) ...{
      'init_images': [base64Encode(init.image)],
      'denoising_strength': init.strength,
      'resize_mode': 0,
      if (init.mask != null) ...{
        'mask': base64Encode(init.mask!),
        'mask_blur': 4,
        'inpainting_fill': 1,
        'inpaint_full_res': false,
        'inpainting_mask_invert': 0,
      },
    },
  };
  final endpoint = remix.init == null ? 'txt2img' : 'img2img';
  // Forge answers when the pictures are done, with them in the answer.
  // That can take a while, so only wait long enough to know it started; the
  // rest is waited for in the background. Its own client, since the one
  // passed in is closed as soon as this returns.
  final own = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final pending = _post(own, '$base/sdapi/v1/$endpoint', payload, timeout: remixPatience)
      .whenComplete(() => own.close(force: true));
  // Read by the stream below, or (if this throws first) not at all.
  pending.ignore();
  try {
    await pending.timeout(const Duration(seconds: 4));
  } on TimeoutException {
    // Still working on it: queued.
  }
  return RemixTicket(
    'Sent ${_count(remix.count)} to Forge / A1111${_mode(remix)}',
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
