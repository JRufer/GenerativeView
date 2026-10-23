import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/backends.dart';
import '../core/models.dart';
import '../theme.dart';
import 'mask_editor.dart' show prepareImageInput;
import 'meta_panel.dart' show toast;
import 'remix_dialog.dart' show openBackendSettings, snapSize;
import 'sheet.dart';

/// Open the upscale panel for [item]: which model, how much bigger, and
/// what to do with the metadata. The upscale itself runs on this device in
/// the background; [UpscaleJobs] shows how it is going.
Future<void> openUpscale(BuildContext context, AppState state, MediaItem item) =>
    openUpscaleMany(context, state, [item]);

/// The same for several pictures at once: one choice for all of them, and
/// they are upscaled one after another. Videos among them are left out.
Future<void> openUpscaleMany(BuildContext context, AppState state, List<MediaItem> targets) async {
  final items = [for (final t in targets) if (!t.isVideo) t];
  if (items.isEmpty) {
    toast(context, 'Videos cannot be upscaled');
    return;
  }
  final UpscaleModels models;
  try {
    models = await state.upscaleModels();
  } catch (e) {
    if (context.mounted) toast(context, 'Upscaling is not available: $e');
    return;
  }
  if (!context.mounted) return;
  await showPanel<void>(
    context,
    title: items.length == 1 ? 'Upscale ${items.single.name}' : 'Upscale ${items.length} images',
    icon: Icons.photo_size_select_large,
    width: 520,
    builder: (context) => UpscalePanel(state: state, items: items, models: models),
  );
}

class UpscalePanel extends StatefulWidget {
  const UpscalePanel({super.key, required this.state, required this.items, required this.models});
  final AppState state;

  /// The pictures to upscale: one, or several, each in turn.
  final List<MediaItem> items;
  final UpscaleModels models;

  @override
  State<UpscalePanel> createState() => _UpscalePanelState();
}

class _UpscalePanelState extends State<UpscalePanel> {
  late String _model = widget.models.models.isEmpty ? '' : widget.models.models.first.id;
  int _factor = 2;
  bool _keepMetadata = true;
  bool _busy = false;

  /// Hires fix: after the upscale here, send it to a server to redraw
  /// lightly at the larger size, adding real detail.
  bool _refine = false;

  /// The server that refines, of those set up.
  String? _server;

  /// How much the server redraws: low, so the picture stays itself.
  double _hiresStrength = hiresDefaultStrength;

  /// How much bigger the refined picture is than the original.
  double _hiresScale = 2;

  /// The servers set up, in the usual order.
  List<String> get _servers => [
    for (final k in backendNames.keys)
      if ((widget.state.backendUrls[k] ?? '').isNotEmpty) k,
  ];

  /// Whether the server was picked by hand, and is not to be changed.
  bool _serverChosen = false;

  /// The program that made the (first) picture, once its metadata is read.
  String? _made;

  @override
  void initState() {
    super.initState();
    _server = _pickServer();
    widget.state.metadata(widget.items.first).then((info) {
      if (!mounted) return;
      _made = madeOn(info.source);
      if (!_serverChosen) setState(() => _server = _pickServer());
    }, onError: (Object _) {});
  }

  /// The one that made the (first) picture, if it is set up, or else the
  /// first that is.
  String? _pickServer() {
    final servers = _servers;
    if (servers.isEmpty) return null;
    return servers.contains(_made) ? _made : servers.first;
  }

  UpscaleModel? get _chosen {
    for (final m in widget.models.models) {
      if (m.id == _model) return m;
    }
    return null;
  }

