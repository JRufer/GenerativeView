/// What the model of the user's taste (core/src/taste.rs) has learned from
/// their stars and flags, and what it makes of a picture.
library;

/// What the taste model has learned, or what it still needs.
class TasteStatus {
  const TasteStatus({
    this.ready = false,
    this.useful = false,
    this.learnedFrom = 0,
    this.liked = 0,
    this.disliked = 0,
    this.agreement = 0,
    this.needs = 5,
    this.judged = 0,
    this.seen = 0,
  });

  /// Whether there is a model at all.
  final bool ready;

  /// Whether it is good enough to suggest keepers and rejects.
  final bool useful;
  final int learnedFrom;

  /// Pictures liked (four stars or more, or kept) and disliked (two or
  /// fewer, or rejected) among those it learned from, or has so far.
  final int liked;
  final int disliked;

  /// Of pairs of a liked and a disliked picture it was not shown, the
  /// share it put the right way round.
  final double agreement;

  /// How many of each it needs.
  final int needs;

  /// Pictures rated or flagged anywhere, and of those, how many content
  /// search has looked at (only those can be learned from).
  final int judged;
  final int seen;

  factory TasteStatus.fromJson(Map<String, dynamic> j) {
    int n(String key) => (j[key] as num?)?.toInt() ?? 0;
    return TasteStatus(
      ready: j['ready'] == true,
      useful: j['useful'] == true,
      learnedFrom: n('learned_from'),
      liked: n('liked'),
      disliked: n('disliked'),
      agreement: (j['agreement'] as num?)?.toDouble() ?? 0,
      needs: (j['needs'] as num?)?.toInt() ?? 5,
      judged: n('judged'),
      seen: n('seen'),
    );
  }

  /// A sentence on where it stands, for the filter panel.
  String describe() {
    if (ready) {
      final share = (agreement * 100).round();
      final from = 'Learned from $learnedFrom ${learnedFrom == 1 ? 'picture' : 'pictures'} you rated or flagged';
      if (!useful) {
        return '$from, but they do not show a clear pattern yet ($share% right on pictures it was not shown), '
            'so it only sorts and suggests nothing. Rating more will help.';
      }
      return '$from. On pictures it was not shown, it put the one you liked above the one you did not $share% of the time.';
    }
    final unseen = judged - seen;
    final more = [
      if (liked < needs) '${needs - liked} more you like (4–5 stars or keep)',
      if (disliked < needs) '${needs - disliked} more you don\'t (1–2 stars or reject)',
    ];
    final lead = more.isEmpty ? 'Almost ready.' : 'Rate or flag ${more.join(' and ')} to teach it your taste.';
    if (unseen > 0) {
      return '$lead $unseen of the pictures you judged have not been looked at by content search yet; '
          'turn content search on in a folder to let it see them.';
    }
    return lead;
  }
}

/// What the taste model makes of one picture.
class TasteScore {
  const TasteScore({required this.stars, required this.verdict, required this.useful});

  /// The stars it would likely get, 1 to 5.
  final double stars;

  /// 'keep', 'reject' or 'unsure'.
  final String verdict;
  final bool useful;

  factory TasteScore.fromJson(Map<String, dynamic> j) => TasteScore(
        stars: (j['stars'] as num?)?.toDouble() ?? 0,
        verdict: j['verdict'] as String? ?? 'unsure',
        useful: j['useful'] == true,
      );
}
