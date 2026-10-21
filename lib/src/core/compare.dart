/// Setting two to four pictures side by side: which of their settings
/// differ, and how one prompt differs from another, word by word.
library;

import 'models.dart';

/// One line of the comparison: a setting and what each picture has for it
/// (an empty string where a picture does not say).
class CompareRow {
  const CompareRow(this.label, this.values, {this.prompt = false});
  final String label;
  final List<String> values;

  /// A prompt, shown word by word against the first picture's.
  final bool prompt;

  /// Whether the pictures do not all have the same value. Case and runs of
  /// spaces aside, so `Euler` and `euler` are the same.
  bool get differs {
    if (values.length < 2) return false;
    final first = _norm(values.first);
    return values.skip(1).any((v) => _norm(v) != first);
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The rows comparing [infos], one picture each, in the order a reader
/// wants them: prompts first, then what made the picture, then the
/// settings (every setting any of them has, in the order first met).
List<CompareRow> compareRows(List<GenInfo> infos) {
  String loras(GenInfo i) => [
        for (final l in i.loras)
          l.weight == null ? _short(l.name) : '${_short(l.name)} ${_weight(l.weight!)}',
      ].join(', ');

  final rows = <CompareRow>[
    CompareRow('Prompt', [for (final i in infos) i.prompt], prompt: true),
    CompareRow('Negative prompt', [for (final i in infos) i.negative], prompt: true),
    CompareRow('Model', [for (final i in infos) i.model]),
    CompareRow('LoRAs', [for (final i in infos) loras(i)]),
    CompareRow('Seed', [for (final i in infos) i.seed]),
    CompareRow('Size', [for (final i in infos) i.width > 0 && i.height > 0 ? '${i.width} × ${i.height}' : '']),
    CompareRow('Made with', [for (final i in infos) i.source]),
  ];

  // Every setting, by its name with case and spacing aside, under the
  // label it was first met with. Seed and size are above already.
  const shown = {'seed', 'size'};
  final labels = <String, String>{};
  for (final i in infos) {
    for (final p in i.params) {
      final key = _key(p.key);
      if (shown.contains(key)) continue;
      labels.putIfAbsent(key, () => p.key);
    }
  }
  for (final MapEntry(key: key, value: label) in labels.entries) {
    rows.add(CompareRow(label, [
      for (final i in infos)
        i.params.firstWhere((p) => _key(p.key) == key, orElse: () => const MapEntry('', '')).value,
    ]));
  }
  // Rows nobody has anything for say nothing.
  return [
    for (final r in rows)
      if (r.values.any((v) => v.trim().isNotEmpty)) r,
  ];
}

String _key(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s_]+'), ' ').trim();

/// A LoRA's name without its folder or file extension.
String _short(String name) => name
    .split(RegExp(r'[/\\]'))
    .last
    .replaceFirst(RegExp(r'\.(safetensors|ckpt|pt|pth|bin)$', caseSensitive: false), '');

String _weight(double w) {
  var s = w.toStringAsFixed(2);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
}

/// How a piece of text compares with the text it is compared to.
enum Change { same, added, removed }

/// A run of text and how it compares.
class DiffPiece {
  const DiffPiece(this.text, this.change);
  final String text;
  final Change change;

  @override
  bool operator ==(Object other) => other is DiffPiece && other.text == text && other.change == change;

  @override
  int get hashCode => Object.hash(text, change);

  @override
  String toString() => '${change.name}:$text';
}

/// The words of [after] against those of [before], in order: what both
/// have, what [after] adds, and (where it was) what [before] had that
/// [after] does not. Words are compared case aside; the spaces and commas
/// between them are kept as [after] has them.
List<DiffPiece> wordDiff(String before, String after) {
  final a = _tokens(before);
  final b = _tokens(after);
  final aw = [for (final t in a) if (!_gap(t)) t];
  final bw = [for (final t in b) if (!_gap(t)) t];

  // Longest common subsequence of the words.
  final n = aw.length;
  final m = bw.length;
  final table = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      table[i][j] = aw[i].toLowerCase() == bw[j].toLowerCase()
          ? table[i + 1][j + 1] + 1
          : (table[i + 1][j] >= table[i][j + 1] ? table[i + 1][j] : table[i][j + 1]);
    }
  }

  final out = <DiffPiece>[];
  void put(String text, Change change) {
    if (text.isEmpty) return;
    if (out.isNotEmpty && out.last.change == change) {
      out[out.length - 1] = DiffPiece(out.last.text + text, change);
    } else {
      out.add(DiffPiece(text, change));
    }
  }

  // [after]'s words, each with the spaces and punctuation before it.
  final gaps = <String>[];
  var gap = '';
  for (final t in b) {
    if (_gap(t)) {
      gap += t;
    } else {
      gaps.add(gap);
      gap = '';
    }
  }
  final trailing = gap;

  var i = 0;
  var j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && aw[i].toLowerCase() == bw[j].toLowerCase()) {
      put(gaps[j], Change.same);
      put(bw[j], Change.same);
      i++;
      j++;
    } else if (j < m && (i == n || table[i][j + 1] >= table[i + 1][j])) {
      put(gaps[j], Change.same);
      put(bw[j], Change.added);
      j++;
    } else {
      // Spaced from what is either side of it.
      final spaced = out.isEmpty || RegExp(r'[\s,(\[]$').hasMatch(out.last.text);
      put(spaced ? '${aw[i]} ' : ' ${aw[i]}', Change.removed);
      i++;
    }
  }
  put(trailing, Change.same);
  return out;
}

/// Words, and the spaces and punctuation between them, in order.
List<String> _tokens(String s) => [
      for (final m in RegExp(r'[^\s,;|()\[\]{}]+|[\s,;|()\[\]{}]+').allMatches(s)) m.group(0)!,
    ];

bool _gap(String t) => RegExp(r'^[\s,;|()\[\]{}]+$').hasMatch(t);
