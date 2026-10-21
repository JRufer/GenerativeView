// The taste model as the app sees it: what it says about itself, and the
// `taste:` filter written into and read out of a search.
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/taste.dart';
import 'package:generativeview/src/ui/filter_sheet.dart';

void main() {
  test('a model in use says how much it learned and how far to trust it', () {
    final status = TasteStatus.fromJson({
      'ready': true,
      'useful': true,
      'learned_from': 140,
      'liked': 60,
      'disliked': 40,
      'agreement': 0.812,
      'needs': 5,
      'judged': 150,
      'seen': 140,
    });
    expect(status.ready, isTrue);
    expect(status.describe(), contains('Learned from 140 pictures'));
    expect(status.describe(), contains('81%'));
  });

  test('a model with no pattern says it suggests nothing', () {
    const status = TasteStatus(ready: true, learnedFrom: 30, agreement: 0.55);
    expect(status.describe(), contains('suggests nothing'));
  });

  test('without a model, it says what it still needs', () {
    final status = TasteStatus.fromJson({'ready': false, 'liked': 2, 'disliked': 5, 'needs': 5, 'judged': 9, 'seen': 7});
    final text = status.describe();
    expect(text, contains('3 more you like'));
    expect(text, isNot(contains("more you don't")));
    expect(text, contains('2 of the pictures you judged have not been looked at'));
  });

  test('the taste filter is read from a search and written back', () {
    final keep = FilterSet.parse('fox taste:keep');
    expect(keep.taste, 'keep');
    expect(keep.free, ['fox']);
    expect(keep.count, 1);
    expect(keep.toQuery(), 'fox taste:keep');

    final reject = FilterSet.parse('likely:rejects rating:>=2');
    expect(reject.taste, 'reject');
    expect(reject.toQuery(), 'rating:>=2 taste:reject');

    reject.taste = null;
    expect(reject.isEmpty, isFalse, reason: 'the rating is still on');
    expect(FilterSet.parse('taste:maybe').free, ['taste:maybe'], reason: 'not understood, kept as typed');
  });

  test('a score is read from the core', () {
    final score = TasteScore.fromJson({'stars': 4.25, 'verdict': 'keep', 'useful': true});
    expect(score.stars, 4.25);
    expect(score.verdict, 'keep');
  });
}