  Future<void> _start() async {
    final model = _chosen;
    if (model == null) return;
    setState(() => _busy = true);
    var ready = model.installed;
    if (!ready) ready = await widget.state.downloadUpscaleModel(widget.models, model);
    if (!mounted) return;
    if (!ready) {
      setState(() => _busy = false);
      return;
    }
    final server = _refine ? _server : null;
    if (server == null) {
      await widget.state.startUpscales(widget.items, model: model.id, factor: _factor, keepMetadata: _keepMetadata);
    } else {
      final state = widget.state;
      final strength = _hiresStrength;
      final scale = _hiresScale;
      await state.startUpscales(
        widget.items,
        model: model.id,
        // The upscale here is the starting point; the server's picture is
        // made at [scale] from it.
        factor: 2,
        keepMetadata: _keepMetadata,
        then: (original, upscaled) => refineUpscale(state, original, upscaled, kind: server, strength: strength, scale: scale),
        thenLabel: 'then refined on ${backendNames[server]}',
      );
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _setUpServer() async {
    await openBackendSettings(context, widget.state);
    if (!mounted) return;
    setState(() => _server = _servers.contains(_server) ? _server : _pickServer());
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items.first;
    final many = widget.items.length > 1;
    final refine = _refine && _server != null;
    final (w, h) = refine ? hiresSize(item.width, item.height, _hiresScale) : (item.width * _factor, item.height * _factor);
    final ext = item.name.contains('.') ? item.name.split('.').last.toLowerCase() : 'png';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Runs on this device with Real-ESRGAN. No prompt is needed and nothing is uploaded; '
            'the larger picture is saved next to the original.',
            style: TextStyle(fontSize: 12.5, color: Palette.muted, height: 1.4),
          ),
          const PanelHeading('Model'),
          RadioGroup<String>(
            groupValue: _model,
            onChanged: (v) {
              if (!_busy && v != null) setState(() => _model = v);
            },
            child: Column(
              children: [
                for (final m in widget.models.models)
                  RadioListTile<String>(
                    key: ValueKey<String>('upscale-model-${m.id}'),
                    value: m.id,
                    enabled: !_busy,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(m.name, style: const TextStyle(fontSize: 13.5)),
                    subtitle: Text(
                      m.installed ? m.detail : '${m.detail}\nDownloaded once on first use: ${formatBytes(m.bytes)} from github.com',
                      style: const TextStyle(fontSize: 12, color: Palette.muted),
                    ),
                  ),
              ],
            ),
          ),
          const PanelHeading('Size'),
          Wrap(
            spacing: 8,
            children: [
              if (!refine)
                for (final f in const [2, 4])
                  ChoiceChipButton(
                    key: ValueKey<String>('upscale-factor-$f'),
                    label: '$f×',
                    selected: _factor == f,
                    onTap: _busy ? null : () => setState(() => _factor = f),
                  )
              else
                for (final f in hiresScales)
                  ChoiceChipButton(
                    key: ValueKey<String>('hires-scale-$f'),
                    label: '${scaleText(f)}×',
                    selected: _hiresScale == f,
                    onTap: _busy ? null : () => setState(() => _hiresScale = f),
                  ),
            ],
          ),
          if (item.width > 0 && !many)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${item.width} × ${item.height} to $w × $h',
                key: const ValueKey<String>('upscale-size'),
                style: const TextStyle(fontSize: 12, color: Palette.faint),
              ),
            ),
          if (refine && math.max(w, h) > hiresLargeSide)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'That is large for most models and graphics cards; 1.5× is gentler on the server.',
                style: TextStyle(fontSize: 12, color: Palette.faint, height: 1.35),
              ),
            ),
          const PanelHeading('Hires fix'),
          _refineSection(context),
          const PanelHeading('Metadata'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChipButton(
                key: const ValueKey<String>('upscale-keep-metadata'),
                label: 'Exact copy of the original\'s',
                icon: Icons.content_copy,
                selected: _keepMetadata,
                onTap: _busy ? null : () => setState(() => _keepMetadata = true),
              ),
              ChoiceChipButton(
                key: const ValueKey<String>('upscale-strip-metadata'),
                label: 'None (stripped)',
                icon: Icons.layers_clear_outlined,
                selected: !_keepMetadata,
                onTap: _busy ? null : () => setState(() => _keepMetadata = false),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _keepMetadata
                  ? 'The prompt, settings and workflow are carried over byte for byte, so the upscale searches and remixes like the original.'
                  : 'Only the picture: nothing of how it was made goes with it.',
              style: const TextStyle(fontSize: 12, color: Palette.faint, height: 1.35),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              refine
                  ? (many
                        ? '${widget.items.length} pictures, one after another: each upscaled here as name_up2x, then refined on '
                              '${backendNames[_server]} and saved beside its original as name_hires1, in ${AppState.remixCollection}'
                        : 'Upscaled here as ${_stem(item.name)}_up2x.$ext, then refined on ${backendNames[_server]} and saved as '
                              '${_stem(item.name)}_hires1, in ${AppState.remixCollection}')
                  : many
                  ? '${widget.items.length} pictures, one after another, each saved beside its original as name_up${_factor}x'
                  : 'Saved as ${_stem(item.name)}_up${_factor}x.$ext',
              key: const ValueKey<String>('upscale-saved-as'),
              style: const TextStyle(fontSize: 12, color: Palette.faint, height: 1.35),
            ),
          ),
          ValueListenableBuilder<DownloadProgress?>(
            valueListenable: widget.state.upscaleDownload,
            builder: (context, progress, _) {
              if (progress == null) return const SizedBox(height: 16);
              return Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: progress.total > 0 ? progress.received / progress.total : null,
                        minHeight: 3,
                        backgroundColor: Palette.line,
                        color: Palette.accent,
                      ),
                    ),
                    TextButton(onPressed: widget.state.cancelUpscaleDownload, child: const Text('Cancel')),
                  ],
                ),
              );
            },
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const ValueKey<String>('upscale-start'),
              onPressed: _busy || _chosen == null ? null : _start,
              icon: const Icon(Icons.photo_size_select_large, size: 18),
              label: Text(
                _chosen?.installed == false
                    ? (refine ? 'Download, upscale and refine' : 'Download and upscale')
                    : refine
                    ? (many ? 'Upscale and refine ${widget.items.length}' : 'Upscale and refine')
                    : many
                    ? 'Upscale ${widget.items.length}'
                    : 'Upscale',
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _stem(String name) => name.replaceFirst(RegExp(r'\.[^.]+$'), '');

  /// The switch for hires fix, and when it is on, the server and how much
  /// it redraws.
  Widget _refineSection(BuildContext context) {
    final servers = _servers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey<String>('hires-switch'),
          value: _refine,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Then refine on a server', style: TextStyle(fontSize: 13.5)),
          subtitle: const Text(
            'The upscale is sent as image to image with the picture\'s own prompt, settings and seed, '
            'and redrawn lightly at the larger size, so the server adds real detail rather than sharpening.',
            style: TextStyle(fontSize: 12, color: Palette.muted, height: 1.35),
          ),
          onChanged: _busy ? null : (v) => setState(() => _refine = v),
        ),
        if (_refine && servers.isEmpty)
          Row(
            children: [
              const Expanded(
                child: Text('No generation server is set up yet.', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
              ),
              TextButton(
                key: const ValueKey<String>('hires-set-up'),
                onPressed: _busy ? null : _setUpServer,
                child: const Text('Set up a server…'),
              ),
            ],
          ),
        if (_refine && servers.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final k in servers)
                ChoiceChipButton(
                  key: ValueKey<String>('hires-server-$k'),
                  label: backendNames[k]!,
                  selected: _server == k,
                  onTap: _busy
                      ? null
                      : () => setState(() {
                          _server = k;
                          _serverChosen = true;
                        }),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Denoising strength', style: TextStyle(fontSize: 13)),
              const Spacer(),
              Text(
                _hiresStrength.toStringAsFixed(2),
                key: const ValueKey<String>('hires-strength-value'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Palette.accent,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(activeTrackColor: Palette.accent, thumbColor: Palette.accent),
            child: Slider(
              key: const ValueKey<String>('hires-strength'),
              value: _hiresStrength,
              min: hiresMinStrength,
              max: hiresMaxStrength,
              divisions: ((hiresMaxStrength - hiresMinStrength) / 0.05).round(),
              label: _hiresStrength.toStringAsFixed(2),
              onChanged: _busy ? null : (v) => setState(() => _hiresStrength = v),
            ),
          ),
          const Text(
            'Around 0.3 adds detail and keeps the picture as it was; higher starts to change faces and shapes.',
            style: TextStyle(fontSize: 11.5, color: Palette.faint, height: 1.35),
          ),
        ],
      ],
    );
  }
}

