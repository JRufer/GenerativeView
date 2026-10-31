/// Audience levels on the film-rating scale, as the core works them out
/// (see `core/src/audience.rs`). 0 is "not rated yet".
abstract final class Audience {
  static const int unknown = 0;
  static const int g = 1;
  static const int pg = 2;
  static const int pg13 = 3;
  static const int r = 4;
  static const int nc17 = 5;

  /// Every level a picture can have, lowest first.
  static const List<int> levels = [g, pg, pg13, r, nc17];

  static String label(int level) => switch (level) {
    g => 'G',
    pg => 'PG',
    pg13 => 'PG-13',
    r => 'R',
    nc17 => 'NC-17',
    _ => 'Not rated',
  };

  /// As written in a search (`audience:..pg13`).
  static String word(int level) => switch (level) {
    g => 'g',
    pg => 'pg',
    pg13 => 'pg13',
    r => 'r',
    nc17 => 'nc17',
    _ => 'none',
  };

  static int parse(String word) => switch (word.trim().toLowerCase().replaceAll('-', '')) {
    'g' => g,
    'pg' => pg,
    'pg13' => pg13,
    'r' => r,
    'nc17' || 'x' => nc17,
    _ => unknown,
  };

  /// What the level means, in a line.
  static String meaning(int level) => switch (level) {
    g => 'Nothing to worry about',
    pg => 'Mild action, swimwear, a little scary',
    pg13 => 'Suggestive, weapons, some blood',
    r => 'Nudity, gore',
    nc17 => 'Sexual or extreme content',
    _ => 'No prompt to read, and not looked at yet',
  };
}

/// What a picture's audience level rests on, for the info panel.
class AudienceInfo {
  const AudienceInfo({
    required this.level,
    required this.source,
    required this.prompt,
    required this.promptReasons,
    required this.image,
    required this.imageReasons,
    required this.model,
    required this.own,
  });

  factory AudienceInfo.fromJson(Map<String, dynamic> j) => AudienceInfo(
    level: (j['level'] as num?)?.toInt() ?? 0,
    source: j['source'] as String? ?? 'both',
    prompt: (j['prompt'] as num?)?.toInt() ?? 0,
    promptReasons: [
      for (final r in (j['prompt_reasons'] as List? ?? const []))
        if (r is Map) (phrase: '${r['phrase']}', level: (r['level'] as num).toInt(), topic: '${r['topic']}'),
    ],
    image: (j['image'] as num?)?.toInt(),
    imageReasons: [
      for (final r in (j['image_reasons'] as List? ?? const []))
        if (r is Map) (phrase: '${r['phrase']}', level: (r['level'] as num).toInt(), topic: '${r['topic']}'),
    ],
    model: j['model'] == true,
    own: (j['own'] as num?)?.toInt(),
  );

  /// The level that counts.
  final int level;

  /// 'image', 'prompt' or 'both'.
  final String source;
  final int prompt;
  final List<({String phrase, int level, String topic})> promptReasons;

  /// What the picture shows; null until content search has looked at it.
  final int? image;

  /// The descriptions that set [image], clearest first.
  final List<({String phrase, int level, String topic})> imageReasons;

  /// Whether the content-search model is installed.
  final bool model;

  /// The user's own say, which wins; null for none.
  final int? own;
}

/// A prompt changed to aim at an audience level.
class AudienceSteer {
  const AudienceSteer({
    required this.from,
    required this.to,
    required this.prompt,
    required this.negative,
    required this.removed,
    required this.addedNegative,
    required this.liftedNegative,
  });

  factory AudienceSteer.fromJson(Map<String, dynamic> j) {
    List<String> list(String k) => [for (final v in (j[k] as List? ?? const [])) '$v'];
    return AudienceSteer(
      from: (j['from'] as num?)?.toInt() ?? 0,
      to: (j['to'] as num?)?.toInt() ?? 0,
      prompt: j['prompt'] as String? ?? '',
      negative: j['negative'] as String? ?? '',
      removed: list('removed'),
      addedNegative: list('added_negative'),
      liftedNegative: list('lifted_negative'),
    );
  }

  final int from;
  final int to;
  final String prompt;
  final String negative;
  final List<String> removed;
  final List<String> addedNegative;
  final List<String> liftedNegative;

  bool get changesAnything => removed.isNotEmpty || addedNegative.isNotEmpty || liftedNegative.isNotEmpty;
}
