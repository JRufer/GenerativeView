/// Prompts for redrawing part of a picture: a tile of a hires fix, or a
/// face or hand of the detail pass.
///
/// A part sent with the picture's whole prompt has every subject of that
/// prompt drawn into it again: a tile of sky grows a second girl, a hand
/// grows a face. So each part gets only what holds in it: the phrases that
/// only ask for quality, those about the look of the whole picture (its
/// medium, style and light), the LoRA tags, and the phrases the content
/// model sees in that part. Without the content model, the subjects are
/// left out altogether, which is what tiled upscalers do anyway.
library;

import 'detail_pass.dart' show DetailKind;

/// One phrase of the prompt as the core cuts it, and how it is marked.
class PiecePhrase {
  const PiecePhrase(this.text, {this.quality = false, this.look = false});
  final String text;

  /// Only asks for quality ("masterpiece", "8k").
  final bool quality;

  /// About the look of the whole picture ("oil painting", "soft lighting").
  final bool look;

  bool get everywhere => quality || look;
}

/// What leads a face's or hand's prompt, so the part is drawn as one.
const Map<DetailKind, String> pieceLead = {
  DetailKind.face: 'a detailed face, clear eyes',
  DetailKind.hand: 'a detailed hand, natural fingers, correct anatomy',
};

/// What is added to a face's or hand's negative prompt.
const Map<DetailKind, String> pieceAvoid = {
  DetailKind.face: 'deformed face, asymmetrical eyes',
  DetailKind.hand: 'extra fingers, missing fingers, fused fingers, deformed hand, face',
};

/// Phrases a hand is never redrawn with, even when the model sees them
/// close by: each would draw a person, or a face, into the hand.
final RegExp _notInHand = RegExp(
  r'\b(\d*(girls?|boys?)|wom[ae]n|m[ae]n|person|people|solo|face|faces|eyes?|hair|lips|mouth|nose|smile|smiling|expression|head|portrait|selfie)\b',
  caseSensitive: false,
);

/// The LoRA, hypernetwork and embedding tags of [prompt]: `<lora:x:0.8>`.
List<String> loraTags(String prompt) => [for (final m in RegExp(r'<[^<>]+>').allMatches(prompt)) m.group(0)!];

/// The phrases of a reply from the core's `phrases_in_parts`.
List<PiecePhrase> piecePhrasesFrom(Object? reply) => [
  for (final p in ((reply is Map ? reply['phrases'] : null) as List? ?? const []))
    if (p is Map && p['text'] is String) PiecePhrase(p['text'] as String, quality: p['quality'] == true, look: p['look'] == true),
];

/// Which phrases each part shows, from the same reply; null when the
/// content model could not say.
List<Set<int>>? pieceSeenFrom(Object? reply) {
  final parts = reply is Map ? reply['parts'] : null;
  if (parts is! List) return null;
  return [
    for (final part in parts) {for (final i in (part is List ? part : const [])) if (i is int) i},
  ];
}

/// The prompt for one part: [phrases] that hold everywhere and those in
/// [seen], in the prompt's order, after [kind]'s lead words, then [loras]
/// and [extra]. A tile with nothing left to say asks for detail.
String piecePrompt(
  List<PiecePhrase> phrases, {
  Set<int> seen = const {},
  List<String> loras = const [],
  DetailKind? kind,
  String extra = '',
}) {
  final words = <String>[
    if (kind != null) pieceLead[kind]!,
    for (var i = 0; i < phrases.length; i++)
      if (phrases[i].everywhere || (seen.contains(i) && !(kind == DetailKind.hand && _notInHand.hasMatch(phrases[i].text))))
        phrases[i].text,
  ];
  if (words.isEmpty) words.add('highly detailed, sharp focus');
  final extraWords = extra.trim();
  return [...words, if (extraWords.isNotEmpty) extraWords, ...loras].join(', ');
}

/// The negative prompt for one part.
String pieceNegative(String negative, {DetailKind? kind}) {
  final add = kind == null ? null : pieceAvoid[kind];
  if (add == null) return negative;
  return negative.trim().isEmpty ? add : '${negative.trim()}, $add';
}

/// Asks the core which phrases of [prompt] each of [boxes] (left, top,
/// right, bottom in the pixels of the picture at [path]) shows, and makes
/// a prompt for each. [kinds], when given, is each box's face or hand.
/// Anything going wrong in the core leaves the subjects out, never the
/// whole prompt in.
Future<List<String>> piecePrompts(
  Future<dynamic> Function(String method, Map<String, Object?> args) call, {
  required String path,
  required String prompt,
  required List<List<num>> boxes,
  List<DetailKind>? kinds,
  String extra = '',
}) async {
  Object? reply;
  try {
    reply = await call('phrases_in_parts', {'path': path, 'prompt': prompt, 'boxes': boxes});
  } catch (_) {
    reply = null;
  }
  final phrases = piecePhrasesFrom(reply);
  final seen = pieceSeenFrom(reply);
  final loras = loraTags(prompt);
  return [
    for (var i = 0; i < boxes.length; i++)
      piecePrompt(
        phrases,
        seen: seen != null && i < seen.length ? seen[i] : const {},
        loras: loras,
        kind: kinds?[i],
        extra: extra,
      ),
  ];
}
