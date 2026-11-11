// Putting a negative prompt into a picture's own graph by following its
// wiring: whatever feeds the sampler's (or denoise step's) negative input
// is where the text goes, whatever it said before. Matching on the old text
// alone misses a picture that had no negative prompt, and one whose
// negative is built from several nodes.

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// One text field of one node.
typedef _Slot = ({String node, String field});

/// The parts of a negative prompt read from several nodes, as the metadata
/// reader joins them: a blank line between each.
List<String> _parts(String text) => [
      for (final p in text.split(RegExp(r'\n\s*\n')))
        if (p.trim().isNotEmpty) p.trim(),
    ];

/// Write [text] into the groups of slots (one group per sampler) whose text
/// reads as [old]: one slot takes all of it; several that say the same take
/// it each; several that differ take a part each, when [text] has as many
/// parts. With no such group, a graph with a single slot takes it there.
/// Returns whether anything was written.
bool _write(
  List<List<_Slot>> groups,
  String text,
  String old, {
  required String Function(_Slot) read,
  required void Function(_Slot, String) write,
}) {
  var done = false;
  for (final slots in groups) {
    if (slots.isEmpty) continue;
    final values = [for (final s in slots) _norm(read(s))];
    if (_norm(values.where((v) => v.isNotEmpty).join(' ')) != _norm(old)) continue;
    if (values.toSet().length == 1) {
      for (final s in slots) {
        write(s, text);
      }
      done = true;
      continue;
    }
    final parts = _parts(text);
    final filled = [
      for (var i = 0; i < slots.length; i++)
        if (values[i].isNotEmpty) slots[i],
    ];
    if (parts.length == filled.length) {
      for (var i = 0; i < filled.length; i++) {
        write(filled[i], parts[i]);
      }
      done = true;
    } else if (parts.isEmpty) {
      for (final s in filled) {
        write(s, '');
      }
      done = true;
    }
  }
  if (done) return true;
  final all = {for (final g in groups) ...g};
  if (all.length == 1) {
    write(all.single, text);
    return true;
  }
  return false;
}

// ---------------------------------------------------------------- ComfyUI

/// The inputs a ComfyUI text encoder takes its text by.
const Set<String> _comfyTextInputs = {'text', 'text_g', 'text_l', 't5xxl', 'clip_l', 'clip_g', 'prompt'};

/// The inputs a node that only holds a string keeps it in.
const List<String> _comfyStringInputs = ['value', 'string', 'text', 'String'];

