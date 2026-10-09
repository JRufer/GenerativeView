import 'dart:convert';
import 'dart:typed_data';

/// One image or video in the current view.
class MediaItem {
  const MediaItem({
    required this.id,
    required this.dir,
    required this.name,
    required this.isVideo,
    required this.width,
    required this.height,
    required this.mtime,
    required this.size,
    required this.durationMs,
  });

  final int id;
  final String dir;
  final String name;
  final bool isVideo;
  final int width;
  final int height;

  /// Modification time, milliseconds since the epoch.
  final int mtime;
  final int size;
  final int durationMs;

  String get path => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  /// Changes whenever the file's contents may have.
  String get version => '$id/$mtime/$size';

  double get aspect => (width > 0 && height > 0) ? width / height : 1.0;
}

/// The result of a folder query. Wraps the core's packed buffer and decodes
/// rows on demand, so receiving ten thousand items costs nothing up front.
class ItemList {
  ItemList._(this._data, this.length, this._dirs, this._strings)
    : _cache = List<MediaItem?>.filled(length, null);

  static const int _header = 16;
  static const int _row = 48;

  final ByteData _data;
  final int length;
  final List<String> _dirs;
  final int _strings;
  final List<MediaItem?> _cache;

  static final ItemList empty = ItemList.parse(
    Uint8List.fromList(const [
      0x47,
      0x56,
      0x51,
      0x31,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]),
  );

  factory ItemList.parse(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    if (bytes.length < _header || d.getUint32(0, Endian.little) != 0x31515647) {
      throw const FormatException('not a packed query result');
    }
    final rows = d.getUint32(4, Endian.little);
    final dirCount = d.getUint32(8, Endian.little);
    final dirTable = _header + rows * _row;
    final strings = dirTable + dirCount * 8;
    final dirs = List<String>.generate(dirCount, (i) {
      final off = d.getUint32(dirTable + i * 8, Endian.little);
      final len = d.getUint32(dirTable + i * 8 + 4, Endian.little);
      return utf8.decode(
        Uint8List.sublistView(bytes, strings + off, strings + off + len),
      );
    }, growable: false);
    return ItemList._(d, rows, dirs, strings);
  }

  bool get isEmpty => length == 0;
  bool get isNotEmpty => length != 0;

  int idAt(int index) => _data.getInt64(_header + index * _row, Endian.little);

  /// Position of the item with this id, or -1.
  int indexOfId(int id) {
    for (var i = 0; i < length; i++) {
      if (idAt(i) == id) return i;
    }
    return -1;
  }

  MediaItem operator [](int index) {
    final cached = _cache[index];
    if (cached != null) return cached;
    final o = _header + index * _row;
    final nameOff = _data.getUint32(o + 36, Endian.little);
    final nameLen = _data.getUint16(o + 40, Endian.little);
    final start = _data.offsetInBytes + _strings + nameOff;
    final item = MediaItem(
      id: _data.getInt64(o, Endian.little),
      mtime: _data.getInt64(o + 8, Endian.little),
      size: _data.getInt64(o + 16, Endian.little),
      width: _data.getUint32(o + 24, Endian.little),
      height: _data.getUint32(o + 28, Endian.little),
      durationMs: _data.getUint32(o + 32, Endian.little),
      name: utf8.decode(Uint8List.view(_data.buffer, start, nameLen)),
      isVideo: _data.getUint8(o + 42) == 1,
      dir: _dirs[_data.getUint32(o + 44, Endian.little)],
    );
    _cache[index] = item;
    return item;
  }
}

class ModelRef {
  const ModelRef(this.kind, this.name, this.hash);
  final String kind;
  final String name;
  final String hash;
}

class LoraRef {
  const LoraRef(this.name, this.weight, this.weightClip, this.hash);
  final String name;
  final double? weight;
  final double? weightClip;
  final String hash;

  /// `<lora:name:weight>`, ready to paste into a prompt box.
  String get tag {
    var stem = name.split(RegExp(r'[/\\]')).last;
    final dot = stem.lastIndexOf('.');
    if (dot > 0) stem = stem.substring(0, dot);
    return '<lora:$stem:${formatNumber(weight ?? 1)}>';
  }
}

class GraphNode {
  const GraphNode(this.id, this.type, this.title, this.inputs);
  final String id;
  final String type;
  final String title;
  final List<MapEntry<String, String>> inputs;
}

String formatNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  var s = v.toStringAsFixed(4);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
}

List<MapEntry<String, String>> _pairs(Object? raw) {
  if (raw is! List) return const [];
  final out = <MapEntry<String, String>>[];
  for (final p in raw) {
    if (p is List && p.length == 2) {
      out.add(MapEntry(p[0].toString(), p[1].toString()));
    }
  }
  return out;
}

