/// Prompt weights: `(red fox:1.2)` makes "red fox" count for more, `(fog:0.6)`
/// for less. The syntax ComfyUI, A1111, Forge and InvokeAI's compel all
/// read (InvokeAI also has its own `+`/`-`, which this leaves alone).
library;

import 'package:flutter/services.dart';

/// The lightest and heaviest weight offered, the step between, and the
/// weight of words left as they are.
const double minWeight = 0.1;
const double maxWeight = 2.0;
const double weightStep = 0.05;
const double plainWeight = 1.0;

/// A weighted group in a prompt: `(` [open], the words from [textStart] to
/// [textEnd], `:`, the number, `)` at [close].
class WeightGroup {
  const WeightGroup(this.open, this.textStart, this.textEnd, this.close, this.weight);
  final int open;
  final int textStart;
  final int textEnd;
  final int close;
  final double weight;

  /// Just past the closing bracket.
  int get end => close + 1;
}

/// Weights as prompts write them: `1.0`, `1.05`, `0.8`.
String formatWeight(double w) {
  final s = w.toStringAsFixed(2);
  return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
}

double snapWeight(double w) {
  final snapped = (w / weightStep).round() * weightStep;
  return double.parse(snapped.clamp(minWeight, maxWeight).toStringAsFixed(2));
}

final RegExp _number = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*$');

/// Every weighted group in [text], outermost and innermost alike.
List<WeightGroup> weightGroups(String text) {
  final out = <WeightGroup>[];
  final stack = <int>[];
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == r'\') {
      i++; // an escaped bracket is just a bracket
      continue;
    }
    if (c == '(') {
      stack.add(i);
    } else if (c == ')' && stack.isNotEmpty) {
      final open = stack.removeLast();
      final inner = text.substring(open + 1, i);
      final colon = inner.lastIndexOf(':');
      if (colon <= 0) continue;
      final m = _number.firstMatch(inner.substring(colon + 1));
      if (m == null) continue;
      out.add(WeightGroup(open, open + 1, open + 1 + colon, i, double.parse(m.group(1)!)));
    }
  }
  return out;
}

/// The innermost group that [selection] is the words of, sits inside, or
/// is exactly (brackets and all).
WeightGroup? groupAt(String text, TextSelection selection) {
  if (!selection.isValid) return null;
  final (s, e) = (selection.start, selection.end);
  WeightGroup? best;
  for (final g in weightGroups(text)) {
    final whole = s == g.open && e == g.end;
    final inside = s >= g.textStart && e <= g.textEnd;
    if (!whole && !inside) continue;
    if (best == null || g.open > best.open) best = g;
  }
  return best;
}

/// The words a selection weights: trimmed of spaces and of commas at its
/// ends, so that a sloppy drag still takes just the words.
TextRange trimmedRange(String text, TextSelection selection) {
  var s = selection.start;
  var e = selection.end;
  bool junk(String c) => c.trim().isEmpty || c == ',';
  while (s < e && junk(text[s])) {
    s++;
  }
  while (e > s && junk(text[e - 1])) {
    e--;
  }
  return TextRange(start: s, end: e);
}

/// [value] with [weight] given to what [value]'s selection covers: the
/// group it is in has its number changed, or the words are wrapped as
/// `(words:weight)`. The selection ends up on the words, so a further
/// change goes to the same group.
TextEditingValue applyWeight(TextEditingValue value, double weight) {
  final text = value.text;
  final w = formatWeight(snapWeight(weight));
  final group = groupAt(text, value.selection);
  if (group != null) {
    final out = text.replaceRange(group.textEnd, group.close, ':$w');
    return TextEditingValue(
      text: out,
      selection: TextSelection(baseOffset: group.textStart, extentOffset: group.textEnd),
    );
  }
  final range = trimmedRange(text, value.selection);
  if (range.isCollapsed) return value;
  final words = range.textInside(text);
  final out = text.replaceRange(range.start, range.end, '($words:$w)');
  return TextEditingValue(
    text: out,
    selection: TextSelection(baseOffset: range.start + 1, extentOffset: range.start + 1 + words.length),
  );
}

/// [value] with the weight around its selection taken off: the words alone
/// again, still selected.
TextEditingValue removeWeight(TextEditingValue value) {
  final group = groupAt(value.text, value.selection);
  if (group == null) return value;
  final words = value.text.substring(group.textStart, group.textEnd);
  final out = value.text.replaceRange(group.open, group.end, words);
  return TextEditingValue(
    text: out,
    selection: TextSelection(baseOffset: group.open, extentOffset: group.open + words.length),
  );
}

/// The weight the selection has now: its group's, or [plainWeight].
double weightAt(TextEditingValue value) => groupAt(value.text, value.selection)?.weight ?? plainWeight;
