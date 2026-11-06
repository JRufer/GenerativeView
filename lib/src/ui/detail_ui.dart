/// The detail pass (faces and hands redrawn up close) and the hires fix in
/// tiles: the controls for each, shared by Upscale and Remix.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/detail_pass.dart';
import '../core/media_image.dart' show pathImage;
import '../theme.dart';
import 'sheet.dart';

// ------------------------------------------------------------ detail pass

/// Faces and hands redrawn up close: which, how much, words to add for
/// them, and, for a picture that exists already, what was found in it (a
/// box on each, tapped to leave it alone).
///
/// In Remix there is no picture yet: [path] is null and the pieces are
/// found in each picture as it arrives.
class DetailPassSection extends StatefulWidget {
  const DetailPassSection({
    super.key,
    required this.pass,
    required this.onChanged,
    this.finder,
    this.path,
    this.aspect = 1,
    this.enabled = true,
  });
  final DetailPass pass;
  final ValueChanged<DetailPass> onChanged;

  /// What finds the faces and hands; its model may need fetching first.
  final RegionFinder? finder;

  /// The picture to find them in now, when there is one.
  final String? path;
  final double aspect;
  final bool enabled;

  @override
  State<DetailPassSection> createState() => _DetailPassSectionState();
}

class _DetailPassSectionState extends State<DetailPassSection> {
  late final TextEditingController _extra = TextEditingController(text: widget.pass.extra);
  StreamSubscription<FinderModelState>? _model;
  List<DetailRegion>? _found;
  bool _finding = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _model = widget.finder?.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
      _findIfReady();
    });
    _findIfReady();
  }

  @override
  void didUpdateWidget(DetailPassSection old) {
    super.didUpdateWidget(old);
    if (widget.pass.on && !old.pass.on) _findIfReady();
  }

  @override
  void dispose() {
    _model?.cancel();
    _extra.dispose();
    super.dispose();
  }

  Future<void> _findIfReady() async {
    final finder = widget.finder, path = widget.path;
    if (finder == null || path == null || !finder.model.installed || _found != null || _finding || !widget.pass.on) return;
    setState(() => _finding = true);
    try {
      final found = await finder.find(path);
      if (mounted) setState(() => _found = found);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  void _set(DetailPass p) => widget.onChanged(p);

  @override
  Widget build(BuildContext context) {
    final p = widget.pass;
    final finder = widget.finder;
    final chips = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChipButton(
          key: const ValueKey<String>('detail-faces'),
          label: 'Faces',
          icon: Icons.face_outlined,
          selected: p.faces,
          onTap: widget.enabled ? () => _set(p.copyWith(faces: !p.faces)) : null,
        ),
        ChoiceChipButton(
          key: const ValueKey<String>('detail-hands'),
          label: 'Hands',
          icon: Icons.back_hand_outlined,
          selected: p.hands,
          onTap: widget.enabled ? () => _set(p.copyWith(hands: !p.hands)) : null,
        ),
      ],
    );
    if (!p.on) {
      return Column(
        key: const ValueKey<String>('detail-section'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          chips,
          const SizedBox(height: 6),
          const Text(
            'Small faces and hands come out soft. Pick either to have them found and redrawn up close.',
            style: TextStyle(fontSize: 12, color: Palette.faint, height: 1.35),
          ),
        ],
      );
    }
    final found = _found;
    final wanted = found == null ? const <(int, DetailRegion)>[] : [for (var i = 0; i < found.length; i++) if (p.wants(found[i].kind)) (i, found[i])];
    final kept = wanted.where((e) => !p.skipped.contains(e.$1)).length;
    return Column(
      key: const ValueKey<String>('detail-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        chips,
        const SizedBox(height: 10),
        if (widget.path != null) ...[
          if (finder != null && !finder.model.installed)
            _ModelCard(
              key: const ValueKey<String>('detail-download'),
              what: 'Finding faces and hands needs a ${(finder.downloadBytes / (1 << 20)).round()} MB model, downloaded once and kept on this device.',
              state: finder.model.downloading ? finder.model.progress : null,
              downloading: finder.model.downloading,
              error: finder.model.error,
              onDownload: finder.download,
            )
          else
            LayoutBuilder(
              builder: (context, box) {
                final preview = ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200, maxHeight: 200),
                  child: _RegionPreview(
                    path: widget.path!,
                    aspect: widget.aspect,
                    regions: wanted,
                    skipped: p.skipped,
                    onToggle: (i) => _set(p.copyWith(skipped: p.skipped.contains(i) ? ({...p.skipped}..remove(i)) : {...p.skipped, i})),
                  ),
                );
                final caption = Text(
                  _error ??
                      (_finding || found == null
                          ? 'Looking for faces and hands…'
                          : wanted.isEmpty
                          ? 'None found in this picture.'
                          : '${_foundText(wanted.map((e) => e.$2))}. '
                                '${kept == wanted.length ? 'Tap one to leave it as it is.' : '$kept will be redrawn.'}'),
                  key: const ValueKey<String>('detail-found'),
                  style: TextStyle(fontSize: 12.5, color: _error == null ? Palette.muted : Palette.danger, height: 1.35),
                );
                if (box.maxWidth < 400) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Center(child: preview), const SizedBox(height: 8), caption]);
                }
                return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [preview, const SizedBox(width: 14), Expanded(child: caption)]);
              },
            ),
          const SizedBox(height: 10),
        ] else
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'Each new picture has its faces and hands found and redrawn up close before it is saved.',
              style: TextStyle(fontSize: 12, color: Palette.faint, height: 1.35),
            ),
          ),
        Row(
          children: [
            const Text('Strength', style: TextStyle(fontSize: 13)),
            Expanded(
              child: Slider(
                key: const ValueKey<String>('detail-strength'),
                value: p.strength,
                min: minDetailStrength,
                max: maxDetailStrength,
                divisions: ((maxDetailStrength - minDetailStrength) / 0.05).round(),
                onChanged: widget.enabled ? (v) => _set(p.copyWith(strength: v)) : null,
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                p.strength.toStringAsFixed(2),
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Palette.accent, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ],
        ),
        const Text('Low keeps the likeness; higher fixes more and changes more.', style: TextStyle(fontSize: 11.5, color: Palette.faint)),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey<String>('detail-extra'),
          controller: _extra,
          enabled: widget.enabled,
          onChanged: (v) => _set(p.copyWith(extra: v)),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Palette.raised,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
            labelText: 'Words to add for them',
            hintText: 'detailed eyes, natural skin',
            helperText: 'Added to the picture\'s own prompt for these parts only',
            helperStyle: const TextStyle(color: Palette.faint),
          ),
        ),
      ],
    );
  }
}

