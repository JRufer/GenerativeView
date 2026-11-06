/// The LoRAs on the remix server, and which kind of model (family) each was
/// made for, so the remix panel can offer only those that fit the model it
/// will render with.
///
/// Families are named as InvokeAI names its bases (`sd-1`, `sdxl`, `flux`,
/// `krea-2`...). InvokeAI says each model's base itself; for ComfyUI and
/// Forge it is read from the file's own safetensors metadata
/// (`modelspec.architecture`, kohya's `ss_base_model_version`), and failing
/// that from its file or folder name.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backends.dart' show serverModels;
import 'models.dart';
import 'recipe_graphs.dart';

/// A model on the server: its name as the server names it, and its family
/// when known.
class ServerModel {
  const ServerModel(this.name, [this.family]);
  final String name;
  final String? family;

  /// The file's [name] as matched everywhere: no folder, extension or case.
  String get key => modelKey(name);

  @override
  String toString() => 'ServerModel($name, $family)';
}

/// What people call each family.
const Map<String, String> familyNames = {
  'sd-1': 'SD 1.x',
  'sd-2': 'SD 2.x',
  'sdxl': 'SDXL',
  'sdxl-refiner': 'SDXL Refiner',
  'sd-3': 'SD 3',
  'flux': 'FLUX.1',
  'flux2': 'FLUX.2',
  'krea-2': 'Krea 2',
  'chroma': 'Chroma',
  'qwen-image': 'Qwen Image',
  'z-image': 'Z-Image',
  'cogview4': 'CogView 4',
};

/// [family] as people call it.
String familyLabel(String family) => familyNames[family] ?? family;

final RegExp _krea2 = RegExp(r'krea[\s_.-]?2', caseSensitive: false);

/// The family named by an architecture or base-model string from a model
/// file's metadata (`stable-diffusion-xl-v1-base/lora`, `sdxl_base_v1-0`,
/// `flux-1-dev/lora`, `sd_v1`...); null if it names none known.
String? familyFromArchitecture(String text) {
  final s = text.toLowerCase().trim();
  if (s.isEmpty) return null;
  if (_krea2.hasMatch(s)) return 'krea-2';
  if (s.contains('refiner')) return 'sdxl-refiner';
  if (s.contains('stable-diffusion-xl') || s.startsWith('sdxl') || s.contains('sd_xl') || s.contains('sd-xl')) return 'sdxl';
  if (s.contains('stable-diffusion-v3') || s.contains('stable-diffusion-3') || RegExp(r'^sd[_-]?3').hasMatch(s)) return 'sd-3';
  if (RegExp(r'flux[\s._-]?2').hasMatch(s)) return 'flux2';
  if (s.contains('flux')) return 'flux';
  if (s.contains('chroma')) return 'chroma';
  if (RegExp(r'qwen[\s._-]?image').hasMatch(s)) return 'qwen-image';
  if (RegExp(r'z[\s._-]?image').hasMatch(s)) return 'z-image';
  if (s.contains('cogview')) return 'cogview4';
  if (s.contains('stable-diffusion-v2') || RegExp(r'^sd[_-]?v?2').hasMatch(s)) return 'sd-2';
  if (s.contains('stable-diffusion-v1') || RegExp(r'^sd[_-]?v?1').hasMatch(s)) return 'sd-1';
  return null;
}

/// The family a model file's safetensors [metadata] says it is for; null
/// when it does not say.
String? familyFromMetadata(Map<String, dynamic> metadata) {
  String text(String key) => '${metadata[key] ?? ''}';
  for (final key in const ['modelspec.architecture', 'ss_base_model_version']) {
    final found = familyFromArchitecture(text(key));
    if (found != null) return found;
  }
  // Older kohya trainers, which only made SD 1.x and 2.x LoRAs, wrote no
  // base model version, only whether it was SD 2.
  if (metadata.containsKey('ss_network_module') && !metadata.containsKey('ss_base_model_version')) {
    final v2 = text('ss_v2').toLowerCase();
    if (v2 == 'true') return 'sd-2';
    if (v2 == 'false') return 'sd-1';
  }
  // Krea 2's files are named for it wherever their metadata mentions it.
  if (metadata.values.any((v) => v is String && _krea2.hasMatch(v))) return 'krea-2';
  return null;
}

