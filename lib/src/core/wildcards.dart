/// Wildcards in a prompt: `{fox|wolf|owl}` picks one of its options for
/// each picture, and `__lighting__` one line of the word list called
/// "lighting". Options can hold more of either: `{red {fox|wolf}|owl}`.
///
/// The choice is made here, before anything is sent, so every server gets
/// a plain prompt and each picture's metadata says what it was made with.
/// A brace with no `|` in it, or a `__name__` with no list of that name, is
/// left as written (the second is reported, so the editor can say so).
library;

import 'dart:convert';
import 'dart:math' as math;

/// One piece of a prompt: plain text, a choice of options, or a word list.
sealed class WildcardPart {
  const WildcardPart(this.start, this.end);

  /// Where it sits in the text, `end` exclusive.
  final int start;
  final int end;
}

class WildText extends WildcardPart {
  const WildText(super.start, super.end, this.text);
  final String text;
}

class WildChoice extends WildcardPart {
  const WildChoice(super.start, super.end, this.options);
  final List<List<WildcardPart>> options;
}

class WildList extends WildcardPart {
  const WildList(super.start, super.end, this.name);
  final String name;
}

/// A prompt read for wildcards.
class WildcardPrompt {
  WildcardPrompt._(this.text, this.parts, this.lists);

  /// Read [text], with the word lists there are by name.
  factory WildcardPrompt.parse(String text, Map<String, List<String>> lists) {
    final reader = _Reader(text);
    return WildcardPrompt._(text, reader.sequence(top: true), {
      for (final e in lists.entries)
        e.key.toLowerCase(): [for (final w in e.value) if (w.trim().isNotEmpty) w.trim()],
    });
  }

  final String text;
  final List<WildcardPart> parts;
  final Map<String, List<String>> lists;

  /// Whether there is anything to choose.
  bool get hasChoices => _any(parts, (p) => p is WildChoice || (p is WildList && _known(p)));

  /// Choices written in braces.
  int get choiceCount => _all(parts).whereType<WildChoice>().length;

  /// The word lists named, in order, without repeats.
  List<String> get listNames => [
    for (final p in _all(parts))
      if (p is WildList) p.name,
  ].toSet().toList();

  /// Lists named that do not exist.
  List<String> get missingLists => [for (final n in listNames) if (!lists.containsKey(n.toLowerCase())) n];

  /// How many different prompts it can make. Large counts are capped at
  /// [cap], which is plenty to say "too many to make every one".
  int combinations({int cap = 1 << 20}) => _count(parts, cap);

  /// One prompt, picking each choice at random.
  String pick(math.Random random) => _tidy(_pick(parts, random));

