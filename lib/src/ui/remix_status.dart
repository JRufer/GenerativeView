import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/backends.dart' show backendNames;
import '../render_queue.dart';
import '../theme.dart';
import 'queue_panel.dart';
import 'upscale_dialog.dart' show scaleText;

/// The blue of the activity button: a step brighter than the accent, so it
/// reads as something happening rather than one more control.
const Color _remixBlue = Color(0xFF3B7BF6);

/// Height kept clear of the card for the button and its margins.
const double _cardReserve = 110;

/// The card is never squeezed below this, however little room there is.
const double _cardLeast = 120;

/// Remixes and upscales under way, as one small round blue button: a
/// spinner while anything runs, a tick once something is done.
///
/// Over the grid it floats in the bottom right corner, out of the way of the
/// tiles' boxes; in the focus view it sits in the top bar ([compact]), so
/// nothing covers the picture.
///
/// Tapped or pressed and held while something runs, it opens a card listing
/// what is running (remixes waiting on the server, upscales with their
/// progress, each with a way to cancel it) and what is done. Tapped when all
/// is done, it goes straight to
/// the new pictures: remixes in the Remixes collection, upscales in the
/// Upscales collection, each picked out. Pressed and held (or right-clicked)
/// when done, or with only a problem left, it is put away without going
/// there.
class ActivityButton extends StatefulWidget {
  const ActivityButton({super.key, required this.state, this.compact = false});
  final AppState state;

  /// Fitted into the top bar: smaller, and the card opens downwards.
  final bool compact;

  @override
  State<ActivityButton> createState() => _ActivityButtonState();
}

/// What is going on, read once per build.
class _Activity {
  _Activity(AppState state)
      : remixesRunning = [for (final j in state.remixes.value) if (j.running) j],
        remixesDone = [for (final j in state.remixes.value) if (!j.running) j],
        upscales = state.upscales.value,
        waiting = state.upscalesWaiting.value,
        upscaled = state.upscaled.value,
        sending = state.afterUpscale.value,
        problems = state.problems.value,
        queued = state.renderQueue.queued.value,
        checking = state.renderQueue.checking.value;

  final List<RemixJob> remixesRunning;
  final List<RemixJob> remixesDone;
  final List<UpscaleJob> upscales;
  final int waiting;
  final List<String> upscaled;

  /// Hires fixes being prepared and sent, after their upscale.
  final List<String> sending;

  /// What went wrong, kept until put away.
  final List<String> problems;

  /// Renders waiting for a server that was offline when they were asked
  /// for, and whether the servers are being asked just now.
  final List<QueuedRender> queued;
  final bool checking;

  /// Only renders waiting in the queue: nothing running, wrong or done.
  bool get onlyQueued => queued.isNotEmpty && !busy && !anyDone && problems.isEmpty;

  /// How many renders the queue holds.
  int get queuedCount => queued.fold<int>(0, (n, e) => n + e.renders);

  /// The servers waited for: "InvokeAI", or "InvokeAI and ComfyUI".
  String get queuedFor => {for (final e in queued) backendNames[e.kind] ?? e.kind}.join(' and ');

  bool get busy => remixesRunning.isNotEmpty || upscales.isNotEmpty || waiting > 0 || sending.isNotEmpty;
  /// Every run that is done made new pictures, not remixes: they are shown
  /// in their own collection.
  bool get onlyNewDone => remixesDone.isNotEmpty && remixesDone.every((j) => j.label == 'new');

  bool get anyDone => remixesDone.isNotEmpty || upscaled.isNotEmpty;
  bool get none => !busy && !anyDone && problems.isEmpty && queued.isEmpty;

  /// What is running, one entry to cancel for each run: a Breed's pictures
  /// are one run, however many.
  List<_Run> get runs {
    final byRun = <Object, List<RemixJob>>{};
    for (final job in remixesRunning) {
      byRun.putIfAbsent(job.batch ?? job.id, () => []).add(job);
    }
    return [for (final jobs in byRun.values) _Run(jobs)];
  }

  /// Done of both kinds at once: there is no one place to go.
  bool get doneBothKinds => remixesDone.isNotEmpty && upscaled.isNotEmpty;

