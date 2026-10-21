/// The user's say, in the remix panel, over each LoRA a picture was made
/// with: on or off, and how strong. Applied to whatever is sent: the
/// `<lora:name:weight>` tags in a prompt, a ComfyUI workflow's LoRA nodes, an
/// InvokeAI graph's LoRA nodes, or the list a built graph is made from.
library;

import 'models.dart';
import 'recipe_graphs.dart' show modelKey;

/// The least and most a LoRA's weight can be set to in the panel.
const double loraWeightMin = -1;
const double loraWeightMax = 2;

/// One LoRA of the picture, as the user has set it.
class LoraChoice {
  LoraChoice(this.original, {bool? enabled, double? weight})
      : enabled = enabled ?? true,
        weight = weight ?? original.weight ?? 1.0;

  /// As the picture was made with it.
  final LoraRef original;
  bool enabled;
  double weight;

  /// The weight the picture was made with (1 when it does not say).
  double get originalWeight => original.weight ?? 1.0;

  /// How far the weight has been moved from [originalWeight].
  double get offset => weight - originalWeight;

  bool get reweighted => offset.abs() > 1e-9;

  bool get changed => !enabled || reweighted;

  /// The text-encoder (CLIP) weight: where the picture had its own, moved by
  /// as much as the main weight; otherwise the same as it.
  double get clipWeight => original.weightClip == null ? weight : original.weightClip! + offset;

  /// The name, as it is matched everywhere: no folder, extension or case.
  String get key => modelKey(original.name);

  /// The LoRA as a built graph should load it.
  LoraRef get ref => LoraRef(
        original.name,
        weight,
        original.weightClip == null ? null : clipWeight,
        original.hash,
      );

  void reset() {
    enabled = true;
    weight = originalWeight;
  }

  LoraChoice copy() => LoraChoice(original, enabled: enabled, weight: weight);
}

/// `<lora:name:weight>`, `<lyco:…>` and `<lycoris:…>`, with any further
/// `:value`s.
final RegExp _tag = RegExp(r'<(lora|lyco|lycoris):([^:>]+)((?::[^:>]*)*)>', caseSensitive: false);

/// The names (as [modelKey]s) of the LoRAs tagged in [prompt].
Set<String> taggedLoras(String prompt) => {
      for (final m in _tag.allMatches(prompt)) modelKey(m.group(2)!),
    };

/// A weight as it is written in a tag: no more digits than it needs.
String weightText(double v) {
  final rounded = (v * 1000).round() / 1000;
  return formatNumber(rounded == 0 ? 0 : rounded);
}

/// [prompt] with its LoRA tags following [choices]: the tags of LoRAs turned
/// off taken out (with a comma beside them, so no `, ,` is left), and the
/// weights of those moved rewritten. Tags of LoRAs not in [choices] are left
/// as they are.
///
/// With [addTo] (the prompt the picture was made with), a LoRA that is on
/// but tagged in neither [addTo] nor [prompt] is added as a tag at the end:
/// for Forge / A1111, which only loads the LoRAs its prompt names. One the
/// user took out of the prompt themselves stays out.
String retagPrompt(String prompt, List<LoraChoice> choices, {String? addTo}) {
  LoraChoice? choiceFor(String name) {
    final key = modelKey(name);
    for (final c in choices) {
      if (c.key == key) return c;
    }
    return null;
  }

  const gone = '\u0000';
  var removed = false;
  var out = prompt.replaceAllMapped(_tag, (m) {
    final choice = choiceFor(m.group(2)!);
    if (choice == null) return m.group(0)!;
    if (!choice.enabled) {
      removed = true;
      return gone;
    }
    if (!choice.reweighted) return m.group(0)!;
    final parts = m.group(3)!.isEmpty ? <String>[] : m.group(3)!.substring(1).split(':');
    if (parts.isEmpty) {
      parts.add(weightText(choice.weight));
    } else {
      for (var i = 0; i < parts.length; i++) {
        final v = double.tryParse(parts[i].trim());
        if (v == null) continue;
        parts[i] = weightText(i == 0 ? choice.weight : v + choice.offset);
      }
    }
    return '<${m.group(1)}:${m.group(2)}:${parts.join(':')}>';
  });
  if (removed) {
    out = out
        .replaceAll(RegExp('[ \\t]*,[ \\t]*$gone'), '')
        .replaceAll(RegExp('$gone[ \\t]*,?[ \\t]*'), '')
        .replaceAll(RegExp(r'[ \t]+$', multiLine: true), '');
  }
  if (addTo != null) {
    final had = {...taggedLoras(addTo), ...taggedLoras(out)};
    final extra = [
      for (final c in choices)
        if (c.enabled && c.key.isNotEmpty && !had.contains(c.key)) '<lora:${_stem(c.original.name)}:${weightText(c.weight)}>',
    ];
    if (extra.isNotEmpty) {
      final trimmed = out.trimRight();
      final sep = trimmed.isEmpty ? '' : (trimmed.endsWith(',') ? ' ' : ', ');
      out = '$trimmed$sep${extra.join(', ')}';
    }
  }
  return out;
}

