import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'app_state.dart';
import 'platform.dart';

/// Keeps Android told about remixes: a quiet notification while any are
/// out, which also keeps the app waiting with the screen locked, and a
/// "Remix done" notification for each that comes back while the app is
/// not on screen. Tapping that one shows the Remixes collection.
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
  void didChangeAppLifecycleState(AppLifecycleState life) => _life = life;

  void _changed() {
    final jobs = state.remixes.value;
    final running = jobs.where((j) => j.running).length;
    if (running != _waiting) {
      _waiting = running;
      unawaited(setRemixesWaiting(running));
    }
    for (final job in jobs) {
      if (job.running || job.saved.isEmpty || !_told.add(job.id)) continue;
      // On screen, the app's own "Remix Done" chip says it.
      if (_life == AppLifecycleState.resumed) continue;
      final n = job.saved.length;
      unawaited(notifyRemixDone(
        'Remix of ${job.name} is done',
        '${n == 1 ? '1 picture' : '$n pictures'} saved beside it. Tap to see ${n == 1 ? 'it' : 'them'}.',
      ));
    }
  }
}