String _foundText(Iterable<DetailRegion> regions) {
  final faces = regions.where((r) => r.kind == DetailKind.face).length;
  final hands = regions.length - faces;
  String n(int c, String one, String many) => c == 1 ? '1 $one' : '$c $many';
  return 'Found ${[if (faces > 0) n(faces, 'face', 'faces'), if (hands > 0) n(hands, 'hand', 'hands')].join(' and ')}';
}

/// The picture with a box on each face or hand to be redrawn; a box tapped
/// is left alone (shown dashed and dim).
class _RegionPreview extends StatelessWidget {
  const _RegionPreview({required this.path, required this.aspect, required this.regions, required this.skipped, required this.onToggle});
  final String path;
  final double aspect;
  final List<(int, DetailRegion)> regions;
  final Set<int> skipped;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      key: const ValueKey<String>('detail-preview'),
      aspectRatio: aspect > 0 ? aspect : 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            fit: StackFit.expand,
            children: [
              Image(image: ResizeImage.resizeIfNeeded(480, null, pathImage(path)), fit: BoxFit.fill, gaplessPlayback: true),
              for (final (i, r) in regions)
                Positioned(
                  left: r.box.left * box.maxWidth,
                  top: r.box.top * box.maxHeight,
                  width: r.box.width * box.maxWidth,
                  height: r.box.height * box.maxHeight,
                  child: Tooltip(
                    message: skipped.contains(i) ? 'Left as it is: tap to redraw it' : 'Redrawn: tap to leave it',
                    child: InkWell(
                      key: ValueKey<String>('detail-region-$i'),
                      onTap: () => onToggle(i),
                      child: CustomPaint(painter: _BoxPainter(r.kind, skipped.contains(i))),
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

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.kind, this.skipped);
  final DetailKind kind;
  final bool skipped;

  @override
  void paint(Canvas canvas, Size size) {
    final color = skipped ? const Color(0x99FFFFFF) : (kind == DetailKind.face ? Palette.accent : const Color(0xFFF0A35E));
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4));
    if (!skipped) canvas.drawRRect(r, Paint()..color = color.withValues(alpha: 0.14));
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    if (!skipped) {
      canvas.drawRRect(r.deflate(1), line);
      return;
    }
    // Dashed: left alone.
    final path = Path()..addRRect(r.deflate(1));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 8) {
        canvas.drawPath(metric.extractPath(d, d + 4), line);
      }
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) => old.kind != kind || old.skipped != skipped;
}