/// A LoRA's file name without its folder or extension, as a tag names it.
String _stem(String name) {
  var s = name.trim().replaceFirst(RegExp(r'\s*\[[0-9a-fA-F]+\]$'), '');
  s = s.split(RegExp(r'[/\\]')).last;
  return s.replaceFirst(RegExp(r'\.(safetensors|ckpt|pt|pth|bin)$', caseSensitive: false), '');
}

LoraChoice? _find(List<LoraChoice> choices, Object? name) {
  if (name is! String || name.trim().isEmpty) return null;
  final key = modelKey(name);
  for (final c in choices) {
    if (c.key == key) return c;
  }
  return null;
}

// ---------------------------------------------------------------- ComfyUI

/// The keys a LoRA's main (model) weight is kept under, beside its name.
const _modelWeightKeys = ['strength_model', 'strength', 'lora_strength', 'weight', 'lora_weight', 'model_strength'];
const _clipWeightKeys = ['strength_clip', 'clip_strength'];

/// The same in stacker nodes, numbered: `lora_wt_1`, `model_str_2`...
const _stackModelPrefixes = ['lora_wt_', 'strength_', 'model_str_', 'lora_strength_', 'weight_', 'model_weight_', 'lora_weight_'];
const _stackClipPrefixes = ['clip_str_', 'clip_strength_', 'clip_weight_'];

/// Change a ComfyUI API-format workflow in place to follow [choices]:
///
/// * a `LoraLoader` (or `LoraLoaderModelOnly`) of a LoRA turned off is taken
///   out, whatever took its model and CLIP taking them from before it;
/// * rgthree's Power Lora Loader has that LoRA switched off;
/// * in any other node naming it (stackers and the like) its weights are
///   set to 0, and an On/Off switch beside it to Off;
/// * a LoRA moved has its weights set wherever it is named.
void editComfyLoras(Map<String, dynamic> graph, List<LoraChoice> choices) {
  if (!choices.any((c) => c.changed)) return;
  final dropped = <String, Map<String, dynamic>>{};
  for (final MapEntry(key: id, value: node) in graph.entries) {
    if (node is! Map<String, dynamic>) continue;
    final inputs = node['inputs'];
    if (inputs is! Map<String, dynamic>) continue;
    final type = '${node['class_type'] ?? ''}';

    // rgthree Power Lora Loader: lora_1: {on, lora, strength, strengthTwo}.
    for (final v in inputs.values) {
      if (v is! Map || v['lora'] is! String) continue;
      final c = _find(choices, v['lora']);
      if (c == null) continue;
      if (!c.enabled) {
        v['on'] = false;
      } else if (c.reweighted) {
        v['strength'] = c.weight;
        final two = v['strengthTwo'];
        if (two is num) v['strengthTwo'] = two + c.offset;
      }
    }

    for (final key in inputs.keys.toList()) {
      final name = inputs[key];
      if (name is! String || !key.toLowerCase().contains('lora')) continue;
      final c = _find(choices, name);
      if (c == null || !c.changed) continue;
      final lower = key.toLowerCase();
      final digits = RegExp(r'_?(\d+)$').firstMatch(lower)?.group(1);
      if (digits == null) {
        // One LoRA to the node.
        if (!c.enabled && (type == 'LoraLoader' || type == 'LoraLoaderModelOnly')) {
          dropped[id] = inputs;
          continue;
        }
        for (final k in _modelWeightKeys) {
          if (inputs[k] is num) inputs[k] = c.enabled ? c.weight : 0;
        }
        for (final k in _clipWeightKeys) {
          if (inputs[k] is num) inputs[k] = c.enabled ? (inputs[k] as num) + c.offset : 0;
        }
      } else {
        // One of several, numbered.
        for (final p in _stackModelPrefixes) {
          final k = '$p$digits';
          if (inputs[k] is num) inputs[k] = c.enabled ? c.weight : 0;
        }
        for (final p in _stackClipPrefixes) {
          final k = '$p$digits';
          if (inputs[k] is num) inputs[k] = c.enabled ? (inputs[k] as num) + c.offset : 0;
        }
        if (!c.enabled) {
          for (final k in ['switch_$digits', 'lora_switch_$digits']) {
            if (inputs[k] is String) inputs[k] = 'Off';
            if (inputs[k] is bool) inputs[k] = false;
          }
        }
      }
    }
  }

  // Take out the loaders of LoRAs turned off, joining what came after each to
  // what came before. Done one at a time, so a chain of them comes out whole.
  for (final MapEntry(key: id, value: inputs) in dropped.entries) {
    final from = <int, Object?>{0: inputs['model'], 1: inputs['clip']};
    for (final node in graph.values) {
      if (node is! Map) continue;
      final into = node['inputs'];
      if (into is! Map) continue;
      for (final k in into.keys.toList()) {
        final v = into[k];
        if (v is List && v.length == 2 && '${v[0]}' == id && v[1] is int) {
          final source = from[v[1]];
          if (source != null) into[k] = source;
        }
      }
    }
    graph.remove(id);
  }
}