/// The family a model's file or folder [name] makes plain (`SDXL/…`,
/// `…_flux_lora`, `pony…`); null when it does not.
String? familyFromName(String name) {
  final s = name
      .toLowerCase()
      .replaceFirst(RegExp(r'\s*\[[0-9a-f]+\]$'), '')
      .replaceFirst(RegExp(r'\.(safetensors|ckpt|pt|pth|bin|gguf|sft)$'), '');
  if (_krea2.hasMatch(s)) return 'krea-2';
  final words = s.split(RegExp(r'[^a-z0-9.]+')).where((w) => w.isNotEmpty).toSet();
  bool any(Iterable<String> ws) => ws.any(words.contains);
  bool starts(Iterable<String> ps) => words.any((w) => ps.any(w.startsWith));
  if (RegExp(r'sd[\s_.-]?3(\.5)?(?![0-9])').hasMatch(s)) return 'sd-3';
  if (RegExp(r'flux[\s_.-]?2(?![0-9])').hasMatch(s)) return 'flux2';
  if (s.contains('flux')) return 'flux';
  if (s.contains('chroma')) return 'chroma';
  if (RegExp(r'qwen[\s_.-]?image').hasMatch(s)) return 'qwen-image';
  if (RegExp(r'z[\s_.-]image').hasMatch(s)) return 'z-image';
  if (s.contains('refiner')) return 'sdxl-refiner';
  if (s.contains('sdxl') ||
      s.contains('sd_xl') ||
      any(const ['xl', 'pony', 'illustrious', 'noobai', 'noob']) ||
      words.any((w) => w.endsWith('xl')) ||
      starts(const ['pony', 'illustrious', 'noobai'])) {
    return 'sdxl';
  }
  if (RegExp(r'sd[\s_.-]?(1\.?5|v1|15)(?![0-9])').hasMatch(s)) return 'sd-1';
  if (RegExp(r'sd[\s_.-]?(2\.?1|2\.?0|v2|21|20)(?![0-9])').hasMatch(s)) return 'sd-2';
  return null;
}

/// The family [info] was made with, as far as the picture itself says: its
/// InvokeAI metadata's base, what [pictureFamily] makes of its names, or its
/// model's name.
String? recordedFamily(GenInfo info) {
  for (final key in const ['invokeai_metadata', 'invokeai_graph']) {
    final raw = info.raw.where((r) => r.key.toLowerCase() == key).firstOrNull?.value;
    if (raw == null) continue;
    try {
      final base = _findBase(jsonDecode(raw), 0);
      if (base != null) return base;
    } on FormatException {
      // Not JSON: nothing to read.
    }
  }
  return pictureFamily(info) ?? familyFromName(info.model);
}

/// The `base` of the first main model named in InvokeAI metadata [j].
String? _findBase(Object? j, int depth) {
  if (depth > 6) return null;
  if (j is Map) {
    final model = j['model'];
    if (model is Map && model['base'] is String && (model['type'] == null || model['type'] == 'main')) {
      final base = model['base'] as String;
      if (base.isNotEmpty && base != 'any') return base;
    }
    for (final v in j.values) {
      final found = _findBase(v, depth + 1);
      if (found != null) return found;
    }
  } else if (j is List) {
    for (final v in j) {
      final found = _findBase(v, depth + 1);
      if (found != null) return found;
    }
  }
  return null;
}

/// What each ComfyUI server's files' metadata said, by server and file, so a
/// file is only asked about once while the app is open.
final Map<String, String?> _comfyFamilies = {};

/// The family ComfyUI's [file] in [folder] (`loras`, `checkpoints`,
/// `diffusion_models`) is for, from its metadata; null when it does not say.
Future<String?> _comfyFamily(HttpClient client, String base, String folder, String file) async {
  final key = '$base|$folder|$file';
  if (_comfyFamilies.containsKey(key)) return _comfyFamilies[key];
  String? found;
  try {
    final uri = Uri.parse('$base/view_metadata/$folder').replace(queryParameters: {'filename': file});
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 300) {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) found = familyFromMetadata(decoded);
    }
  } on Object {
    // No metadata to be had: the name is all there is to go by.
  }
  _comfyFamilies[key] = found;
  return found;
}

/// [action] over each of [items], no more than [width] at a time.
Future<List<R>> _eachLimited<T, R>(List<T> items, int width, Future<R> Function(T) action) async {
  final out = List<R?>.filled(items.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      final i = next++;
      out[i] = await action(items[i]);
    }
  }

  await Future.wait([for (var w = 0; w < width; w++) worker()]);
  return out.cast<R>();
}

Future<Object?> _getJson(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close().timeout(const Duration(seconds: 10));
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode >= 300) throw HttpException('$url answered ${response.statusCode}.');
  return jsonDecode(body);
}