/// Generation metadata for one file, as parsed by the core.
class GenInfo {
  GenInfo({
    required this.source,
    required this.prompt,
    required this.negative,
    required this.seed,
    required this.model,
    required this.models,
    required this.loras,
    required this.params,
    required this.nodes,
    required this.raw,
    required this.width,
    required this.height,
    required this.durationMs,
  });

  final String source;
  final String prompt;
  final String negative;
  final String seed;
  final String model;
  final List<ModelRef> models;
  final List<LoraRef> loras;
  final List<MapEntry<String, String>> params;
  final List<GraphNode> nodes;

  /// The text blobs exactly as stored in the file (workflow JSON and so on).
  final List<MapEntry<String, String>> raw;
  final int width;
  final int height;
  final int durationMs;

  bool get hasGeneration => source.isNotEmpty;

  factory GenInfo.fromJson(Map<String, dynamic> j) {
    double? num_(Object? v) => v is num ? v.toDouble() : null;
    return GenInfo(
      source: j['source'] as String? ?? '',
      prompt: j['prompt'] as String? ?? '',
      negative: j['negative'] as String? ?? '',
      seed: j['seed'] as String? ?? '',
      model: j['model'] as String? ?? '',
      models: [
        for (final m in (j['models'] as List? ?? const []))
          if (m is Map)
            ModelRef(
              m['kind'] as String? ?? '',
              m['name'] as String? ?? '',
              m['hash'] as String? ?? '',
            ),
      ],
      loras: [
        for (final l in (j['loras'] as List? ?? const []))
          if (l is Map)
            LoraRef(
              l['name'] as String? ?? '',
              num_(l['weight']),
              num_(l['weight_clip']),
              l['hash'] as String? ?? '',
            ),
      ],
      params: _pairs(j['params']),
      nodes: [
        for (final n in (j['nodes'] as List? ?? const []))
          if (n is Map)
            GraphNode(
              n['id']?.toString() ?? '',
              n['class'] as String? ?? '',
              n['title'] as String? ?? '',
              _pairs(n['inputs']),
            ),
      ],
      raw: _pairs(j['raw']),
      width: (j['width'] as num?)?.toInt() ?? 0,
      height: (j['height'] as num?)?.toInt() ?? 0,
      durationMs: (j['duration_ms'] as num?)?.toInt() ?? 0,
    );
  }

  static String sourceLabel(String source) => switch (source) {
    'comfyui' => 'ComfyUI',
    'invokeai' => 'InvokeAI',
    'a1111' => 'A1111',
    'forge' => 'Forge',
    'swarmui' => 'SwarmUI',
    'fooocus' => 'Fooocus',
    'novelai' => 'NovelAI',
    '' => '',
    _ => source,
  };

  /// Everything, as plain text, for "copy all".
  String summary() {
    final b = StringBuffer();
    if (prompt.isNotEmpty) b.writeln('Prompt: $prompt');
    if (negative.isNotEmpty) b.writeln('Negative prompt: $negative');
    if (seed.isNotEmpty) b.writeln('Seed: $seed');
    if (model.isNotEmpty) b.writeln('Model: $model');
    for (final m in models) {
      if (m.name != model) b.writeln('${kindLabel(m.kind)}: ${m.name}');
    }
    if (loras.isNotEmpty) {
      b.writeln(
        'LoRAs: ${loras.map((l) => l.weight == null ? l.name : '${l.name} (${formatNumber(l.weight!)})').join(', ')}',
      );
    }
    for (final p in params) {
      b.writeln('${p.key}: ${p.value}');
    }
    return b.toString().trimRight();
  }

  static String kindLabel(String kind) => switch (kind) {
    'checkpoint' => 'Checkpoint',
    'unet' => 'Diffusion model',
    'vae' => 'VAE',
    'clip' => 'Text encoder',
    'clip_vision' => 'CLIP vision',
    'controlnet' => 'ControlNet',
    'upscaler' => 'Upscaler',
    'refiner' => 'Refiner',
    'ipadapter' => 'IP-Adapter',
    't2i_adapter' => 'T2I adapter',
    'hypernetwork' => 'Hypernetwork',
    'style_model' => 'Style model',
    'model' => 'Model',
    _ =>
      kind.isEmpty
          ? 'Model'
          : '${kind[0].toUpperCase()}${kind.substring(1).replaceAll('_', ' ')}',
  };
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatDuration(int ms) {
  final s = (ms / 1000).round();
  final m = s ~/ 60;
  return '$m:${(s % 60).toString().padLeft(2, '0')}';
}

String formatDate(int mtimeMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(mtimeMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
