/// A spelling check for prompts.
///
/// The words it knows are an English word list (from pyspellchecker, MIT),
/// most common first, plus words at home in prompts but not in dictionaries
/// (`bokeh`, `sdxl`), plus every word that turns up in two or more of the
/// folder's own prompts, plus words the user added. Words with digits,
/// LoRA tags and embeddings are never questioned.
///
/// Suggestions are the known words one or two edits away, most common
/// first: the way most spelling slips happen.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

class Spelling {
  Spelling._(this._rank);

  /// Every known word, with its place in the frequency list (lower is more
  /// common). Folder and user words rank after the dictionary.
  final Map<String, int> _rank;

  static Spelling? _base;
  static Future<Spelling>? _loading;

  /// The dictionary and prompt words, loaded once.
  static Future<Spelling> load() {
    final done = _base;
    if (done != null) return Future.value(done);
    return _loading ??= _read();
  }

  static Future<Spelling> _read() async {
    final rank = <String, int>{};
    try {
      final packed = await rootBundle.load('assets/spelling/en_words.txt.gz');
      final text = utf8.decode(gzip.decode(packed.buffer.asUint8List(packed.offsetInBytes, packed.lengthInBytes)));
      var i = 0;
      for (final line in const LineSplitter().convert(text)) {
        if (line.isNotEmpty) rank.putIfAbsent(line, () => i++);
      }
    } catch (_) {
      // No list: nothing is flagged, which beats flagging everything.
    }
    try {
      final terms = await rootBundle.loadString('assets/spelling/prompt_terms.txt');
      for (final line in const LineSplitter().convert(terms)) {
        final w = line.trim().toLowerCase();
        if (w.isNotEmpty && !w.startsWith('#')) rank.putIfAbsent(w, () => 5000);
      }
    } catch (_) {}
    return _base = Spelling._(rank);
  }

  /// A checker that also knows [extra] words (the folder's, the user's).
  Spelling withWords(Iterable<String> extra) {
    final rank = Map<String, int>.of(_rank);
    for (final w in extra) {
      rank.putIfAbsent(w.toLowerCase(), () => 200000);
    }
    return Spelling._(rank);
  }

  bool get ready => _rank.isNotEmpty;

  /// Whether [word] (as it stands in the text) should be questioned.
  bool isMisspelled(String word) {
    if (!ready || word.length < 3) return false;
    if (word.contains(RegExp(r'[0-9_]'))) return false;
    // ALLCAPS is an acronym or a name, more often than not.
    if (word.length <= 5 && word == word.toUpperCase()) return false;
    final lower = word.toLowerCase().replaceAll('’', "'");
    if (_rank.containsKey(lower)) return false;
    // Possessives and plurals of known words.
    for (final end in ["'s", "s'", 's', 'es']) {
      if (lower.endsWith(end) && _rank.containsKey(lower.substring(0, lower.length - end.length))) return false;
    }
    // Hyphenated: fine if every part is.
    if (lower.contains('-')) return lower.split('-').every((p) => p.isEmpty || !isMisspelled(p));
    return true;
  }

  static const String _letters = "abcdefghijklmnopqrstuvwxyz'";

  Iterable<String> _edits(String w) sync* {
    for (var i = 0; i <= w.length; i++) {
      final (a, b) = (w.substring(0, i), w.substring(i));
      if (b.isNotEmpty) yield a + b.substring(1);
      if (b.length > 1) yield a + b[1] + b[0] + b.substring(2);
      for (final c in _letters.split('')) {
        if (b.isNotEmpty) yield a + c + b.substring(1);
        yield a + c + b;
      }
    }
  }

  /// Up to [count] corrections for [word], most likely first, in the same
  /// case as the word (`Forrest` → `Forest`).
  List<String> suggest(String word, {int count = 5}) {
    final lower = word.toLowerCase();
    final found = <String, int>{};
    void consider(String w, int penalty) {
      final r = _rank[w];
      if (r != null) {
        final score = r + penalty;
        if ((found[w] ?? 1 << 30) > score) found[w] = score;
      }
    }

    final first = _edits(lower).toSet();
    for (final w in first) {
      consider(w, 0);
    }
    if (found.length < count && lower.length <= 14) {
      // Two edits away: far more candidates, so ranked well behind.
      for (final e in first) {
        for (final w in _edits(e)) {
          consider(w, 300000);
        }
      }
    }
    final ranked = found.keys.toList()..sort((a, b) => found[a]!.compareTo(found[b]!));
    return [for (final w in ranked.take(count)) _sameCase(word, w)];
  }

  static String _sameCase(String like, String word) {
    if (like == like.toUpperCase() && like.length > 1) return word.toUpperCase();
    if (like.isNotEmpty && like[0] == like[0].toUpperCase() && like[0] != like[0].toLowerCase()) {
      return word[0].toUpperCase() + word.substring(1);
    }
    return word;
  }
}

/// The words of [text] that a spelling check should look at, with where
/// each starts: not inside `<lora:…>` tags, `embedding:` names, or the
/// weight numbers of `(word:1.2)`.
Iterable<(int, String)> promptWords(String text) sync* {
  final skip = <(int, int)>[];
  for (final m in RegExp(r'<[^>]*>|embedding:\S+|https?://\S+').allMatches(text)) {
    skip.add((m.start, m.end));
  }
  for (final m in RegExp(r"[A-Za-zÀ-ɏ][A-Za-zÀ-ɏ'’\-]*[A-Za-zÀ-ɏ]|[A-Za-z]").allMatches(text)) {
    if (skip.any((s) => m.start >= s.$1 && m.start < s.$2)) continue;
    // Glued to a digit (1girl, 4k, v2): a token, not a word.
    final before = m.start > 0 ? text[m.start - 1] : '';
    final after = m.end < text.length ? text[m.end] : '';
    if (RegExp(r'[0-9_]').hasMatch(before) || RegExp(r'[0-9_]').hasMatch(after)) continue;
    yield (m.start, m.group(0)!);
  }
}
