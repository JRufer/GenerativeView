import 'package:flutter/services.dart' show TextEditingValue, TextRange, TextSelection;

import 'prompt_weights.dart';

/// Where [phrase] is in [text], ignoring case, as whole words; underscores
/// and runs of spaces in the text count as one space (prompt check reads
/// `red_fox` as "red fox"). Null when it is not there.
TextRange? findPhrase(String text, String phrase) {
  final words = phrase.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map(RegExp.escape).toList();
  if (words.isEmpty) return null;
  final pattern = RegExp(r'(?<![\p{L}\p{N}])' + words.join(r'[\s_]+') + r'(?![\p{L}\p{N}])', caseSensitive: false, unicode: true);
  final m = pattern.firstMatch(text);
  return m == null ? null : TextRange(start: m.start, end: m.end);
}

/// [value] with [phrase] given [weight] (see [applyWeight]) and selected,
/// so the weight slider under it can fine-tune it. Unchanged if the phrase
/// is not in it.
TextEditingValue weightPhrase(TextEditingValue value, String phrase, double weight) {
  final range = findPhrase(value.text, phrase);
  if (range == null) return value;
  return applyWeight(value.copyWith(selection: TextSelection(baseOffset: range.start, extentOffset: range.end)), weight);
}

/// [value] with [phrase] selected, or unchanged if it is not there.
TextEditingValue selectPhrase(TextEditingValue value, String phrase) {
  final range = findPhrase(value.text, phrase);
  if (range == null) return value;
  final group = groupAt(value.text, TextSelection(baseOffset: range.start, extentOffset: range.end));
  final (from, to) = group != null && group.textStart <= range.start && group.textEnd >= range.end ? (group.textStart, group.textEnd) : (range.start, range.end);
  return value.copyWith(selection: TextSelection(baseOffset: from, extentOffset: to));
}

/// [text] without [phrases]: each taken out with its weight brackets and
/// the comma that set it off from the next (or, at the end, the last).
String removePhrases(String text, List<String> phrases) {
  var out = text;
  for (final p in phrases) {
    final r = findPhrase(out, p);
    if (r == null) continue;
    var start = r.start;
    var end = r.end;
    final group = groupAt(out, TextSelection(baseOffset: r.start, extentOffset: r.end));
    if (group != null && group.textStart == r.start && group.textEnd == r.end) {
      start = group.open;
      end = group.end;
    }
    final after = RegExp(r'\s*,\s*').matchAsPrefix(out, end);
    if (after != null) {
      end = after.end;
    } else {
      final before = RegExp(r'\s*,\s*$').firstMatch(out.substring(0, start));
      if (before != null) start = before.start;
    }
    out = out.replaceRange(start, end, '');
  }
  return out.trim();
}

/// [text] with [phrase] added at the end, after a comma; unchanged if it is
/// there already.
String addPhrase(String text, String phrase) {
  if (findPhrase(text, phrase) != null) return text;
  final t = text.trimRight();
  if (t.isEmpty) return phrase;
  return t.endsWith(',') ? '$t $phrase' : '$t, $phrase';
}

/// [prompt] cut into the phrases it asks for, as content search reads it
/// (see `prompt_phrases` in core/src/clip/mod.rs): at commas, full stops,
/// semicolons, line breaks and `BREAK`; weights, brackets and LoRA tags
/// taken off; each phrase once.
List<String> promptPhrases(String prompt) {
  var text = prompt.replaceAll(RegExp(r'<[^>]*>'), ',').replaceAll('BREAK', ',');
  text = text.replaceAll(RegExp(r':\s*-?[\d.]+\s*(?=[)\]}])'), '');
  // Brackets go (an escaped one is part of the text), then the escapes.
  text = text.replaceAll(RegExp(r'(?<!\\)[()\[\]{}]'), ' ');
  text = text.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!).replaceAll('_', ' ');
  final out = <String>[];
  for (final piece in text.split(RegExp(r'[,;.\n\r|]'))) {
    final phrase = piece.trim().split(RegExp(r'\s+')).join(' ').replaceAll(RegExp(r'^[-"!?*#/:+]+|[-"!?*#/:+]+$'), '').trim();
    if (!RegExp(r'\p{L}', unicode: true).hasMatch(phrase) || phrase.startsWith('embedding')) continue;
    if (out.any((p) => p.toLowerCase() == phrase.toLowerCase())) continue;
    out.add(phrase);
    if (out.length == 40) break;
  }
  return out;
}
