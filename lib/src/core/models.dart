import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

/// Join a folder path [dir] and file [name] using normalized forward slashes
/// so Windows paths (`C:\Pictures` or `C:/Pictures/`) never produce mixed
/// separators (`C:\Pictures/img.png`).
String joinMediaPath(String dir, String name) {
  final normalizedDir = dir.replaceAll('\\', '/');
  if (normalizedDir.isEmpty) return name;
  return normalizedDir.endsWith('/')
      ? '$normalizedDir$name'
      : '$normalizedDir/$name';
}

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
    this.rating = 0,
    this.flag = Flag.none,
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

  /// What the user said about it, as of the query (see [Note]).
  final int rating;
  final Flag flag;

  String get path => joinMediaPath(dir, name);

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

  /// Every id in the list, in order.
  Iterable<int> get ids sync* {
    for (var i = 0; i < length; i++) {
      yield idAt(i);
    }
  }

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
      rating: _data.getUint8(o + 43) & 7,
      flag: Flag.fromIndex((_data.getUint8(o + 43) >> 3) & 3),
      dir: _dirs[_data.getUint32(o + 44, Endian.little)],
    );
    _cache[index] = item;
    return item;
  }
}

/// A picture's keep-or-reject flag.
enum Flag {
  none,
  keep,
  reject;

  static Flag fromIndex(int i) => i == 1
      ? Flag.keep
      : i == 2
      ? Flag.reject
      : Flag.none;

  static Flag parse(String? name) => switch (name) {
    'keep' => Flag.keep,
    'reject' => Flag.reject,
    _ => Flag.none,
  };

  /// As the core takes it.
  String get word => switch (this) {
    Flag.none => 'none',
    Flag.keep => 'keep',
    Flag.reject => 'reject',
  };

  String get label => switch (this) {
    Flag.none => 'Not flagged',
    Flag.keep => 'Keep',
    Flag.reject => 'Reject',
  };
}

/// What the user has said about a picture: stars, a flag, and the
/// collections it is in. Kept in a small file in the picture's own folder.
class Note {
  const Note({
    this.rating = 0,
    this.flag = Flag.none,
    this.collections = const [],
  });
  final int rating;
  final Flag flag;
  final List<String> collections;

  static const Note empty = Note();

