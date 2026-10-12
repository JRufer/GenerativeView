/// Looking up a model or LoRA on Civitai: what it is, what it was trained
/// on, and the words that trigger it.
///
/// Only when asked, and only the model's hash or name is sent. A hash (the
/// short one A1111 and Forge save, or a full SHA-256) finds the exact file;
/// a name is searched for and matched against the files listed.
library;

import 'dart:convert';
import 'dart:io';

class CivitaiModel {
  const CivitaiModel({
    required this.modelId,
    required this.versionId,
    required this.name,
    required this.version,
    required this.type,
    required this.baseModel,
    required this.trainedWords,
    required this.creator,
    required this.preview,
    required this.matchedBy,
  });

  final int modelId;
  final int versionId;
  final String name;
  final String version;

  /// Checkpoint, LORA, LoCon, TextualInversion...
  final String type;

  /// SDXL 1.0, Flux.1 D, SD 1.5...
  final String baseModel;
  final List<String> trainedWords;
  final String creator;

  /// A picture made with it that is safe to show, if there is one.
  final String? preview;

  /// "hash" (the very file) or "name" (the best match by name).
  final String matchedBy;

  String get url => 'https://civitai.com/models/$modelId?modelVersionId=$versionId';
}

class CivitaiException implements Exception {
  CivitaiException(this.message);
  final String message;
  @override
  String toString() => message;
}

final Map<String, CivitaiModel?> _cache = {};

const String _api = 'https://civitai.com/api/v1';

/// The model with [hash] or, failing that, the one whose file is called
/// [name]. Null if Civitai knows neither.
Future<CivitaiModel?> lookUpModel({required String name, String hash = '', String kind = ''}) async {
  final key = '$hash|$name';
  if (_cache.containsKey(key)) return _cache[key];
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = 'GenerativeView';
  try {
    CivitaiModel? found;
    final h = hash.trim().replaceFirst(RegExp(r'^[a-z0-9]+:'), '');
    if (RegExp(r'^[0-9a-fA-F]{8,64}$').hasMatch(h)) {
      final version = await _get(client, '$_api/model-versions/by-hash/$h');
      if (version != null) found = _fromVersion(version, 'hash');
    }
    found ??= await _byName(client, name, kind);
    _cache[key] = found;
    return found;
  } on SocketException catch (e) {
    throw CivitaiException('Could not reach civitai.com (${e.message}).');
  } on HandshakeException {
    throw CivitaiException('Could not make a secure connection to civitai.com.');
  } finally {
    client.close(force: true);
  }
}

/// The file name without folders and extension: what Civitai lists.
String modelStem(String name) {
  var stem = name.split(RegExp(r'[/\\]')).last;
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  return stem;
}

Future<CivitaiModel?> _byName(HttpClient client, String name, String kind) async {
  final stem = modelStem(name);
  if (stem.isEmpty) return null;
  final types = switch (kind) {
    'lora' => '&types=LORA&types=LoCon&types=DoRA',
    'checkpoint' || 'model' || 'unet' => '&types=Checkpoint',
    _ => '',
  };
  final query = stem.replaceAll(RegExp(r'[_\-.]+'), ' ');
  final list = await _get(client, '$_api/models?limit=10&query=${Uri.encodeQueryComponent(query)}$types');
  final items = (list?['items'] as List?) ?? const [];
  String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final want = norm(stem);
  // The version that has a file of exactly this name, if any.
  for (final item in items) {
    if (item is! Map<String, dynamic>) continue;
    for (final version in (item['modelVersions'] as List? ?? const [])) {
      if (version is! Map<String, dynamic>) continue;
      for (final file in (version['files'] as List? ?? const [])) {
        if (file is Map && norm(modelStem('${file['name']}')) == want) {
          return _fromVersion({...version, 'model': item}, 'name');
        }
      }
    }
  }
  return null;
}

Future<Map<String, dynamic>?> _get(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close().timeout(const Duration(seconds: 20));
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode == HttpStatus.notFound) return null;
  if (response.statusCode >= 300) {
    throw CivitaiException('civitai.com answered ${response.statusCode}.');
  }
  final decoded = jsonDecode(body);
  return decoded is Map<String, dynamic> ? decoded : null;
}

CivitaiModel _fromVersion(Map<String, dynamic> v, String matchedBy) {
  final model = (v['model'] as Map?) ?? const {};
  String? preview;
  for (final image in (v['images'] as List? ?? const [])) {
    if (image is! Map) continue;
    final level = (image['nsfwLevel'] as num?)?.toInt() ?? 1;
    final nsfw = image['nsfw'];
    final safe = level <= 1 && (nsfw == null || nsfw == false || nsfw == 'None');
    if (safe && image['type'] != 'video' && image['url'] is String) {
      preview = image['url'] as String;
      break;
    }
  }
  return CivitaiModel(
    modelId: ((v['modelId'] ?? model['id']) as num?)?.toInt() ?? 0,
    versionId: (v['id'] as num?)?.toInt() ?? 0,
    name: '${model['name'] ?? v['name'] ?? ''}',
    version: '${v['name'] ?? ''}',
    type: '${model['type'] ?? ''}',
    baseModel: '${v['baseModel'] ?? ''}',
    trainedWords: [
      for (final w in (v['trainedWords'] as List? ?? const []))
        if (w is String && w.trim().isNotEmpty) w.trim(),
    ],
    creator: '${(model['creator'] as Map?)?['username'] ?? ''}',
    preview: preview,
    matchedBy: matchedBy,
  );
}