/// A model to fetch once: what it is for, and the button or the progress.
class _ModelCard extends StatelessWidget {
  const _ModelCard({super.key, required this.what, required this.onDownload, this.state, this.downloading = false, this.error});
  final String what;
  final double? state;
  final bool downloading;
  final String? error;
  final Future<void> Function() onDownload;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(color: Palette.raised, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          const Icon(Icons.download_outlined, size: 18, color: Palette.muted),
          const SizedBox(width: 10),
          Expanded(
            child: downloading
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Downloading… ${state == null ? '' : '${(state! * 100).round()}%'}', style: const TextStyle(fontSize: 12.5, color: Palette.muted)),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: state, minHeight: 3),
                    ],
                  )
                : Text(error ?? what, style: TextStyle(fontSize: 12.5, color: error == null ? Palette.muted : Palette.danger, height: 1.35)),
          ),
          if (!downloading) ...[
            const SizedBox(width: 10),
            FilledButton(onPressed: onDownload, child: Text(error == null ? 'Download' : 'Try again')),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ tiles

/// How a hires fix is sent: whole, in tiles, or tiles when it is large;
/// the tile size and overlap; and the picture with the tiles drawn on it.
class TilesSection extends StatelessWidget {
  const TilesSection({
    super.key,
    required this.mode,
    required this.tile,
    required this.overlap,
    required this.width,
    required this.height,
    required this.onChanged,
    this.path,
    this.aspect = 1,
    this.enabled = true,
  });
  final TileMode mode;
  final int tile;
  final int overlap;

  /// The size the server redraws at.
  final int width;
  final int height;
  final void Function(TileMode mode, int tile, int overlap) onChanged;
  final String? path;
  final double aspect;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final tiled = usesTiles(mode, width, height);
    final tiles = tiled ? planTiles(width, height, tile: tile, overlap: overlap) : const <Rect>[];
    final caption = tiled
        ? '${tiles.length} tiles of ${tiles.first.width.round()} × ${tiles.first.height.round()}, sharing $overlap px. '
              'The server only ever draws one tile at a time, so any size fits.'
        : mode == TileMode.auto
        ? 'Sent whole at $width × $height. Pictures over $autoTileAbove px on a side go in tiles.'
        : 'Sent whole at $width × $height.';
    return Column(
      key: const ValueKey<String>('tiles-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<TileMode>(
            key: const ValueKey<String>('tiles-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: TileMode.auto, label: Text('Auto'), tooltip: 'Tiles only when the picture is large'),
              ButtonSegment(value: TileMode.tiles, icon: Icon(Icons.grid_on, size: 16), label: Text('Tiles')),
              ButtonSegment(value: TileMode.whole, icon: Icon(Icons.crop_square, size: 16), label: Text('Whole')),
            ],
            selected: {mode},
            onSelectionChanged: enabled ? (s) => onChanged(s.first, tile, overlap) : null,
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, box) {
            final controls = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(caption, key: const ValueKey<String>('tiles-caption'), style: const TextStyle(fontSize: 12.5, color: Palette.muted, height: 1.35)),
                if (tiled) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const SizedBox(width: 64, child: Text('Tile', style: TextStyle(fontSize: 12.5, color: Palette.muted))),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final t in tileSizes)
                              ChoiceChipButton(
                                key: ValueKey<String>('tiles-size-$t'),
                                label: '$t',
                                selected: tile == t,
                                onTap: enabled ? () => onChanged(mode, t, overlap) : null,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const SizedBox(width: 64, child: Text('Overlap', style: TextStyle(fontSize: 12.5, color: Palette.muted))),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final o in tileOverlaps)
                              ChoiceChipButton(
                                key: ValueKey<String>('tiles-overlap-$o'),
                                label: '$o px',
                                selected: overlap == o,
                                onTap: enabled ? () => onChanged(mode, tile, o) : null,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
            if (!tiled || path == null) return controls;
            final preview = ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170, maxHeight: 170),
              child: AspectRatio(
                key: const ValueKey<String>('tiles-preview'),
                aspectRatio: aspect > 0 ? aspect : 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image(image: ResizeImage.resizeIfNeeded(360, null, pathImage(path!)), fit: BoxFit.fill, gaplessPlayback: true),
                      CustomPaint(painter: _TilesPainter(tiles, width.toDouble(), height.toDouble())),
                    ],
                  ),
                ),
              ),
            );
            if (box.maxWidth < 400) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Center(child: preview), const SizedBox(height: 10), controls]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [preview, const SizedBox(width: 14), Expanded(child: controls)]);
          },
        ),
      ],
    );
  }
}

/// Each tile's edges over the picture, the shared bands lighter.
class _TilesPainter extends CustomPainter {
  _TilesPainter(this.tiles, this.width, this.height);
  final List<Rect> tiles;
  final double width;
  final double height;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / width, sy = size.height / height;
    final shared = Paint()..color = const Color(0x267AA2F7);
    final edge = Paint()
      ..color = Palette.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 0; i < tiles.length; i++) {
      for (var j = i + 1; j < tiles.length; j++) {
        final both = tiles[i].intersect(tiles[j]);
        if (both.width > 0 && both.height > 0) {
          canvas.drawRect(Rect.fromLTWH(both.left * sx, both.top * sy, both.width * sx, both.height * sy), shared);
        }
      }
    }
    for (final t in tiles) {
      canvas.drawRect(Rect.fromLTWH(t.left * sx, t.top * sy, t.width * sx, t.height * sy).deflate(0.6), edge);
    }
  }

  @override
  bool shouldRepaint(_TilesPainter old) => old.tiles != tiles || old.width != width || old.height != height;
}