/// The LoRAs the server [kind] at [base] has, each with its family when it
/// can be told.
Future<List<ServerModel>> serverLoras(String kind, String base) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    switch (kind) {
      case 'invokeai':
        final reply = await _getJson(client, '$base/api/v2/models/?model_type=lora');
        return [
          for (final m in ((reply is Map ? reply['models'] : null) as List? ?? const []))
            if (m is Map<String, dynamic>)
              () {
                final model = InvokeModel.fromJson(m);
                return ServerModel(model.name, model.base.isEmpty || model.base == 'any' ? null : model.base);
              }(),
        ];
      case 'comfyui':
        final reply = await _getJson(client, '$base/object_info/LoraLoader');
        final files = ComfyModels.options(reply is Map<String, dynamic> ? reply : const {}, 'LoraLoader', 'lora_name');
        final families = await _eachLimited(files, 6, (f) async => await _comfyFamily(client, base, 'loras', f) ?? familyFromName(f));
        return [for (var i = 0; i < files.length; i++) ServerModel(files[i], families[i])];
      default:
        final reply = await _getJson(client, '$base/sdapi/v1/loras');
        return [
          for (final l in (reply is List ? reply : const []))
            if (l is Map<String, dynamic>)
              () {
                final name = '${l['name'] ?? l['alias'] ?? ''}';
                final meta = l['metadata'];
                final family = (meta is Map<String, dynamic> ? familyFromMetadata(meta) : null) ??
                    familyFromName('${l['path'] ?? ''} $name');
                return ServerModel(name, family);
              }(),
        ];
    }
  } finally {
    client.close(force: true);
  }
}

/// The main models the server [kind] at [base] has, with their families
/// where the listing says (InvokeAI); [modelFamily] finds the rest.
Future<List<ServerModel>> serverMainModels(String kind, String base) async {
  if (kind != 'invokeai') return [for (final n in await serverModels(kind, base)) ServerModel(n)];
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final reply = await _getJson(client, '$base/api/v2/models/?model_type=main');
    return [
      for (final m in ((reply is Map ? reply['models'] : null) as List? ?? const []))
        if (m is Map<String, dynamic>)
          () {
            final model = InvokeModel.fromJson(m);
            return ServerModel(model.name, model.base.isEmpty || model.base == 'any' ? null : model.base);
          }(),
    ];
  } finally {
    client.close(force: true);
  }
}

/// The family of [model] on the server [kind] at [base]: as the listing
/// said, else (ComfyUI) its file's metadata, else its name.
Future<String?> modelFamily(String kind, String base, ServerModel model) async {
  if (model.family != null) return model.family;
  if (kind == 'comfyui') {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      for (final folder in const ['checkpoints', 'diffusion_models']) {
        final found = await _comfyFamily(client, base, folder, model.name);
        if (found != null) return found;
      }
    } finally {
      client.close(force: true);
    }
  }
  return familyFromName(model.name);
}

/// The family the picture's own model is, when it is sent as the picture
/// had it: what the server says of the model it has under that name, else
/// what the picture records, else the family of the picture's LoRAs on the
/// server (they worked with it, so it is theirs).
Future<String?> pictureModelFamily(
  String kind,
  String base,
  GenInfo info,
  List<ServerModel> mains,
  Future<List<ServerModel>> Function() loras,
) async {
  final own = findModel(info.model, mains, (m) => [m.name]);
  if (own != null) {
    final found = await modelFamily(kind, base, own);
    if (found != null) return found;
  }
  final recorded = recordedFamily(info);
  if (recorded != null) return recorded;
  if (info.loras.isEmpty) return null;
  final installed = await loras();
  final kin = {
    for (final l in info.loras) findModel(l.name, installed, (m) => [m.name])?.family,
  }..remove(null);
  return kin.length == 1 ? kin.single : null;
}

/// Which of [loras] fit a model of [family], and which cannot be told.
/// With [family] unknown, every LoRA is one that cannot be told.
({List<ServerModel> fitting, List<ServerModel> unknown, int other}) sortLoras(List<ServerModel> loras, String? family) {
  final fitting = <ServerModel>[];
  final unknown = <ServerModel>[];
  var other = 0;
  for (final l in loras) {
    if (family == null || l.family == null) {
      unknown.add(l);
    } else if (l.family == family) {
      fitting.add(l);
    } else {
      other++;
    }
  }
  int byName(ServerModel a, ServerModel b) => a.key.compareTo(b.key);
  fitting.sort(byName);
  unknown.sort(byName);
  return (fitting: fitting, unknown: unknown, other: other);
}
