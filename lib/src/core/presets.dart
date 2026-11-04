/// Presets: parts of a recipe saved under a name, to apply to any picture in
/// Remix or Breed. A part left out stays as it is when one is applied.
library;

import 'dart:convert';

import 'lora_edits.dart';
import 'models.dart';
import 'prompt_edits.dart';
import 'recipe_graphs.dart' show modelKey;

class PresetLora {
  const PresetLora(this.name, this.weight);
  final String name;
  final double weight;

  Map<String, Object?> toJson() => {'name': name, 'weight': weight};

  factory PresetLora.fromJson(Map<String, dynamic> j) =>
      PresetLora(j['name'] as String? ?? '', (j['weight'] as num?)?.toDouble() ?? 1.0);
}

class Preset {
  const Preset({
    required this.id,
    required this.name,
    this.prompt,
    this.replacePrompt = false,
    this.negative,
    this.replaceNegative = false,
    this.loras = const [],
    this.steps,
    this.cfg,
    this.width,
    this.height,
  });

  final String id;
  final String name;

  /// Phrases to add, or the whole prompt with [replacePrompt].
  final String? prompt;
  final bool replacePrompt;
  final String? negative;
  final bool replaceNegative;
  final List<PresetLora> loras;
  final int? steps;
  final double? cfg;
  final int? width;
  final int? height;

  /// What it carries, for a list.
  List<String> get parts => [
    if (prompt != null) 'Prompt',
    if (negative != null) 'Negative',
    if (loras.isNotEmpty) loras.length == 1 ? '1 LoRA' : '${loras.length} LoRAs',
    if (steps != null || cfg != null) 'Steps, CFG',
    if (width != null && height != null) 'Size',
  ];

  bool get isEmpty => parts.isEmpty;

  Preset copyWith({String? id, String? name}) => Preset(
    id: id ?? this.id,
    name: name ?? this.name,
    prompt: prompt,
    replacePrompt: replacePrompt,
    negative: negative,
    replaceNegative: replaceNegative,
    loras: loras,
    steps: steps,
    cfg: cfg,
    width: width,
    height: height,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (prompt != null) 'prompt': prompt,
    if (replacePrompt) 'replacePrompt': true,
    if (negative != null) 'negative': negative,
    if (replaceNegative) 'replaceNegative': true,
    if (loras.isNotEmpty) 'loras': [for (final l in loras) l.toJson()],
    if (steps != null) 'steps': steps,
    if (cfg != null) 'cfg': cfg,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
  };

  factory Preset.fromJson(Map<String, dynamic> j) => Preset(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    prompt: j['prompt'] as String?,
    replacePrompt: j['replacePrompt'] == true,
    negative: j['negative'] as String?,
    replaceNegative: j['replaceNegative'] == true,
    loras: [
      for (final l in (j['loras'] as List?) ?? const [])
        if (l is Map<String, dynamic>) PresetLora.fromJson(l),
    ],
    steps: (j['steps'] as num?)?.toInt(),
    cfg: (j['cfg'] as num?)?.toDouble(),
    width: (j['width'] as num?)?.toInt(),
    height: (j['height'] as num?)?.toInt(),
  );
}

/// A presets file: what Export writes and Import reads.
String presetsToFile(List<Preset> presets) => const JsonEncoder.withIndent('  ').convert({
  'generativeview_presets': 1,
  'presets': [for (final p in presets) p.toJson()],
});

/// The presets in a presets file; throws [FormatException] if it is not one.
List<Preset> presetsFromFile(String text) {
  final json = jsonDecode(text);
  if (json is! Map<String, dynamic> || json['generativeview_presets'] == null) {
    throw const FormatException('this is not a presets file');
  }
  return [
    for (final p in (json['presets'] as List?) ?? const [])
      if (p is Map<String, dynamic>) Preset.fromJson(p),
  ];
}

/// [incoming] added to [mine]: one the same as one already here is skipped,
/// and one with a name already used gets a number.
List<Preset> mergePresets(List<Preset> mine, List<Preset> incoming, String Function() newId) {
  final out = [...mine];
  String body(Preset p) => jsonEncode(p.copyWith(id: '', name: '').toJson());
  for (final p in incoming) {
    if (p.name.trim().isEmpty) continue;
    if (out.any((o) => o.name == p.name && body(o) == body(p))) continue;
    var name = p.name;
    for (var n = 2; out.any((o) => o.name == name); n++) {
      name = '${p.name} ($n)';
    }
    out.add(p.copyWith(id: newId(), name: name));
  }
  return out;
}

/// Each comma-separated part of [text], weights and all.
List<String> _parts(String text) => [
  for (final p in text.split(',').map((p) => p.trim()))
    if (p.isNotEmpty) p,
];

/// [current] with a preset's [text] applied: added phrase by phrase, or in
/// place of it all.
String applyPresetText(String current, String text, {required bool replace}) {
  if (replace) return text;
  var out = current;
  for (final part in _parts(text)) {
    out = addPhrase(out, part);
  }
  return out;
}

/// The parts of [text] that applying it adds to [current], to show as new.
List<String> addedPresetPhrases(String current, String text, {required bool replace}) => replace
    ? _parts(text)
    : [
        for (final part in _parts(text))
          if (findPhrase(current, part) == null) part,
      ];

/// [loras] with the preset's: one the picture has takes the preset's weight,
/// and a new one joins the list.
void applyPresetLoras(List<LoraChoice> loras, List<PresetLora> preset) {
  for (final p in preset) {
    final key = modelKey(p.name);
    final known = loras.where((c) => c.key == key).firstOrNull;
    if (known != null) {
      known
        ..enabled = true
        ..weight = p.weight;
    } else {
      loras.add(LoraChoice(LoraRef(p.name, p.weight, null, '')));
    }
  }
}