// ---------------------------------------------------------------- InvokeAI

/// The name of the LoRA an InvokeAI node loads, if it loads one.
String? _invokeLora(Map node) {
  final lora = node['lora'];
  if (lora is Map) return '${lora['name'] ?? lora['model_name'] ?? ''}';
  return null;
}

/// Change an InvokeAI graph (`{nodes, edges}`) in place to follow
/// [choices]: the loader of a LoRA turned off is taken out (what it fed fed
/// from what fed it), a LoRA selector feeding a collection of them is taken
/// out, and the weights of those moved are set. The picture's metadata node
/// is changed to match, so the new picture says what it was made with.
void editInvokeLoras(Map<String, dynamic> graph, List<LoraChoice> choices) {
  if (!choices.any((c) => c.changed)) return;
  final nodes = graph['nodes'];
  if (nodes is! Map<String, dynamic>) return;
  final edges = graph['edges'] is List ? (graph['edges'] as List).whereType<Map>().toList() : <Map>[];

  String sourceNode(Map e) => '${(e['source'] as Map?)?['node_id']}';
  String sourceField(Map e) => '${(e['source'] as Map?)?['field']}';
  String destNode(Map e) => '${(e['destination'] as Map?)?['node_id']}';
  String destField(Map e) => '${(e['destination'] as Map?)?['field']}';

  for (final id in nodes.keys.toList()) {
    final node = nodes[id];
    if (node is! Map) continue;
    final c = _find(choices, _invokeLora(node));
    if (c == null || !c.changed) continue;
    if (c.enabled) {
      if (node['weight'] is num) node['weight'] = c.weight;
      continue;
    }
    final type = '${node['type'] ?? ''}';
    if (type.endsWith('lora_loader')) {
      // A pass-through: unet in, unet out (and clip, clip2...).
      for (final out in edges.where((e) => sourceNode(e) == id).toList()) {
        final incoming = edges.where((e) => destNode(e) == id && destField(e) == sourceField(out));
        if (incoming.isEmpty) {
          edges.remove(out);
        } else {
          out['source'] = Map<String, dynamic>.from(incoming.first['source'] as Map);
        }
      }
      edges.removeWhere((e) => destNode(e) == id);
      nodes.remove(id);
    } else if (type.endsWith('lora_selector')) {
      edges.removeWhere((e) => destNode(e) == id || sourceNode(e) == id);
      nodes.remove(id);
    } else if (node['weight'] is num) {
      node['weight'] = 0;
    }
  }
  if (graph['edges'] is List) graph['edges'] = edges;

  // The metadata the new picture will carry.
  for (final node in nodes.values) {
    if (node is! Map || node['loras'] is! List) continue;
    final list = node['loras'] as List;
    list.removeWhere((l) {
      if (l is! Map) return false;
      final m = l['model'] ?? l['lora'];
      final c = m is Map ? _find(choices, m['name'] ?? m['model_name']) : null;
      return c != null && !c.enabled;
    });
    for (final l in list) {
      if (l is! Map) continue;
      final m = l['model'] ?? l['lora'];
      final c = m is Map ? _find(choices, m['name'] ?? m['model_name']) : null;
      if (c != null && c.reweighted && l['weight'] is num) l['weight'] = c.weight;
    }
  }
}

// ---------------------------------------------------------------- trigger words

/// The phrases of one of a LoRA's trigger-word entries, which Civitai often
/// lists several to an entry, comma-separated.
List<String> triggerParts(String entry) => [
      for (final part in entry.split(',')) if (part.trim().isNotEmpty) part.trim(),
    ];

String _flat(String text) => text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Whether every phrase of trigger-word [entry] is in [prompt], case and
/// spacing aside.
bool triggerPresent(String prompt, String entry) {
  final parts = triggerParts(entry);
  if (parts.isEmpty) return true;
  final text = _flat(prompt);
  return parts.every((p) => text.contains(_flat(p)));
}

/// [prompt] with trigger-word [entry] put at its start, where trigger
/// words are usually written (only the phrases not already there).
String addTrigger(String prompt, String entry) {
  final missing = [for (final p in triggerParts(entry)) if (!triggerPresent(prompt, p)) p];
  if (missing.isEmpty) return prompt;
  final head = missing.join(', ');
  final rest = prompt.trimLeft();
  return rest.isEmpty ? head : '$head, $rest';
}
