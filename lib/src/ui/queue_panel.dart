import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/backends.dart' show backendNames;
import '../core/models.dart';
import '../render_queue.dart';
import '../theme.dart';
import 'sheet.dart';
import 'thumb_image.dart' show ThumbImage;
import 'upscale_dialog.dart' show scaleText;

/// Open the render queue: every run waiting for a server that was offline,
/// each with the pictures it is made from (or, for a new picture, what its
/// prompt asks for) and a way to cancel it.
Future<void> openRenderQueue(BuildContext context, AppState state) => showPanel<void>(
  context,
  title: 'Render queue',
  icon: Icons.schedule,
  builder: (context) => RenderQueuePanel(state: state),
);

/// What is queued, as runs: those queued together (a Breed's pictures, a
/// prompt's wildcard picks) are one, shown and cancelled as one.
List<List<QueuedRender>> queuedRuns(List<QueuedRender> queued) {
  final byRun = <String, List<QueuedRender>>{};
  for (final entry in queued) {
    byRun.putIfAbsent(entry.group ?? entry.id, () => []).add(entry);
  }
  return byRun.values.toList();
}

/// The queue's contents, kept up to date as renders are sent or cancelled.
class RenderQueuePanel extends StatelessWidget {
  const RenderQueuePanel({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final queue = state.renderQueue;
    return ListenableBuilder(
      listenable: Listenable.merge([queue.queued, queue.checking]),
      builder: (context, _) {
        final queued = queue.queued.value;
        final checking = queue.checking.value;
        final runs = queuedRuns(queued);
        final renders = queued.fold<int>(0, (n, e) => n + e.renders);
        final servers = {for (final e in queued) backendNames[e.kind] ?? e.kind}.join(' and ');
        final how = queue.automatic ? 'Checked every ${everyText(queue.every.inSeconds)} while the app is open.' : 'Not checked automatically.';
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      queued.isEmpty
                          ? 'Nothing is queued. Renders asked for while their server is offline wait here.'
                          : '${renders == 1 ? '1 render' : '$renders renders'} waiting for $servers to come online. $how',
                      key: const ValueKey<String>('queue-status'),
                      style: const TextStyle(fontSize: 12.5, color: Palette.muted, height: 1.35),
                    ),
                  ),
                  if (queued.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    OutlinedButton(
                      key: const ValueKey<String>('queue-check'),
                      onPressed: checking ? null : () => queue.check(asked: true),
                      child: Text(checking ? 'Checking…' : 'Check now'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  key: const ValueKey<String>('queue-list'),
                  shrinkWrap: true,
                  itemCount: runs.length,
                  separatorBuilder: (context, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _RunCard(
                    key: ValueKey<String>('queue-run-${runs[i].first.id}'),
                    state: state,
                    run: runs[i],
                    onCancel: () => queue.cancel(runs[i].map((e) => e.id)),
                  ),
                ),
              ),
              if (runs.length > 1)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextButton(
                      key: const ValueKey<String>('queue-cancel-all'),
                      onPressed: queue.cancelAll,
                      child: const Text('Cancel all'),
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

/// The most thumbnails shown for one run; past it the last says how many
/// more there are.
const int _mostThumbs = 4;

/// One queued run: its pictures, what it will make, and a way to cancel.
class _RunCard extends StatelessWidget {
  const _RunCard({super.key, required this.state, required this.run, required this.onCancel});
  final AppState state;
  final List<QueuedRender> run;
  final VoidCallback onCancel;

  /// The pictures the run is made from, each once, in the order given.
  List<MediaItem> get _pictures {
    final seen = <String>{};
    return [
      for (final entry in run)
        for (final item in entry.pictures)
          if (seen.add(item.path)) item,
    ];
  }

  String _title(int pictures) {
    final first = run.first;
    return switch (first.label) {
      'bred' => pictures > 1 ? 'Breed of $pictures pictures' : 'Breed from ${first.name}',
      'new' => 'New picture',
      _ => first.title,
    };
  }

  /// A line under the title on what will be made: the prompt for a remix,
  /// the steps for an upscale.
  String get _blurb {
    final first = run.first;
    if (first.type != 'upscale') return first.prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    final body = first.body;
    double number(String key) => body[key] is num ? (body[key] as num).toDouble() : 1;
    final here = body['model'] != null;
    if (body['refine'] == true) {
      final faces = body['detail'] is Map ? ', then faces and hands redrawn' : '';
      return here ? 'Upscaled ${scaleText(number('scale'))}× here, then refined on the server$faces' : 'Refined on the server at its own size$faces';
    }
    return here ? 'Upscaled ${scaleText(number('factor'))}× here, then faces and hands redrawn on the server' : 'Faces and hands redrawn on the server';
  }

  /// The small print: how many, how big, how, and where.
  String get _details {
    final first = run.first;
    final renders = run.fold<int>(0, (n, e) => n + e.renders);
    final remix = first.remix;
    return [
      renders == 1 ? '1 render' : '$renders renders',
      if (remix['width'] is num && remix['height'] is num) '${remix['width']} × ${remix['height']}',
      if (remix['init'] is Map) 'image to image',
      if (first.type != 'upscale' && first.body['detail'] is Map) 'faces and hands',
      backendNames[first.kind] ?? first.kind,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final pictures = _pictures;
    final shown = pictures.length > _mostThumbs ? pictures.sublist(0, _mostThumbs - 1) : pictures;
    final more = pictures.length - shown.length;
    // One picture large; several small, two to a row.
    final size = pictures.length == 1 ? 64.0 : 38.0;
    final blurb = _blurb;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 2, 10),
      decoration: BoxDecoration(
        color: Palette.raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: pictures.length <= 1 ? 64 : 80,
            child: pictures.isEmpty
                // A new picture has nothing to show yet but its prompt.
                ? const _Tile(size: 64, child: Icon(Icons.auto_awesome, size: 24, color: Palette.muted))
                : Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final item in shown)
                        _Tile(
                          key: ValueKey<String>('queue-thumb-${item.path}'),
                          size: size,
                          child: ThumbImage(cache: state.thumbs, item: item, tier: 0, fit: BoxFit.cover),
                        ),
                      if (more > 0)
                        _Tile(
                          size: size,
                          child: Center(
                            child: Text('+$more', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Palette.muted)),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _title(pictures.length),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Palette.text),
                ),
                if (blurb.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    blurb,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: Palette.muted, height: 1.35),
                  ),
                ],
                const SizedBox(height: 5),
                Text(_details, style: const TextStyle(fontSize: 11.5, color: Palette.faint, height: 1.3)),
              ],
            ),
          ),
          // Big enough for a finger.
          SizedBox(
            width: 44,
            height: 44,
            child: IconButton(
              key: ValueKey<String>('queue-cancel-${run.first.id}'),
              tooltip: 'Cancel',
              iconSize: 20,
              onPressed: onCancel,
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small square with rounded corners: a thumbnail, or what stands in
/// for one.
class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.size, required this.child});
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(5),
    child: SizedBox(
      width: size,
      height: size,
      child: ColoredBox(color: Palette.tile, child: child),
    ),
  );
}