  /// Renders still to finish, for the badge: each picture a remix still
  /// waits on from the server (a remix of 4 counts 4, then 3 as one comes
  /// back), each hires fix being sent, and each upscale running or waiting.
  /// What is done is not counted; what waits in the queue for its server is.
  int get count =>
      remixesRunning.fold<int>(0, (n, j) => n + (j.remaining < 1 ? 1 : j.remaining)) +
      upscales.length +
      waiting +
      sending.length +
      queuedCount;

  /// One upscale and nothing else: its progress can be shown on the ring.
  double? get progress =>
      remixesRunning.isEmpty && waiting == 0 && sending.isEmpty && upscales.length == 1 ? upscales.single.progress : null;
}

/// A run of remixes, as it is cancelled.
class _Run {
  _Run(this.jobs);
  final List<RemixJob> jobs;

  String get label {
    final left = jobs.fold<int>(0, (n, j) => n + (j.remaining < 1 ? 1 : j.remaining));
    final job = jobs.first;
    final what = switch (job.label) {
      'hires' => 'Hires fix of ${job.name}',
      'bred' => 'Breed from ${job.name}',
      'new' => 'New picture: ${job.name}',
      _ => 'Remix of ${job.name}',
    };
    return left > 1 ? '$what, $left left' : what;
  }
}

class _ActivityButtonState extends State<ActivityButton> with SingleTickerProviderStateMixin {
  final OverlayPortalController _card = OverlayPortalController();
  final LayerLink _link = LayerLink();
  final Object _region = Object();

  /// A short pop each time something finishes, to catch the eye.
  late final AnimationController _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  int _doneBefore = 0;

  AppState get state => widget.state;

  late final Listenable _changes = Listenable.merge(
    [
      state.remixes,
      state.upscales,
      state.upscalesWaiting,
      state.upscaled,
      state.afterUpscale,
      state.problems,
      state.renderQueue.queued,
      state.renderQueue.checking,
    ],
  );

  @override
  void initState() {
    super.initState();
    _changes.addListener(_changed);
    _doneBefore = _Activity(state).remixesDone.length + state.upscaled.value.length;
  }

  @override
  void dispose() {
    _changes.removeListener(_changed);
    _pop.dispose();
    super.dispose();
  }

  void _changed() {
    final now = _Activity(state);
    final done = now.remixesDone.length + now.upscaled.length;
    if (done > _doneBefore) _pop.forward(from: 0);
    _doneBefore = done;
    // Nothing left to show: the card goes with the button.
    if (now.none && _card.isShowing) _card.hide();
    if (mounted) setState(() {});
  }

  void _toggle() => _card.isShowing ? _card.hide() : _card.show();

  /// How tall the card can be and stay on the screen, whichever way it
  /// opens: the whole view, less the system's bars and the keyboard, less
  /// what the button and its margins take.
  double _cardRoom(BuildContext context) {
    // The view itself: panels above here may have taken the bars out of
    // the MediaQuery, and the card is not inside them.
    final view = MediaQueryData.fromView(View.of(context));
    final room = view.size.height - view.padding.vertical - view.viewInsets.bottom - _cardReserve;
    return math.max(room, _cardLeast);
  }

  void _tap(_Activity now) {
    if (now.onlyQueued) {
      // Nothing else to choose between: straight to the queue.
      if (_card.isShowing) setState(_card.hide);
      openRenderQueue(context, state);
    } else if (now.busy || now.doneBothKinds || now.problems.isNotEmpty || now.queued.isNotEmpty) {
      setState(_toggle);
    } else if (now.remixesDone.isNotEmpty) {
      state.showRemixes();
    } else if (now.upscaled.isNotEmpty) {
      state.showUpscales();
    }
  }

  /// Held while something runs, the card opens to cancel it; otherwise
  /// what is finished is put away.
  void _hold(_Activity now) {
    if (now.busy || now.queued.isNotEmpty) {
      if (!_card.isShowing) setState(_card.show);
    } else {
      _dismissDone();
    }
  }

  void _dismissDone() {
    state.dismissDoneRemixes();
    state.dismissDoneUpscales();
    state.dismissProblems();
  }

