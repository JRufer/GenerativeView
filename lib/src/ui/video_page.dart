import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/models.dart';
import '../core/thumb_cache.dart';
import '../theme.dart';
import 'thumb_image.dart';

/// Plays one video in the focus view. It loops, starts when its page becomes
/// the current one and pauses when it is swiped away.
class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.item,
    required this.cache,
    required this.active,
    required this.playbackAvailable,
  });

  final MediaItem item;
  final ThumbCache cache;
  final bool active;
  final bool playbackAvailable;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  Player? _player;
  VideoController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(VideoPage old) {
    super.didUpdateWidget(old);
    if (old.item.version != widget.item.version) {
      _stop();
      if (widget.active) _start();
    } else if (widget.active && !old.active) {
      final player = _player;
      if (player == null) {
        _start();
      } else {
        unawaited(player.play());
      }
    } else if (!widget.active && old.active) {
      unawaited(_player?.pause());
    }
  }

  void _start() {
    if (!widget.playbackAvailable || _player != null) return;
    try {
      final player = Player();
      _player = player;
      _controller = VideoController(player);
      unawaited(player.setPlaylistMode(PlaylistMode.single));
      unawaited(player.open(Media(Uri.file(widget.item.path).toString())));
      player.stream.error.listen((_) {
        if (mounted) setState(() => _failed = true);
      });
    } catch (_) {
      _failed = true;
    }
  }

  void _stop() {
    final player = _player;
    _player = null;
    _controller = null;
    _failed = false;
    if (player != null) unawaited(player.dispose());
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final poster = ThumbImage(
      cache: widget.cache,
      item: widget.item,
      tier: 1,
      fit: BoxFit.contain,
    );
    if (controller == null || _failed) {
      return Stack(
        fit: StackFit.expand,
        children: [
          poster,
          if (!widget.playbackAvailable || _failed)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.all(20),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Palette.raised,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Palette.line),
                ),
                child: Text(
                  _failed
                      ? 'This video could not be played.'
                      : 'Video playback is unavailable. On Linux, install mpv to enable it.',
                  style: const TextStyle(fontSize: 13, color: Palette.muted),
                ),
              ),
            ),
        ],
      );
    }
    final player = _player!;
    return Stack(
      fit: StackFit.expand,
      children: [
        poster,
        // Our own controls: the stock ones claim double-tap, which here
        // means "back to the grid".
        Video(controller: controller, fill: Colors.transparent, controls: NoVideoControls),
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: player.playOrPause,
        ),
        Align(alignment: Alignment.bottomCenter, child: _Transport(player: player)),
      ],
    );
  }
}

/// Play/pause, a seek bar and the clock. Deliberately small.
class _Transport extends StatelessWidget {
  const _Transport({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      constraints: const BoxConstraints(maxWidth: 640),
      decoration: BoxDecoration(
        color: const Color(0xCC151518),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Palette.line),
      ),
      child: Row(
        children: [
          StreamBuilder<bool>(
            stream: player.stream.playing,
            initialData: player.state.playing,
            builder: (context, playing) => IconButton(
              tooltip: playing.data == true ? 'Pause' : 'Play',
              icon: Icon(playing.data == true ? Icons.pause : Icons.play_arrow, color: Palette.text),
              onPressed: player.playOrPause,
            ),
          ),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: player.stream.position,
              initialData: player.state.position,
              builder: (context, position) {
                final total = player.state.duration.inMilliseconds;
                final at = (position.data ?? Duration.zero).inMilliseconds;
                return Slider(
                  value: total <= 0 ? 0 : at.clamp(0, total).toDouble(),
                  max: total <= 0 ? 1 : total.toDouble(),
                  onChanged: total <= 0 ? null : (v) => player.seek(Duration(milliseconds: v.round())),
                );
              },
            ),
          ),
          StreamBuilder<Duration>(
            stream: player.stream.position,
            initialData: player.state.position,
            builder: (context, position) => Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                '${formatDuration((position.data ?? Duration.zero).inMilliseconds)} / ${formatDuration(player.state.duration.inMilliseconds)}',
                style: const TextStyle(fontSize: 12, color: Palette.muted, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
