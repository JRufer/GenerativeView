import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'app_state.dart';
import 'platform.dart';

/// The runs in [jobs] that have just finished: each a remix on its own, or
/// everything sent in one batch once none of it is running or still being
/// sent ([batchOpen]). A run is one notification, however many pictures it
/// made. Failures have nothing saved and are left out; they stay on the
/// round button. Jobs answered with are added to [told].
List<List<RemixJob>> finishedRuns(List<RemixJob> jobs, Set<int> told, {required bool Function(String batch) batchOpen}) {
  final runs = <Object, List<RemixJob>>{};
  for (final job in jobs) {
    runs.putIfAbsent(job.batch ?? job.id, () => []).add(job);
  }
  final finished = <List<RemixJob>>[];
  for (final run in runs.values) {
    final batch = run.first.batch;
    if (run.any((j) => j.running) || (batch != null && batchOpen(batch))) continue;
    final fresh = [for (final j in run) if (j.saved.isNotEmpty && told.add(j.id)) j];
    if (fresh.isNotEmpty) finished.add(fresh);
  }
  return finished;
}

/// Keeps Android told about remixes: a quiet notification while any are
/// out, which also keeps the app waiting with the screen locked, and a
/// "done" notification for each run that finishes while the app is not on
/// screen. Tapping that one shows the Remixes collection.
class RemixAlerts with WidgetsBindingObserver {
  RemixAlerts(this.state);
  final AppState state;

  final Set<int> _told = {};
  int _waiting = 0;
  AppLifecycleState _life = AppLifecycleState.resumed;
  StreamSubscription<void>? _taps;

  void attach() {
    if (!Platform.isAndroid) return;
    WidgetsBinding.instance.addObserver(this);
    state.remixes.addListener(_changed);
    _taps = remixNotificationTaps.listen((_) => state.showRemixes());
    _changed();
  }

  void detach() {
    if (!Platform.isAndroid) return;
    WidgetsBinding.instance.removeObserver(this);
    state.remixes.removeListener(_changed);
    _taps?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _life = state;

  void _changed() {
    final jobs = state.remixes.value;
    final running = jobs.where((j) => j.running).length;
    if (running != _waiting) {
      _waiting = running;
      unawaited(setRemixesWaiting(running));
    }
    for (final run in finishedRuns(jobs, _told, batchOpen: state.remixBatchOpen)) {
      // On screen, the app's own "Remix Done" chip says it.
      if (_life == AppLifecycleState.resumed) continue;
      if (!state.prefFlag('pref_notify_remix', true)) continue;
      final n = run.fold<int>(0, (sum, job) => sum + job.saved.length);
      final pictures = n == 1 ? '1 picture' : '$n pictures';
      final see = 'Tap to see ${n == 1 ? 'it' : 'them'}.';
      unawaited(run.first.batch == null
          ? notifyRemixDone('Remix of ${run.first.name} is done', '$pictures saved beside it. $see')
          : notifyRemixDone('Breed is done', '$pictures saved beside the parents. $see'));
    }
  }
}