/// How much bigger a hires fix may make the picture.
const List<double> hiresScales = [1.5, 2];

/// Denoising strength for a hires fix: where it starts, and how far it goes.
const double hiresDefaultStrength = 0.35;
const double hiresMinStrength = 0.1;
const double hiresMaxStrength = 0.7;

/// A long side past this is heavy going for most servers.
const int hiresLargeSide = 2560;

/// `1.5` or `2`, as a size is written.
String scaleText(double f) => f == f.roundToDouble() ? '${f.round()}' : '$f';

/// The size a hires fix of a [width] × [height] picture is made at: [scale]
/// times as big, rounded to a size every server takes.
(int, int) hiresSize(int width, int height, double scale) =>
    (snapSize((width * scale).round()), snapSize((height * scale).round()));

/// The server a picture from [source] was made on, as [backendNames] names
/// it; null for anything else.
String? madeOn(String source) => switch (source) {
  'comfyui' => 'comfyui',
  'invokeai' => 'invokeai',
  'a1111' || 'forge' => 'forge',
  _ => null,
};

/// Hires fix, the second half: send [upscaled] (the upscale of [original]
/// made here) to the server [kind] as image to image, with [original]'s own
/// prompt, settings and seed, at [scale] times [original]'s size and
/// [strength]. What comes back is saved beside [original] as
/// `name_hires1.png` and put in the remix collection, as a remix is.
/// Answers with a line to show.
Future<String?> refineUpscale(
  AppState state,
  MediaItem original,
  String upscaled, {
  required String kind,
  required double strength,
  required double scale,
}) async {
  final name = backendNames[kind] ?? kind;
  final base = state.backendUrls[kind] ?? '';
  if (base.isEmpty) return '${original.name} was upscaled but not refined: $name is no longer set up';
  final GenInfo info;
  try {
    info = await state.metadata(original);
  } catch (_) {
    return '${original.name} was upscaled but not refined: its generation data could not be read';
  }
  if (backendSupport(info)[kind] != null) {
    return '${original.name} was upscaled but not refined: it has no generation data to refine with';
  }
  var (w, h) = (original.width, original.height);
  if (w <= 0 || h <= 0) (w, h) = recipeSize(info);
  if (w <= 0 || h <= 0) return '${original.name} was upscaled but not refined: its size is not known';
  final (width, height) = hiresSize(w, h, scale);
  final ImageInput init;
  try {
    init = await prepareImageInput(path: upscaled, width: width, height: height, strength: strength, ops: const []);
  } catch (e) {
    return '${original.name} was upscaled but not refined: could not read the upscale ($e)';
  }
  final seed = int.tryParse(info.seed.trim());
  final ticket = await sendRemix(
    kind,
    base,
    Remix(
      info: info,
      prompt: info.prompt,
      negative: info.negative,
      seed: seed ?? 0,
      randomSeed: seed == null,
      count: 1,
      width: width,
      height: height,
      init: init,
    ),
  );
  state.collectRemix(original, ticket, label: 'hires');
  return 'Hires fix of ${original.name} sent to $name, at $width × $height';
}