  String _tooltip(_Activity now) {
    if (now.busy) {
      final parts = [
        if (now.remixesRunning.isNotEmpty) now.remixesRunning.length == 1 ? 'a remix' : '${now.remixesRunning.length} remixes',
        if (now.upscales.isNotEmpty || now.waiting > 0) now.upscales.length + now.waiting == 1 ? 'an upscale' : '${now.upscales.length + now.waiting} upscales',
      ];
      if (now.sending.isNotEmpty) parts.add(now.sending.length == 1 ? 'a hires fix' : '${now.sending.length} hires fixes');
      return 'Running ${parts.join(' and ')}: tap for details, or to cancel';
    }
    if (now.problems.isNotEmpty) return 'Something went wrong: tap to see what, press and hold to dismiss';
    if (now.queued.isNotEmpty) {
      final n = now.queuedCount;
      return '${n == 1 ? '1 render' : '$n renders'} queued until ${now.queuedFor} is online: tap to see the queue';
    }
    if (now.doneBothKinds) return 'Remixes and upscales done: tap to choose';
    final what = now.remixesDone.isNotEmpty
        ? (now.onlyNewDone
            ? (now.remixesDone.length == 1 ? 'New picture done' : '${now.remixesDone.length} new pictures done')
            : (now.remixesDone.length == 1 ? 'Remix done' : '${now.remixesDone.length} remixes done'))
        : (now.upscaled.length == 1 ? 'Upscale done' : '${now.upscaled.length} upscales done');
    return '$what: tap to see, press and hold to dismiss';
  }

  @override
  Widget build(BuildContext context) {
    final now = _Activity(state);
    final size = widget.compact ? 32.0 : 48.0;
    final Widget button = now.none
        ? const SizedBox.shrink(key: ValueKey<String>('activity-none'))
        : _RoundButton(
            key: const ValueKey<String>('activity-button'),
            size: size,
            compact: widget.compact,
            activity: now,
            pop: _pop,
            tooltip: _tooltip(now),
            onTap: () => _tap(now),
            onHold: () => _hold(now),
          );
    return TapRegion(
      groupId: _region,
      onTapOutside: (_) {
        if (_card.isShowing) setState(_card.hide);
      },
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _card,
          overlayChildBuilder: (context) => CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            // Over the grid it opens upwards from the corner; in the top
            // bar, downwards. Either way lined up on the right.
            targetAnchor: widget.compact ? Alignment.bottomRight : Alignment.topRight,
            followerAnchor: widget.compact ? Alignment.topRight : Alignment.bottomRight,
            offset: Offset(0, widget.compact ? 8 : -10),
            child: Align(
              alignment: widget.compact ? Alignment.topRight : Alignment.bottomRight,
              child: TapRegion(
                groupId: _region,
                child: _ActivityCard(
                  state: state,
                  activity: now,
                  maxHeight: _cardRoom(context),
                  onGo: () => setState(_card.hide),
                ),
              ),
            ),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutBack,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: animation, child: child),
            ),
            child: button,
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.size,
    required this.compact,
    required this.activity,
    required this.pop,
    required this.tooltip,
    required this.onTap,
    required this.onHold,
  });
  final double size;
  final bool compact;
  final _Activity activity;
  final Animation<double> pop;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback onHold;

  @override
  Widget build(BuildContext context) {
    final busy = activity.busy;
    final ring = size - (compact ? 8 : 12);
    final failed = !busy && activity.problems.isNotEmpty;
    // Nothing running, wrong or done: only renders waiting for a server.
    final waiting = activity.onlyQueued;
    final icon = busy
        ? (activity.remixesRunning.isEmpty && activity.sending.isEmpty ? Icons.photo_size_select_large : Icons.auto_fix_high)
        : failed
        ? Icons.priority_high
        : waiting
        ? Icons.schedule
        : Icons.check;
    final Widget face = Stack(
      alignment: Alignment.center,
      children: [
        if (busy)
          SizedBox(
            key: const ValueKey<String>('activity-spinner'),
            width: ring,
            height: ring,
            child: CircularProgressIndicator(
              value: activity.progress,
              strokeWidth: compact ? 2.2 : 2.8,
              color: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: activity.progress == null ? 0 : 0.25),
            ),
          ),
        Icon(
          icon,
          key: ValueKey<String>(
            busy ? 'activity-running-icon' : (failed ? 'activity-problem-icon' : (waiting ? 'activity-queued-icon' : 'activity-done-icon')),
          ),
          size: busy ? (compact ? 14 : 18) : (compact ? 19 : 26),
          color: Colors.white,
        ),
      ],
    );
    final count = activity.count;
    Widget circle = Material(
      color: failed ? Palette.danger : _remixBlue,
      shape: const CircleBorder(),
      elevation: compact ? 0 : 6,
      shadowColor: _remixBlue.withValues(alpha: 0.6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onHold,
        onSecondaryTap: onHold,
        child: SizedBox(width: size, height: size, child: face),
      ),
    );
    circle = Stack(
      clipBehavior: Clip.none,
      children: [
        circle,
        // How many renders are left, while any are: running, or queued.
        if ((busy || activity.queued.isNotEmpty) && count > 0)
          Positioned(
            right: compact ? -4 : -2,
            top: compact ? -4 : -2,
            child: Container(
              key: const ValueKey<String>('activity-count'),
              constraints: BoxConstraints(minWidth: compact ? 15 : 18),
              height: compact ? 15 : 18,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: _remixBlue, width: 1.5),
              ),
              child: Text(
                '$count',
                style: TextStyle(fontSize: compact ? 9.5 : 10.5, fontWeight: FontWeight.w700, color: _remixBlue, height: 1),
              ),
            ),
          ),
      ],
    );
    return Tooltip(
      message: tooltip,
      // Shown on hover; a long press belongs to the button.
      triggerMode: TooltipTriggerMode.manual,
      child: Semantics(
        button: true,
        liveRegion: true,
        label: tooltip,
        child: AnimatedBuilder(
          animation: pop,
          builder: (context, child) {
            // Up to 1.15 and settle back, each time something finishes.
            final scale = pop.isAnimating ? 1 + 0.15 * math.sin(pop.value * math.pi) : 1.0;
            return Transform.scale(scale: scale, child: child);
          },
          child: circle,
        ),
      ),
    );
  }
}