/// Put the negative prompt [text] into the ComfyUI API graph [graph], whose
/// negative prompt read as [old]: into the text encoders wired to each
/// sampler's `negative` input, through whatever combines or passes
/// conditioning on the way. A negative that is the positive zeroed out
/// (how Krea 2 and FLUX workflows run with CFG off) has no text to change;
/// with [add], a text encoder for it is put in its place, on the same CLIP
/// as the positive prompt's.
///
/// Returns whether the graph now carries [text].
bool placeComfyNegative(Map<String, dynamic> graph, String text, {required String old, bool add = true}) {
  Map<String, dynamic> inputs(String id) {
    final node = graph[id];
    final i = node is Map ? node['inputs'] : null;
    return i is Map<String, dynamic> ? i : const {};
  }

  String type(String id) {
    final node = graph[id];
    return node is Map ? '${node['class_type'] ?? ''}' : '';
  }

  String? link(Object? v) => v is List && v.length == 2 && (v[0] is String || v[0] is num) && graph['${v[0]}'] is Map ? '${v[0]}' : null;

  // The slot a text input's value lives in: the encoder's own field, or the
  // string node wired into it.
  _Slot? textSlot(String id, String key, [int depth = 0]) {
    final v = inputs(id)[key];
    if (v is String) return (node: id, field: key);
    final from = link(v);
    if (from == null || depth > 4) return null;
    for (final k in _comfyStringInputs) {
      if (inputs(from)[k] is String) return (node: from, field: k);
      if (link(inputs(from)[k]) != null) return textSlot(from, k, depth + 1);
    }
    return null;
  }

  // Walk up from [id], which feeds a sampler's [side] input.
  void walk(
    String id,
    String side,
    List<_Slot> slots,
    Set<String> seen, {
    List<String>? encoders,
    void Function(String zero)? zeroed,
  }) {
    if (!seen.add(id)) return;
    final i = inputs(id);
    if (type(id) == 'ConditioningZeroOut') {
      zeroed?.call(id);
      return;
    }
    if (link(i['clip']) != null) {
      encoders?.add(id);
      for (final key in i.keys) {
        if (!_comfyTextInputs.contains(key)) continue;
        final slot = textSlot(id, key);
        if (slot != null && !slots.contains(slot)) slots.add(slot);
      }
      return;
    }
    // A node that passes both sides on (ControlNet, say): this side's.
    if (link(i['positive']) != null && link(i['negative']) != null) {
      walk(link(i[side])!, side, slots, seen, encoders: encoders, zeroed: zeroed);
      return;
    }
    for (final MapEntry(:key, :value) in i.entries) {
      final from = link(value);
      if (from != null && key.startsWith('conditioning')) {
        walk(from, side, slots, seen, encoders: encoders, zeroed: zeroed);
      }
    }
  }

  final samplers = [
    for (final id in graph.keys)
      if (link(inputs(id)['positive']) != null && link(inputs(id)['negative']) != null) id,
  ];
  // What the positive side reads its text from is never the negative's.
  final positive = <_Slot>[];
  final encoders = <String, List<String>>{};
  for (final id in samplers) {
    walk(link(inputs(id)['positive'])!, 'positive', positive, {}, encoders: encoders[id] = []);
  }
  final groups = <List<_Slot>>[];
  final zeroed = <String>[];
  for (final id in samplers) {
    final slots = <_Slot>[];
    var zero = false;
    walk(link(inputs(id)['negative'])!, 'negative', slots, {}, zeroed: (_) => zero = true);
    slots.removeWhere(positive.contains);
    if (slots.isNotEmpty) {
      groups.add(slots);
    } else if (zero) {
      zeroed.add(id);
    }
  }

  final written = _write(
    groups,
    text,
    old,
    read: (s) => '${inputs(s.node)[s.field] ?? ''}',
    write: (s, v) => inputs(s.node)[s.field] = v,
  );
  if (written || !add || text.trim().isEmpty) return written;

  // No negative text anywhere: one of its own for each sampler that ran on
  // the positive zeroed out.
  var added = false;
  for (final id in zeroed) {
    final clip = [for (final e in encoders[id] ?? const <String>[]) inputs(e)['clip']].firstOrNull;
    if (clip == null) continue;
    const name = 'generativeview_negative';
    graph[name] ??= {
      'class_type': 'CLIPTextEncode',
      'inputs': {'text': text, 'clip': clip},
    };
    inputs(id)['negative'] = [name, 0];
    added = true;
  }
  return added;
}

// --------------------------------------------------------------- InvokeAI

/// The inputs an InvokeAI denoise step takes the two prompts by: most name
/// them `…_conditioning`, FLUX `…_text_conditioning`.
const Map<String, String> _invokeSides = {
  'negative_conditioning': 'positive_conditioning',
  'negative_text_conditioning': 'positive_text_conditioning',
};