  /// Every prompt it can make, in order (the last choice changing fastest),
  /// up to [limit].
  List<String> every({int limit = 256}) {
    final out = <String>[];
    for (final s in _every(parts)) {
      out.add(_tidy(s));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// [count] prompts: picked at random from [seed], or every combination in
  /// turn (and round again if [count] is more) when [all].
  List<String> expand(int count, {required bool all, int seed = 0}) {
    if (!hasChoices) return List.filled(count, text);
    if (all) {
      final every = this.every(limit: count);
      return [for (var i = 0; i < count; i++) every[i % every.length]];
    }
    final random = math.Random(seed);
    return [for (var i = 0; i < count; i++) pick(random)];
  }

  bool _known(WildList l) => (lists[l.name.toLowerCase()] ?? const []).isNotEmpty;

  int _count(List<WildcardPart> seq, int cap) {
    var n = 1;
    for (final p in seq) {
      final c = switch (p) {
        WildText() => 1,
        WildChoice(:final options) => options.fold<int>(0, (s, o) => math.min(cap, s + _count(o, cap))),
        WildList() => _known(p) ? lists[p.name.toLowerCase()]!.length : 1,
      };
      n = math.min(cap, n * c);
    }
    return n;
  }

  String _pick(List<WildcardPart> seq, math.Random random) {
    final b = StringBuffer();
    for (final p in seq) {
      switch (p) {
        case WildText(:final text):
          b.write(text);
        case WildChoice(:final options):
          b.write(_pick(options[random.nextInt(options.length)], random));
        case WildList(:final name):
          final words = lists[name.toLowerCase()];
          b.write(words == null || words.isEmpty ? '__${name}__' : words[random.nextInt(words.length)]);
      }
    }
    return b.toString();
  }

  Iterable<String> _every(List<WildcardPart> seq, [int from = 0]) sync* {
    if (from >= seq.length) {
      yield '';
      return;
    }
    final p = seq[from];
    final heads = switch (p) {
      WildText(:final text) => [text],
      WildChoice(:final options) => [for (final o in options) ..._every(o)],
      WildList(:final name) => (lists[name.toLowerCase()]?.isNotEmpty ?? false) ? lists[name.toLowerCase()]! : ['__${name}__'],
    };
    for (final head in heads) {
      for (final rest in _every(seq, from + 1)) {
        yield '$head$rest';
      }
    }
  }
}

/// A choice or list of [text], for drawing it in the editor: where it is,
/// and for a choice where its `|`s are.
class WildcardMark {
  const WildcardMark(this.start, this.end, {this.bars = const [], this.list, this.missing = false});
  final int start;
  final int end;
  final List<int> bars;

  /// The list's name, for a `__name__`.
  final String? list;

  /// A list that does not exist.
  final bool missing;
}

/// The choices and lists in [text], outermost first.
List<WildcardMark> wildcardMarks(String text, Map<String, List<String>> lists) {
  final known = {for (final k in lists.keys) k.toLowerCase()};
  final out = <WildcardMark>[];
  void walk(List<WildcardPart> seq) {
    for (final p in seq) {
      switch (p) {
        case WildText():
          break;
        case WildChoice(:final options):
          out.add(WildcardMark(p.start, p.end, bars: _barsIn(text, p.start, p.end)));
          for (final o in options) {
            walk(o);
          }
        case WildList(:final name):
          out.add(WildcardMark(p.start, p.end, list: name, missing: !known.contains(name.toLowerCase())));
      }
    }
  }

  walk(_Reader(text).sequence(top: true));
  return out;
}

/// Whether [text] has a choice or a list in it at all.
bool mayHaveWildcards(String text) => text.contains('|') || text.contains('__');

/// The `|`s at the top level of the braces from [start] to [end].
List<int> _barsIn(String text, int start, int end) {
  final bars = <int>[];
  var depth = 0;
  for (var i = start; i < end; i++) {
    final c = text[i];
    if (c == '\\') {
      i++;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
    } else if (c == '|' && depth == 1) {
      bars.add(i);
    }
  }
  return bars;
}

/// Spaces and commas left doubled by an empty option, made single.
String _tidy(String s) => s
    .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
    .replaceAll(RegExp(r'\s*,(\s*,)+'), ',')
    .replaceAll(RegExp(r'^\s*,\s*|\s*,\s*$'), '')
    .trim();

final RegExp _listName = RegExp(r'__([A-Za-z0-9][A-Za-z0-9 _\-/]*?)__');

class _Reader {
  _Reader(this.text);
  final String text;
  int at = 0;

  /// Parts up to the end, or (inside braces) up to a `|` or `}`.
  List<WildcardPart> sequence({bool top = false}) {
    final parts = <WildcardPart>[];
    var plain = at;
    void flush(int to) {
      if (to > plain) _addText(parts, plain, to);
    }

    while (at < text.length) {
      final c = text[at];
      if (c == '\\' && at + 1 < text.length) {
        at += 2;
        continue;
      }
      if (!top && (c == '|' || c == '}')) break;
      if (c == '{') {
        final close = _matching(at);
        if (close != null && _barsIn(text, at, close + 1).isNotEmpty) {
          flush(at);
          final start = at;
          at++;
          final options = <List<WildcardPart>>[];
          while (true) {
            options.add(sequence());
            if (at >= text.length || text[at] == '}') break;
            at++; // the |
          }
          at++; // the }
          parts.add(WildChoice(start, at, options));
          plain = at;
          continue;
        }
      }
      if (c == '_' && text.startsWith('__', at)) {
        final m = _listName.matchAsPrefix(text, at);
        if (m != null) {
          flush(at);
          parts.add(WildList(at, m.end, m.group(1)!.trim()));
          at = m.end;
          plain = at;
          continue;
        }
      }
      at++;
    }
    flush(at);
    return parts;
  }

  void _addText(List<WildcardPart> parts, int from, int to) {
    final raw = text.substring(from, to);
    parts.add(WildText(from, to, raw.replaceAllMapped(RegExp(r'\\([{}|])'), (m) => m.group(1)!)));
  }

  /// The `}` that closes the `{` at [open], if there is one.
  int? _matching(int open) {
    var depth = 0;
    for (var i = open; i < text.length; i++) {
      final c = text[i];
      if (c == '\\') {
        i++;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return null;
  }
}

/// Whether a part of [parts] (looking inside choices) passes [test].
bool _any(List<WildcardPart> parts, bool Function(WildcardPart) test) => _all(parts).any(test);

Iterable<WildcardPart> _all(List<WildcardPart> parts) sync* {
  for (final p in parts) {
    yield p;
    if (p is WildChoice) {
      for (final o in p.options) {
        yield* _all(o);
      }
    }
  }
}

/// Word lists as saved: a JSON object of name to lines. Anything else
/// reads as no lists.
Map<String, List<String>> wordListsFromJson(Object? raw) {
  if (raw is! String || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    return {
      for (final e in decoded.entries)
        if (e.value is List) '${e.key}': [for (final w in e.value as List) '$w'],
    };
  } on FormatException {
    return const {};
  }
}

/// A wildcard file's lines as a word list: one entry per line, with blank
/// lines and `#` comments left out, as the usual wildcard .txt files are.
List<String> wordListFromText(String text) => [
  for (final line in const LineSplitter().convert(text))
    if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#')) line.trim(),
];