  factory Note.fromJson(Object? j) {
    if (j is! Map) return empty;
    return Note(
      rating: (j['rating'] as num?)?.toInt() ?? 0,
      flag: Flag.parse(j['flag'] as String?),
      collections: [
        for (final c in (j['collections'] as List? ?? const []))
          if (c is String) c,
      ],
    );
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

/// A search term that matches [value] as a whole rather than in part:
/// `model:="flux dev"`, `seed:=42`.
String exactTerm(String field, String value) => anyOfTerm(field, [value]);

/// A search term that matches any of [values] as a whole:
/// `model:="flux dev|sdxl"`. Prompts are taken whole, `|` and all.
String anyOfTerm(String field, Iterable<String> values) {
  final clean = [
    for (final v in values)
      v.replaceAll('"', '').replaceAll(RegExp(r'\s+'), ' ').trim(),
  ].where((v) => v.isNotEmpty).join('|');
  return clean.contains(' ') ? '$field:="$clean"' : '$field:=$clean';
}

/// One whitespace-separated term of a search, as typed: quotes and all.
/// Splits the way the core does, so a quoted phrase stays one term.
List<String> splitTerms(String text) {
  final out = <String>[];
  final b = StringBuffer();
  var quoted = false;
  for (final rune in text.runes) {
    final c = String.fromCharCode(rune);
    if (c == '"') quoted = !quoted;
    if (!quoted && c.trim().isEmpty) {
      if (b.isNotEmpty) out.add(b.toString());
      b.clear();
      continue;
    }
    b.write(c);
  }
  if (b.isNotEmpty) out.add(b.toString());
  return out;
}

/// A search term split into its field, whether it is exact (`:=`), and its
/// value without quotes. Field is empty for a plain word.
({bool negate, String field, bool exact, String value}) parseTerm(
  String term,
) {
  var t = term;
  var negate = false;
  if (t.length > 1 && t.startsWith('-')) {
    negate = true;
    t = t.substring(1);
  }
  final m = RegExp(r'^([a-zA-Z]+):(=?)(.*)$').firstMatch(t);
  if (m == null) {
    return (negate: negate, field: '', exact: false, value: t.replaceAll('"', ''));
  }
  return (
    negate: negate,
    field: m.group(1)!.toLowerCase(),
    exact: m.group(2) == '=',
    value: m.group(3)!.replaceAll('"', ''),
  );
}

/// One model, LoRA, setting or word, and how many images use it.
/// One image standing for a model or LoRA in the usage page.
class UsageSample {
  const UsageSample(this.path, this.mtime, this.size, this.rating);
  final String path;
  final int mtime;
  final int size;
  final int rating;

  /// Enough of a [MediaItem] to ask for its thumbnail.
  MediaItem get item {
    final slash = path.lastIndexOf('/');
    return MediaItem(
      id: path.hashCode,
      dir: slash <= 0 ? '/' : path.substring(0, slash),
      name: path.substring(slash + 1),
      isVideo: false,
      width: 0,
      height: 0,
      mtime: mtime,
      size: size,
      durationMs: 0,
      rating: rating,
    );
  }
}

class UsageItem {
  const UsageItem(
    this.value,
    this.count,
    this.role,
    this.trend, {
    this.rated = 0,
    this.stars = 0,
    this.keeps = 0,
    this.rejects = 0,
    this.samples = const [],
  });
  final String value;
  final int count;

  /// How many of its images are rated, and their stars added up; how many
  /// are flagged keep and reject.
  final int rated;
  final int stars;
  final int keeps;
  final int rejects;

  /// Its best rated images (models and LoRAs).
  final List<UsageSample> samples;

  double get averageRating => rated == 0 ? 0 : stars / rated;

  /// For supporting models, what they were used as (vae, clip, ...).
  final String role;

  /// The count spread over the folder's time span, oldest first.
  final List<int> trend;
}

/// The values of one kind, most used first.
class UsageGroup {
  const UsageGroup(this.kind, this.distinct, this.items);

  /// model | lora | aux | sampler | scheduler | steps | cfg | size | source | word
  final String kind;

  /// How many different values there are; [items] holds the most used.
  final int distinct;
  final List<UsageItem> items;

  String get title => switch (kind) {
    'model' => 'Models',
    'lora' => 'LoRAs',
    'aux' => 'Other models',
    'sampler' => 'Samplers',
    'scheduler' => 'Schedulers',
    'steps' => 'Steps',
    'cfg' => 'CFG',
    'size' => 'Sizes',
    'source' => 'Made with',
    'word' => 'Prompt words',
    'prompt' => 'Prompts',
    'rating' => 'Rating',
    'flag' => 'Flag',
    'collection' => 'Collections',
    _ => kind,
  };

  /// How [item] reads on screen.
  String label(UsageItem item) => switch (kind) {
    'source' => GenInfo.sourceLabel(item.value),
    'size' => item.value.replaceFirst('x', ' × '),
    'rating' => item.value == '0'
        ? 'Not rated'
        : '★' * (int.tryParse(item.value) ?? 0),
    'flag' => Flag.parse(item.value).label,
    _ => item.value,
  };

  /// The search that shows the images counted under [item].
  String queryFor(UsageItem item) => switch (kind) {
    'aux' => exactTerm('model', item.value),
    'word' => exactTerm('prompt', item.value),
    'prompt' => exactTerm('fullprompt', item.value),
    'rating' => 'rating:${item.value}',
    'flag' => 'flag:${item.value}',
    'source' => 'source:${item.value}',
    _ => exactTerm(kind, item.value),
  };
}

/// One bar of the usage timeline.
class TimeBucket {
  const TimeBucket(this.label, this.query, this.count);

  /// The day or month it starts on: 2026-10-09, 2026-10, 2026.
  final String label;

  /// The search that shows its images.
  final String query;
  final int count;
}

/// What a folder's images were made with, and when, as counted by the core.
class UsageStats {
  const UsageStats({
    required this.total,
    required this.generated,
    required this.groups,
    required this.unit,
    required this.timeline,
  });

  final int total;

  /// Files that carry generation data.
  final int generated;
  final List<UsageGroup> groups;

  /// day | week | month | year
  final String unit;
  final List<TimeBucket> timeline;

  static const UsageStats empty = UsageStats(
    total: 0,
    generated: 0,
    groups: [],
    unit: 'day',
    timeline: [],
  );

  factory UsageStats.fromJson(Map<String, dynamic> j) {
    int number(Object? v) => v is num ? v.toInt() : 0;
    return UsageStats(
      total: number(j['total']),
      generated: number(j['generated']),
      unit: j['unit'] as String? ?? 'day',
      groups: [
        for (final g in (j['groups'] as List? ?? const []))
          if (g is Map)
            UsageGroup(g['kind'] as String? ?? '', number(g['distinct']), [
              for (final i in (g['items'] as List? ?? const []))
                if (i is Map)
                  UsageItem(
                    i['value'] as String? ?? '',
                    number(i['count']),
                    i['role'] as String? ?? '',
                    [for (final n in (i['trend'] as List? ?? const [])) number(n)],
                    rated: number(i['rated']),
                    stars: number(i['stars']),
                    keeps: number(i['keeps']),
                    rejects: number(i['rejects']),
                    samples: [
                      for (final s in (i['samples'] as List? ?? const []))
                        if (s is Map)
                          UsageSample(
                            s['path'] as String? ?? '',
                            number(s['mtime']),
                            number(s['size']),
                            number(s['rating']),
                          ),
                    ],
                  ),
            ]),
      ],
      timeline: [
        for (final b in (j['timeline'] as List? ?? const []))
          if (b is Map)
            TimeBucket(
              b['label'] as String? ?? '',
              b['query'] as String? ?? '',
              number(b['count']),
            ),
      ],
    );
  }
}

/// Where content search stands: whether its model is here, and how far the
/// current folder's pictures have been looked at.
class ContentStatus {
  const ContentStatus({
    this.known = false,
    this.installed = false,
    this.modelDir = '',
    this.source = '',
    this.files = const [],
    this.embedded = 0,
    this.total = 0,
    this.indexing = false,
    this.done = 0,
    this.todo = 0,
    this.error,
  });

  /// False until the core has been asked.
  final bool known;
  final bool installed;

  /// Where the model's files go, and where they come from.
  final String modelDir;
  final String source;

  /// (name, bytes) of each file of the model.
  final List<(String, int)> files;

  /// Pictures of the folder that have been looked at, out of how many.
  final int embedded;
  final int total;

  /// A pass over the folder is running: [done] of [todo] pictures so far.
  final bool indexing;
  final int done;
  final int todo;
  final String? error;

  int get downloadBytes => files.fold(0, (sum, file) => sum + file.$2);

  factory ContentStatus.fromJson(Map<String, dynamic> j) {
    int number(Object? v) => v is num ? v.toInt() : 0;
    return ContentStatus(
      known: true,
      installed: j['installed'] == true,
      modelDir: j['model_dir'] as String? ?? '',
      source: j['source'] as String? ?? '',
      files: [
        for (final f in (j['files'] as List? ?? const []))
          if (f is Map) (f['name'] as String? ?? '', number(f['bytes'])),
      ],
      embedded: number(j['embedded']),
      total: number(j['total']),
      indexing: j['indexing'] == true,
      done: number(j['done']),
      todo: number(j['todo']),
    );
  }

  ContentStatus copyWith({
    bool? installed,
    int? embedded,
    bool? indexing,
    int? done,
    int? todo,
    String? Function()? error,
  }) => ContentStatus(
    known: known,
    installed: installed ?? this.installed,
    modelDir: modelDir,
    source: source,
    files: files,
    embedded: embedded ?? this.embedded,
    total: total,
    indexing: indexing ?? this.indexing,
    done: done ?? this.done,
    todo: todo ?? this.todo,
    error: error == null ? this.error : error(),
  );
}

/// The file extension for a pasted picture of MIME type [type].
String extensionForType(String? type) => switch (type) {
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'image/bmp' => 'bmp',
      'video/mp4' => 'mp4',
      'video/webm' => 'webm',
      'video/quicktime' => 'mov',
      _ => 'png',
    };

/// Normalize a filesystem path to use forward slashes (`/`) across all platforms,
/// stripping Windows extended-length verbatim prefixes (`\\?\`) and redundant
/// trailing slashes while preserving Unix root (`/`) and Windows drive roots (`C:/`).
String normalizePath(String raw) {
  var stripped = raw;
  if (stripped.startsWith(r'\\?\UNC\')) {
    stripped = '//${stripped.substring(8)}';
  } else if (stripped.startsWith(r'\\?\')) {
    stripped = stripped.substring(4);
  }
  var s = stripped.replaceAll(r'\', '/');
  while (s.length > 1 && s.endsWith('/')) {
    if (s.length == 3 && s[1] == ':' && RegExp(r'^[A-Za-z]').hasMatch(s)) {
      break;
    }
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// A path in [dir] for a file called [name] that doesn't exist yet:
/// `name.png`, then `name (2).png`, `name (3).png`, …
String freeFileName(String dir, String name) {
  final sep = dir.contains('/') ? '/' : Platform.pathSeparator;
  final base = (dir.endsWith('/') || dir.endsWith(r'\')) ? dir : '$dir$sep';
  if (!File('$base$name').existsSync()) return '$base$name';
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var n = 2;; n++) {
    final candidate = '$base$stem ($n)$ext';
    if (!File(candidate).existsSync()) return candidate;
  }
}

