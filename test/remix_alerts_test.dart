import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/remix_alerts.dart';

RemixJob running(int id, {String? batch}) => RemixJob(id, 'p$id.png', batch: batch);
RemixJob done(int id, {String? batch, int pictures = 1}) =>
    RemixJob(id, 'p$id.png', batch: batch).finished([for (var i = 0; i < pictures; i++) '/x/p${id}_$i.png']);

void main() {
  bool none(String _) => false;

  test('a batch is told of once, when the last of it is back', () {
    final told = <int>{};
    final jobs = [done(1, batch: 'a'), done(2, batch: 'a'), running(3, batch: 'a')];
    expect(finishedRuns(jobs, told, batchOpen: none), isEmpty);
    expect(told, isEmpty);

    jobs[2] = done(3, batch: 'a');
    final runs = finishedRuns(jobs, told, batchOpen: none);
    expect(runs.single.map((j) => j.id), [1, 2, 3]);
    expect(finishedRuns(jobs, told, batchOpen: none), isEmpty, reason: 'told of once');
  });

  test('a batch still being sent waits, even with all of it back', () {
    final told = <int>{};
    final jobs = [done(1, batch: 'a')];
    expect(finishedRuns(jobs, told, batchOpen: (b) => b == 'a'), isEmpty);
    expect(finishedRuns(jobs, told, batchOpen: none).single.single.id, 1);
  });

  test('runs side by side are told of separately', () {
    final told = <int>{};
    final jobs = [done(1, pictures: 6), done(2, batch: 'a'), running(3, batch: 'b'), done(4, batch: 'b'), done(5)];
    final runs = finishedRuns(jobs, told, batchOpen: none);
    expect(runs.map((r) => r.map((j) => j.id).toList()), [
      [1],
      [2],
      [5],
    ]);
  });

  test('what failed is not counted; a run with nothing saved says nothing', () {
    final told = <int>{};
    final jobs = [const RemixJob(1, 'p1.png', running: false, batch: 'a'), done(2, batch: 'a')];
    expect(finishedRuns(jobs, told, batchOpen: none).single.single.id, 2);
    expect(finishedRuns([const RemixJob(3, 'p3.png', running: false)], told, batchOpen: none), isEmpty);
  });
}
