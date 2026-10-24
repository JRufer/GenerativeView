/// A page for finding out why a touch is not doing what it should: a pad to
/// press and hold, and what the device and Flutter made of each press.
///
/// It sits on its own page, away from the grid and the panels, so a press
/// that works here and not there points at the app's screens, and one that
/// fails here too points at the device or Flutter.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'meta_panel.dart' show copyText;

/// Open the touch check.
Future<void> showTouchCheck(BuildContext context) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(builder: (context) => const TouchCheckPage()),
);

class TouchCheckPage extends StatefulWidget {
  const TouchCheckPage({super.key});

  @override
  State<TouchCheckPage> createState() => _TouchCheckPageState();
}

/// One press on the pad, as it went.
class _Press {
  _Press(this.kind, this.at);
  final PointerDeviceKind kind;
  final Offset at;
  final Stopwatch clock = Stopwatch()..start();
  int moves = 0;
  double furthest = 0;

  /// What happened, in order, each with when (ms after the finger went down).
  final List<String> events = [];

  /// How it ended: lifted, or cancelled by the system.
  String end = 'still down';
  int heldMs = 0;

  void note(String what) => events.add('$what at ${clock.elapsedMilliseconds} ms');
}

class _TouchCheckPageState extends State<TouchCheckPage> {
  final List<_Press> _presses = [];
  int _padMounts = 0;

  _Press? get _current => _presses.isEmpty ? null : _presses.last;

  void _note(String what) {
    final p = _current;
    if (p == null) return;
    setState(() => p.note(what));
  }

  String _report(BuildContext context) {
    final media = MediaQuery.of(context);
    final view = View.of(context);
    final slop = media.gestureSettings.touchSlop;
    final b = StringBuffer()
      ..writeln('Touch check')
      ..writeln('Screen: ${media.size.width.round()} × ${media.size.height.round()} at ${media.devicePixelRatio.toStringAsFixed(2)}x')
      ..writeln('Touch slop the device reports: ${view.gestureSettings.physicalTouchSlop?.toStringAsFixed(1) ?? 'none'} physical px')
      ..writeln('Touch slop in use: ${slop?.toStringAsFixed(1) ?? 'Flutter\'s default ($kTouchSlop)'}')
      ..writeln('Long press waits: ${kLongPressTimeout.inMilliseconds} ms')
      ..writeln('Pad built afresh: $_padMounts time(s)');
    for (final (i, p) in _presses.reversed.take(5).indexed) {
      b
        ..writeln()
        ..writeln('Press ${_presses.length - i}: ${p.kind.name}, ${p.end} after ${p.heldMs} ms, '
            '${p.moves} moves, drifted ${p.furthest.toStringAsFixed(1)} px at most')
        ..writeln('  ${p.events.isEmpty ? 'no gesture fired' : p.events.join(', ')}');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final report = _report(context);
    return Scaffold(
      backgroundColor: Palette.canvas,
      appBar: AppBar(
        title: const Text('Touch check'),
        actions: [
          IconButton(
            tooltip: 'Copy the report',
            icon: const Icon(Icons.content_copy),
            onPressed: () => copyText(context, report, 'touch report'),
          ),
          IconButton(
            tooltip: 'Start again',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(_presses.clear),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final pad = _Pad(
              onMounted: () => _padMounts++,
              onDown: (e) => setState(() => _presses.add(_Press(e.kind, e.position))),
              onMove: (e) {
                final p = _current;
                if (p == null) return;
                p.moves++;
                p.furthest = math.max(p.furthest, (e.position - p.at).distance);
              },
              onEnd: (e) {
                final p = _current;
                if (p == null) return;
                setState(() {
                  p.end = e is PointerCancelEvent ? 'cancelled by the system' : 'lifted';
                  p.heldMs = p.clock.elapsedMilliseconds;
                });
              },
              onTap: () => _note('tap'),
              onTapCancel: () => _note('tap given up'),
              onLongPressStart: () => _note('LONG PRESS'),
              onLongPressCancel: () => _note('long press given up'),
            );
            final text = Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                child: SelectableText(
                  report,
                  style: const TextStyle(fontSize: 13, height: 1.45, color: Palette.text, fontFamily: 'monospace'),
                ),
              ),
            );
            final wide = box.maxWidth > box.maxHeight;
            return wide
                ? Row(children: [Expanded(child: pad), Expanded(child: text)])
                : Column(children: [Expanded(child: pad), Expanded(child: text)]);
          },
        ),
      ),
    );
  }
}

/// The pad: a plain GestureDetector, as every press-and-hold in the app
/// uses, with the raw pointer events beside it.
class _Pad extends StatefulWidget {
  const _Pad({
    required this.onMounted,
    required this.onDown,
    required this.onMove,
    required this.onEnd,
    required this.onTap,
    required this.onTapCancel,
    required this.onLongPressStart,
    required this.onLongPressCancel,
  });

  final VoidCallback onMounted;
  final ValueChanged<PointerDownEvent> onDown;
  final ValueChanged<PointerMoveEvent> onMove;
  final ValueChanged<PointerEvent> onEnd;
  final VoidCallback onTap;
  final VoidCallback onTapCancel;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressCancel;

  @override
  State<_Pad> createState() => _PadState();
}

class _PadState extends State<_Pad> {
  @override
  void initState() {
    super.initState();
    widget.onMounted();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: widget.onDown,
      onPointerMove: widget.onMove,
      onPointerUp: widget.onEnd,
      onPointerCancel: widget.onEnd,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapCancel: widget.onTapCancel,
        onLongPressStart: (_) => widget.onLongPressStart(),
        onLongPressCancel: widget.onLongPressCancel,
        child: Container(
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Palette.tile,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Palette.line),
          ),
          alignment: Alignment.center,
          child: const Text(
            'Press and hold here',
            style: TextStyle(fontSize: 16, color: Palette.muted),
          ),
        ),
      ),
    );
  }
}