/// The card the button opens: what is running, and what is done.
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.state, required this.activity, required this.maxHeight, required this.onGo});
  final AppState state;
  final _Activity activity;

  /// Taller than this and it scrolls, so a long error cannot push anything
  /// off the screen.
  final double maxHeight;

  /// Called on going to new pictures, so the card closes.
  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final rows = <Widget>[
      if (a.remixesRunning.isNotEmpty)
        _Pill(
          key: const ValueKey<String>('activity-remix-running'),
          icon: const _Spinning(icon: Icons.autorenew),
          label: a.remixesRunning.length == 1 ? 'Remix Running' : '${a.remixesRunning.length} Remixes Running',
          tooltip: 'Waiting on the server for\n${a.remixesRunning.map((j) => j.name).join('\n')}',
        ),
      for (final run in a.runs)
        _RunRow(
          key: ValueKey<String>('activity-run-${run.jobs.first.id}'),
          label: run.label,
          onCancel: () => state.cancelRemixes(run.jobs.map((j) => j.id)),
        ),
      if (a.runs.length > 1)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const ValueKey<String>('activity-cancel-all'),
            onPressed: () => state.cancelRemixes(a.remixesRunning.map((j) => j.id)),
            child: const Text('Cancel all'),
          ),
        ),
      for (final s in a.sending)
        _Pill(
          key: ValueKey<String>('activity-sending-$s'),
          icon: const _Spinning(icon: Icons.autorenew),
          label: 'Sending $s',
          tooltip: 'Preparing the upscale and sending it to the server',
        ),
      for (final job in a.upscales) _UpscaleRow(key: ValueKey<String>('activity-upscale-${job.id}'), state: state, job: job, many: a.waiting > 0),
      if (a.waiting > 0)
        Row(
          key: const ValueKey<String>('activity-upscale-waiting'),
          children: [
            const SizedBox(width: 10),
            Expanded(
              child: Text('${a.waiting} more upscale${a.waiting == 1 ? '' : 's'} waiting', style: const TextStyle(fontSize: 12, color: Palette.muted)),
            ),
            TextButton(onPressed: state.cancelAllUpscales, child: const Text('Stop all')),
          ],
        ),
      if (a.remixesDone.isNotEmpty)
        _Pill(
          key: const ValueKey<String>('activity-remix-done'),
          icon: const Icon(Icons.check_circle, size: 18, color: Colors.white),
          label: a.onlyNewDone
              ? (a.remixesDone.length == 1 ? 'New Picture Done' : '${a.remixesDone.length} New Pictures Done')
              : (a.remixesDone.length == 1 ? 'Remix Done' : '${a.remixesDone.length} Remixes Done'),
          tooltip: 'Show them in ${a.onlyNewDone ? AppState.newCollection : AppState.remixCollection}',
          go: true,
          onTap: () {
            onGo();
            state.showRemixes();
          },
          onDismiss: state.dismissDoneRemixes,
        ),
      if (a.upscaled.isNotEmpty)
        _Pill(
          key: const ValueKey<String>('activity-upscale-done'),
          icon: const Icon(Icons.check_circle, size: 18, color: Colors.white),
          label: a.upscaled.length == 1 ? 'Upscale Done' : '${a.upscaled.length} Upscales Done',
          tooltip: 'Show ${a.upscaled.length == 1 ? 'it' : 'them'} in ${AppState.upscaleCollection}',
          go: true,
          onTap: () {
            onGo();
            state.showUpscales();
          },
          onDismiss: state.dismissDoneUpscales,
        ),
      // Waiting for a server that was offline: looked at, and cancelled,
      // in the queue's own panel.
      if (a.queued.isNotEmpty)
        _QueuedHeader(
          state: state,
          activity: a,
          onView: () {
            onGo();
            openRenderQueue(context, state);
          },
        ),
    ];
    if (a.problems.isNotEmpty) {
      rows.insert(
        0,
        Container(
          key: const ValueKey<String>('activity-problems'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Palette.danger.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Palette.danger.withValues(alpha: 0.5)),
          ),
          child: SelectableText(
            a.problems.join('\n\n'),
            style: const TextStyle(fontSize: 12.5, height: 1.35),
          ),
        ),
      );
    }
    return Material(
      key: const ValueKey<String>('activity-card'),
      color: Palette.raised,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Palette.line)),
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: 220, maxWidth: 320, maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Outside the scrolling part, so it can always be reached.
              if (a.problems.isNotEmpty) _ProblemsHeader(count: a.problems.length, onDismiss: state.dismissProblems),
              Flexible(
                child: SingleChildScrollView(
                  key: const ValueKey<String>('activity-card-scroll'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < rows.length; i++) ...[
                        if (i > 0) const SizedBox(height: 6),
                        rows[i],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Above what went wrong, and always on the card: how many, and the way to
/// put them away.
class _ProblemsHeader extends StatelessWidget {
  const _ProblemsHeader({required this.count, required this.onDismiss});
  final int count;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Palette.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              count == 1 ? 'Something went wrong' : '$count things went wrong',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(
            width: 40,
            height: 40,
            child: IconButton(
              key: const ValueKey<String>('activity-problems-dismiss'),
              tooltip: 'Dismiss',
              padding: EdgeInsets.zero,
              iconSize: 20,
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }
}

/// A blue row in the card, as the old chips were: what is happening, and
/// for what is done, a way to go there and one to put it away.
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.go = false,
    this.onTap,
    this.onDismiss,
  });
  final Widget icon;
  final String label;
  final String tooltip;
  final bool go;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: _remixBlue,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            // Big enough to hit with a finger.
            constraints: const BoxConstraints(minHeight: 38),
            child: Padding(
              padding: EdgeInsets.only(left: 12, right: onDismiss == null ? 12 : 2),
              child: Row(
                children: [
                  icon,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5)),
                  ),
                  if (go) const Icon(Icons.arrow_forward, size: 16, color: Colors.white),
                  if (onDismiss != null)
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        tooltip: 'Dismiss',
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        color: Colors.white.withValues(alpha: 0.85),
                        onPressed: onDismiss,
                        icon: const Icon(Icons.close),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Above the renders waiting in the queue: which server they wait for, how
/// it is looked for, and a way to look now.
class _QueuedHeader extends StatelessWidget {
  const _QueuedHeader({required this.state, required this.activity, required this.onView});
  final AppState state;
  final _Activity activity;

  /// Open the queue, to see what is in it and cancel from it.
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final queue = state.renderQueue;
    final n = activity.queuedCount;
    final how = queue.automatic ? 'Checked every ${everyText(queue.every.inSeconds)}.' : 'Not checked automatically.';
    return Container(
      key: const ValueKey<String>('activity-queued'),
      padding: const EdgeInsets.only(left: 10, top: 8, bottom: 2, right: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.schedule, size: 16, color: Palette.muted),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${n == 1 ? '1 render' : '$n renders'} queued',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Waiting for ${activity.queuedFor} to come online. $how',
                      style: const TextStyle(fontSize: 12, color: Palette.muted, height: 1.3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const ValueKey<String>('activity-queued-check'),
                onPressed: activity.checking ? null : () => queue.check(asked: true),
                child: Text(activity.checking ? 'Checking…' : 'Check now'),
              ),
              TextButton(
                key: const ValueKey<String>('activity-queued-view'),
                onPressed: onView,
                child: const Text('View queue'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One run of remixes under way, and a way to cancel it.
class _RunRow extends StatelessWidget {
  const _RunRow({super.key, required this.label, required this.onCancel});
  final String label;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
        ),
        IconButton(tooltip: 'Cancel', iconSize: 18, onPressed: onCancel, icon: const Icon(Icons.close)),
      ],
    );
  }
}

/// One upscale under way: its picture, how far it has got, and a way to
/// stop it.
class _UpscaleRow extends StatelessWidget {
  const _UpscaleRow({super.key, required this.state, required this.job, required this.many});
  final AppState state;
  final UpscaleJob job;

  /// More are waiting behind it.
  final bool many;

  @override
  Widget build(BuildContext context) {
    final label = 'Upscaling ${job.name} ${scaleText(job.factor)}×${job.then == null ? '' : ', ${job.then}'}';
    return Row(
      children: [
        const SizedBox(width: 10),
        const Icon(Icons.photo_size_select_large, size: 16, color: Palette.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: job.progress, minHeight: 3, backgroundColor: Palette.line, color: Palette.accent),
            ],
          ),
        ),
        IconButton(
          tooltip: many ? 'Stop this one' : 'Stop',
          iconSize: 18,
          onPressed: () => state.cancelUpscale(job.id),
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}

/// An icon turning round and round, for something under way.
class _Spinning extends StatefulWidget {
  const _Spinning({required this.icon});
  final IconData icon;

  @override
  State<_Spinning> createState() => _SpinningState();
}

class _SpinningState extends State<_Spinning> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _turn,
        builder: (context, child) => Transform.rotate(angle: _turn.value * 2 * math.pi, child: child),
        child: Icon(widget.icon, size: 18, color: Colors.white),
      );
}

/// Wraps a grid tile and, when [tick] changes to a non-zero number, plays a
/// short animation around it: a bump in size and rings of the accent colour
/// spreading out, so the eye goes to it.
class HighlightPulse extends StatefulWidget {
  const HighlightPulse({super.key, required this.tick, required this.child});

  /// 0 when this tile is not being pointed out.
  final int tick;
  final Widget child;

  @override
  State<HighlightPulse> createState() => _HighlightPulseState();
}

class _HighlightPulseState extends State<HighlightPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    if (widget.tick != 0) _c.forward(from: 0);
  }

  @override
  void didUpdateWidget(HighlightPulse old) {
    super.didUpdateWidget(old);
    if (widget.tick != 0 && widget.tick != old.tick) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        // The same shape whether or not it is playing, so the picture inside
        // is never rebuilt from scratch when the animation starts or ends.
        final playing = _c.isAnimating;
        final t = playing ? _c.value : 1.0;
        // A quick bump that settles in the first third.
        final bump = t < 0.35 ? math.sin(t / 0.35 * math.pi) * 0.08 : 0.0;
        // Three pulses, each fading.
        final ring = (t * 3) % 1;
        final fade = 1 - t;
        // Drawn over the picture: the grid paints later tiles on top of
        // earlier ones, so a glow spilling outside would be cut off.
        final pulse = (1 - ring) * fade;
        return Transform.scale(
          scale: 1 + bump,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              child!,
              if (playing)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _remixBlue.withValues(alpha: 0.22 * pulse),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: Color.lerp(Palette.accent, Colors.white, 0.35 * pulse)!.withValues(alpha: 0.4 + 0.6 * fade),
                          width: 2 + 4 * pulse,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