/// Put the negative prompt [text] into the InvokeAI graph [graph], whose
/// negative prompt read as [old]: into the text encoder wired to each
/// denoise step's negative conditioning (or the string node wired into
/// that), and into the metadata the picture will carry. A graph made with
/// CFG off has no negative encoder at all; with [add], one is made the way
/// the positive prompt's is, on the same model, and wired in.
///
/// Returns whether the graph now carries [text].
bool placeInvokeNegative(Map<String, dynamic> graph, String text, {required String old, bool add = true}) {
  final nodes = graph['nodes'];
  final edges = graph['edges'];
  if (nodes is! Map<String, dynamic> || edges is! List) return false;

  Map<String, dynamic>? node(Object? id) {
    final n = nodes[id];
    return n is Map<String, dynamic> ? n : null;
  }

  // The edges into [id], as (the field they arrive at, where from).
  Iterable<(String, Map<dynamic, dynamic>)> into(String id) sync* {
    for (final e in edges) {
      if (e is! Map) continue;
      final to = e['destination'];
      final from = e['source'];
      if (to is Map && from is Map && to['node_id'] == id) yield ('${to['field']}', from);
    }
  }

  bool encodes(String id) {
    final n = node(id);
    if (n == null) return false;
    final t = '${n['type'] ?? ''}';
    return n['prompt'] is String || t.contains('compel') || t.contains('text_encoder') || into(id).any((e) => e.$1 == 'prompt');
  }

  _Slot? slot(String id, String field) {
    for (final (to, from) in into(id)) {
      if (to != field) continue;
      final source = node(from['node_id']);
      final out = '${from['field']}';
      return source != null && source[out] is String ? (node: '${from['node_id']}', field: out) : null;
    }
    return (node: id, field: field);
  }

  String read(_Slot s) => '${node(s.node)?[s.field] ?? ''}';

  void walk(String id, List<_Slot> slots, Set<String> seen, {List<String>? encoders}) {
    if (!seen.add(id) || node(id) == null) return;
    if (encodes(id)) {
      encoders?.add(id);
      final n = node(id)!;
      bool takes(String field) => n.containsKey(field) || into(id).any((e) => e.$1 == field);
      // SDXL's refiner encoder has a style prompt alone.
      final main = !takes('prompt') && takes('style') ? 'style' : 'prompt';
      final prompt = slot(id, main);
      if (prompt == null) return;
      if (!slots.contains(prompt)) slots.add(prompt);
      // SDXL's style prompt follows the prompt where it says the same.
      if (main == 'prompt' && takes('style')) {
        final style = slot(id, 'style');
        if (style != null && !slots.contains(style) && _norm(read(style)) == _norm(read(prompt))) slots.add(style);
      }
      return;
    }
    // A collection of conditionings, or anything else passing them on.
    for (final (to, from) in into(id)) {
      if (to == 'item' || to == 'collection' || to.contains('conditioning')) {
        walk('${from['node_id']}', slots, seen, encoders: encoders);
      }
    }
  }

  final positive = <_Slot>[];
  // Each denoise step: its positive encoders, and what leaves them.
  final steps = <String, ({String field, List<String> encoders})>{};
  final groups = <List<_Slot>>[];
  final has = <String>{};
  for (final id in nodes.keys) {
    for (final (to, from) in into(id).toList()) {
      if (_invokeSides.containsValue(to)) {
        final found = <String>[];
        walk('${from['node_id']}', positive, {}, encoders: found);
        steps[id] = (field: _invokeSides.entries.firstWhere((e) => e.value == to).key, encoders: found);
      }
    }
  }
  for (final id in nodes.keys) {
    for (final (to, from) in into(id).toList()) {
      if (!_invokeSides.containsKey(to)) continue;
      has.add(id);
      final slots = <_Slot>[];
      walk('${from['node_id']}', slots, {});
      slots.removeWhere(positive.contains);
      if (slots.isNotEmpty) groups.add(slots);
    }
  }

  var placed = _write(groups, text, old, read: read, write: (s, v) => node(s.node)![s.field] = v);

  if (!placed && add && text.trim().isNotEmpty) {
    for (final MapEntry(key: id, value: step) in steps.entries) {
      if (has.contains(id) || step.encoders.isEmpty) continue;
      final like = step.encoders.first;
      const name = 'generativeview_negative';
      if (!nodes.containsKey(name)) {
        final copy = Map<String, dynamic>.of(node(like)!)
          ..['id'] = name
          ..['prompt'] = text;
        if (copy.containsKey('style')) copy['style'] = text;
        nodes[name] = copy;
        // On the same model (and CLIPs, and LoRAs) as the positive prompt.
        for (final (to, from) in into(like).toList()) {
          if (to == 'prompt' || to == 'style') continue;
          edges.add({
            'source': Map<String, dynamic>.from(from),
            'destination': {'node_id': name, 'field': to},
          });
        }
      }
      // What leaves the positive encoder leaves this one the same way.
      var out = 'conditioning';
      for (final e in edges) {
        if (e is Map && (e['source'] as Map?)?['node_id'] == like) {
          out = '${(e['source'] as Map)['field']}';
          break;
        }
      }
      edges.add({
        'source': {'node_id': name, 'field': out},
        'destination': {'node_id': id, 'field': step.field},
      });
      placed = true;
    }
  }

  // So the picture records what it was made with.
  if (placed) {
    for (final MapEntry(key: id, :value) in nodes.entries) {
      if (value is Map<String, dynamic> && value['type'] == 'core_metadata' && !into(id).any((e) => e.$1 == 'negative_prompt')) {
        value['negative_prompt'] = text;
      }
    }
  }
  return placed;
}
