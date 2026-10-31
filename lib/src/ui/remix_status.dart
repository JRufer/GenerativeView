import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'upscale_dialog.dart' show scaleText;

/// The blue of the activity button: a step brighter than the accent, so it
/// reads as something happening rather than one more control.
const Color _remixBlue = Color(0xFF3B7BF6);

/// Remixes and upscales under way, as one small round blue button: a
/// spinner while anything runs, a tick once something is done.
///
/// Over the grid it floats in the bottom right corner, out of the way of the
/// tiles' boxes; in the focus view it sits in the top bar ([compact]), so
/// nothing covers the picture.
///
/// Tapped while something runs, it opens a card listing what is running
/// (remixes waiting on the server, upscales with their progress and a way to
/// stop each) and what is done. Tapped when all is done, it goes straight to
/// the new pictures: remixes in the Remixes collection, upscales in their
/// folder, each picked out. Pressed and held (or right-clicked) when done, it
/// is put away without going there.
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
        problems = state.problems.value;

  final List<RemixJob> remixesRunning;
  final List<RemixJob> remixesDone;
  final List<UpscaleJob> upscales;
  final int waiting;
  final List<String> upscaled;

  /// Hires fixes being prepared and sent, after their upscale.
  final List<String> sending;

  /// What went wrong, kept until put away.
  final List<String> problems;

  bool get busy => remixesRunning.isNotEmpty || upscales.isNotEmpty || waiting > 0 || sending.isNotEmpty;
  bool get anyDone => remixesDone.isNotEmpty || upscaled.isNotEmpty;
  bool get none => !busy && !anyDone && problems.isEmpty;

  /// Done of both kinds at once: there is no one place to go.
  bool get doneBothKinds => remixesDone.isNotEmpty && upscaled.isNotEmpty;

  /// Things running or done, for the badge.
  int get count =>
      remixesRunning.length + upscales.length + waiting + sending.length + remixesDone.length + upscaled.length + problems.length;

  /// One upscale and nothing else: its progress can be shown on the ring.
  double? get progress =>
      remixesRunning.isEmpty && waiting == 0 && sending.isEmpty && upscales.length == 1 ? upscales.single.progress : null;
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
    [state.remixes, state.upscales, state.upscalesWaiting, state.upscaled, state.afterUpscale, state.problems],
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

  void _tap(_Activity now) {
    if (now.busy || now.doneBothKinds || now.problems.isNotEmpty) {
      setState(_toggle);
    } else if (now.remixesDone.isNotEmpty) {
      state.showRemixes();
    } else if (now.upscaled.isNotEmpty) {
      state.showUpscales();
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
      return 'Running ${parts.join(' and ')}: tap for details';
    }
    if (now.problems.isNotEmpty) return 'Something went wrong: tap to see what';
    if (now.doneBothKinds) return 'Remixes and upscales done: tap to choose';
    final what = now.remixesDone.isNotEmpty
        ? (now.remixesDone.length == 1 ? 'Remix done' : '${now.remixesDone.length} remixes done')
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
            onDismiss: !now.busy && (now.anyDone || now.problems.isNotEmpty) ? _dismissDone : null,
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
                child: _ActivityCard(state: state, activity: now, onGo: () => setState(_card.hide)),
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
    required this.onDismiss,
  });
  final double size;
  final bool compact;
  final _Activity activity;
  final Animation<double> pop;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final busy = activity.busy;
    final ring = size - (compact ? 8 : 12);
    final failed = !busy && activity.problems.isNotEmpty;
    final icon = busy
        ? (activity.remixesRunning.isEmpty && activity.sending.isEmpty ? Icons.photo_size_select_large : Icons.auto_fix_high)
        : failed
        ? Icons.priority_high
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
          key: ValueKey<String>(busy ? 'activity-running-icon' : (failed ? 'activity-problem-icon' : 'activity-done-icon')),
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
        onLongPress: onDismiss,
        onSecondaryTap: onDismiss,
        child: SizedBox(width: size, height: size, child: face),
      ),
    );
    circle = Stack(
      clipBehavior: Clip.none,
      children: [
        circle,
        // How many, when more than one thing is going on.
        if (count > 1)
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
      // Shown on hover; a long press belongs to the button (put away).
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
  const _ActivityCard({required this.state, required this.activity, required this.onGo});
  final AppState state;
  final _Activity activity;

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
          label: a.remixesDone.length == 1 ? 'Remix Done' : '${a.remixesDone.length} Remixes Done',
          tooltip: 'Show them in ${AppState.remixCollection}',
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
          tooltip: 'Show ${a.upscaled.length == 1 ? 'it' : 'them'} in the folder',
          go: true,
          onTap: () {
            onGo();
            state.showUpscales();
          },
          onDismiss: state.dismissDoneUpscales,
        ),
    ];
    if (a.problems.isNotEmpty) {
      rows.add(
        Container(
          key: const ValueKey<String>('activity-problems'),
          padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
          decoration: BoxDecoration(
            color: Palette.danger.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Palette.danger.withValues(alpha: 0.5)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.error_outline, size: 16, color: Palette.danger),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  a.problems.join('\n\n'),
                  style: const TextStyle(fontSize: 12.5, height: 1.35),
                ),
              ),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  key: const ValueKey<String>('activity-problems-dismiss'),
                  tooltip: 'Dismiss',
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  onPressed: state.dismissProblems,
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
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
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(8),
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
