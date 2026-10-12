import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

/// The blue of the remix chips: a step brighter than the accent, so the chip
/// reads as something happening rather than one more control.
const Color _remixBlue = Color(0xFF3B7BF6);

/// How the remixes sent to a server are getting on: a blue chip that moves
/// while any is running, and one saying a remix is done that, tapped, goes
/// to the pictures it brought back.
class RemixStatus extends StatelessWidget {
  const RemixStatus({super.key, required this.state, this.compact = false});
  final AppState state;

  /// Fitted into the top bar rather than floating over the content.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<RemixJob>>(
      valueListenable: state.remixes,
      builder: (context, jobs, _) {
        final running = [for (final j in jobs) if (j.running) j];
        final done = [for (final j in jobs) if (!j.running) j];
        final chips = <Widget>[
          if (running.isNotEmpty)
            _RunningChip(
              key: const ValueKey<String>('remix-running'),
              jobs: running,
              compact: compact,
            ),
          if (done.isNotEmpty)
            _DoneChip(
              key: const ValueKey<String>('remix-done'),
              job: done.last,
              more: done.length - 1,
              compact: compact,
              onOpen: () => state.showRemix(done.last),
              onDismiss: () => state.dismissRemix(done.last),
            ),
        ];
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutBack,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: animation, child: child),
            ),
            child: chips.isEmpty
                ? const SizedBox.shrink(key: ValueKey<String>('remix-none'))
                : Row(
                    // Keyed by what shows, so running turning into done
                    // swaps with the animation rather than snapping.
                    key: ValueKey<String>('remix-${running.isNotEmpty}-${done.isNotEmpty}'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < chips.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        chips[i],
                      ],
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _ChipShape extends StatelessWidget {
  const _ChipShape({
    required this.child,
    required this.compact,
    this.background,
    this.onTap,
    this.tooltip,
  });
  final Widget child;
  final bool compact;
  final Widget? background;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(compact ? 16 : 20);
    Widget chip = Material(
      color: _remixBlue,
      elevation: compact ? 0 : 6,
      shadowColor: _remixBlue.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(borderRadius: radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            if (background != null) Positioned.fill(child: background!),
            ConstrainedBox(
              // Big enough to hit with a finger.
              constraints: BoxConstraints(minHeight: compact ? 32 : 40),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
                child: Center(widthFactor: 1, child: child),
              ),
            ),
          ],
        ),
      ),
    );
    if (tooltip != null) chip = Tooltip(message: tooltip, child: chip);
    return Semantics(button: onTap != null, liveRegion: true, child: chip);
  }
}

class _RunningChip extends StatefulWidget {
  const _RunningChip({super.key, required this.jobs, required this.compact});
  final List<RemixJob> jobs;
  final bool compact;

  @override
  State<_RunningChip> createState() => _RunningChipState();
}

class _RunningChipState extends State<_RunningChip> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.jobs.length;
    final names = widget.jobs.map((j) => j.name).join('\n');
    return _ChipShape(
      compact: widget.compact,
      tooltip: 'Waiting on the server for\n$names',
      // A band of light running across the chip, so it plainly is busy.
      background: AnimatedBuilder(
        animation: _sweep,
        builder: (context, _) {
          final t = _sweep.value * 2.4 - 0.7;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.white.withValues(alpha: 0),
                  Colors.white.withValues(alpha: 0.28),
                  Colors.white.withValues(alpha: 0),
                ],
                stops: [
                  (t - 0.3).clamp(0.0, 1.0),
                  t.clamp(0.0, 1.0),
                  (t + 0.3).clamp(0.0, 1.0),
                ],
              ),
            ),
          );
        },
      ),
      child: Row(
        key: const ValueKey<String>('remix-running-chip'),
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _sweep,
            builder: (context, child) => Transform.rotate(
              angle: _sweep.value * 2 * math.pi,
              child: child,
            ),
            child: Icon(Icons.autorenew, size: widget.compact ? 16 : 18, color: Colors.white),
          ),
          const SizedBox(width: 8),
          Text(
            n == 1 ? 'Remix Running' : '$n Remixes Running',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: widget.compact ? 12.5 : 13.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _DoneChip extends StatefulWidget {
  const _DoneChip({
    super.key,
    required this.job,
    required this.more,
    required this.compact,
    required this.onOpen,
    required this.onDismiss,
  });
  final RemixJob job;

  /// Other finished remixes waiting behind this one.
  final int more;
  final bool compact;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  State<_DoneChip> createState() => _DoneChipState();
}

class _DoneChipState extends State<_DoneChip> with SingleTickerProviderStateMixin {
  /// A short pop each time a remix finishes, to catch the eye.
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  )..forward();

  @override
  void didUpdateWidget(_DoneChip old) {
    super.didUpdateWidget(old);
    if (old.job.id != widget.job.id) _pop.forward(from: 0);
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.job.saved.length;
    final label = widget.more > 0 ? 'Remix Done (+${widget.more})' : 'Remix Done';
    return AnimatedBuilder(
      animation: _pop,
      builder: (context, child) {
        final t = _pop.value;
        // Up to 1.1 and settle back.
        final scale = 1 + 0.1 * math.sin(t * math.pi);
        return Transform.scale(scale: scale, child: child);
      },
      child: _ChipShape(
        compact: widget.compact,
        onTap: widget.onOpen,
        tooltip: 'Show ${count == 1 ? 'the remix' : 'the $count remixes'} of ${widget.job.name}',
        child: Row(
          key: const ValueKey<String>('remix-done-chip'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: widget.compact ? 16 : 18, color: Colors.white),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: widget.compact ? 12.5 : 13.5,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_forward, size: 16, color: Colors.white),
            const SizedBox(width: 2),
            // Put away without going there.
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                key: const ValueKey<String>('remix-done-dismiss'),
                tooltip: 'Dismiss',
                padding: EdgeInsets.zero,
                iconSize: 16,
                color: Colors.white.withValues(alpha: 0.85),
                onPressed: widget.onDismiss,
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