/// Upscales under way, in the corner of the window: progress, and a way to
/// stop each.
class UpscaleJobs extends StatelessWidget {
  const UpscaleJobs({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: state.upscalesWaiting,
      builder: (context, waiting, _) => ValueListenableBuilder<List<UpscaleJob>>(
      valueListenable: state.upscales,
      builder: (context, jobs, _) {
        if (jobs.isEmpty) return const SizedBox.shrink();
        return Material(
          key: const ValueKey<String>('upscale-jobs'),
          color: Palette.raised,
          elevation: 6,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Palette.line)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final job in jobs)
                    Row(
                      children: [
                        const Icon(Icons.photo_size_select_large, size: 16, color: Palette.muted),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                job.then == null ? 'Upscaling ${job.name} ${job.factor}×' : 'Upscaling ${job.name} ${job.factor}×, ${job.then}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                              const SizedBox(height: 4),
                              LinearProgressIndicator(
                                value: job.progress,
                                minHeight: 3,
                                backgroundColor: Palette.line,
                                color: Palette.accent,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: waiting > 0 ? 'Stop this one' : 'Stop',
                          iconSize: 18,
                          onPressed: () => state.cancelUpscale(job.id),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  if (waiting > 0)
                    Row(
                      key: const ValueKey<String>('upscale-waiting'),
                      children: [
                        const SizedBox(width: 24),
                        Expanded(
                          child: Text(
                            '$waiting more waiting',
                            style: const TextStyle(fontSize: 12, color: Palette.muted),
                          ),
                        ),
                        TextButton(
                          onPressed: state.cancelAllUpscales,
                          child: const Text('Stop all'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
      ),
    );
  }
}
