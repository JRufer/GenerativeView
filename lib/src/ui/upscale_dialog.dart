import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/backends.dart';
import '../core/models.dart';
import '../theme.dart';
import 'mask_editor.dart' show prepareImageInput;
import 'meta_panel.dart' show toast;
import 'remix_dialog.dart' show openBackendSettings, snapSize;
import 'kit.dart';
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

  /// The sizes on offer, worked out from the pictures' own sizes: the
  /// largest of them decides, so every one of them fits.
  late final double _maxFactor = maxUpscaleFactor(widget.items, widget.models);
  late final List<double> _factors = upscaleFactors(_maxFactor);
  late final double _maxHires = maxHiresScale(widget.items);
  late final List<double> _hiresScales = hiresScalesFor(_maxHires);

  /// How much bigger the upscale here is; null when the pictures are
  /// already as large as one can be.
  late double? _factor = _factors.contains(2.0) ? 2.0 : (_factors.isEmpty ? null : _factors.last);
  bool _keepMetadata = true;
  bool _busy = false;

  /// Hires fix: after the upscale here, send it to a server to redraw
  /// lightly at the larger size, adding real detail.
  bool _refine = false;

  /// The server that refines, of those set up.
  String? _server;

  /// How much the server redraws: low, so the picture stays itself.
  double _hiresStrength = hiresDefaultStrength;

  /// How much bigger the refined picture is than the original; 1 sends it
  /// at its own size, with no upscale here.
  late double _hiresScale = defaultHiresScale(widget.items, _hiresScales);

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
    final model = _usesModel ? _chosen : null;
    if (_usesModel && model == null) return;
    setState(() => _busy = true);
    if (model != null) {
      var ready = model.installed;
      if (!ready) ready = await widget.state.downloadUpscaleModel(widget.models, model);
      if (!mounted) return;
      if (!ready) {
        setState(() => _busy = false);
        return;
      }
    }
    final server = _refine ? _server : null;
    final factor = _factor;
    if (server == null) {
      if (factor == null) {
        setState(() => _busy = false);
        return;
      }
      await widget.state.startUpscales(widget.items, model: model!.id, factor: factor, keepMetadata: _keepMetadata);
    } else {
      final state = widget.state;
      final strength = _hiresStrength;
      final scale = _hiresScale;
      Future<String?> refine(MediaItem original, String upscaled) =>
          refineUpscale(state, original, upscaled, kind: server, strength: strength, scale: scale);
      if (scale <= 1) {
        // At its own size: the picture itself goes, nothing is made here.
        unawaited(state.startWithoutUpscale(widget.items, refine, label: 'refining on ${backendNames[server]}'));
      } else {
        await state.startUpscales(
          widget.items,
          model: model!.id,
          // The upscale here is made at the size the server redraws at, so
          // what is sent is the model's detail, not a stretched picture.
          factor: scale,
          keepMetadata: _keepMetadata,
          then: refine,
          thenLabel: 'then refined on ${backendNames[server]}',
        );
      }
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  /// Whether the button has anything to do: an upscale needs a size on
  /// offer and a model; a hires fix at its own size needs neither here.
  bool get _canStart {
    if (_busy) return false;
    if (_refine && _server != null) return _hiresScale <= 1 || _chosen != null;
    return _chosen != null && _factor != null;
  }

  /// Whether a model is used at all: not by a hires fix at the picture's
  /// own size.
  bool get _usesModel => !(_refine && _server != null && _hiresScale <= 1);

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
    final factor = _factor ?? 1;
    final (w, h) = refine
        ? hiresSize(item.width, item.height, _hiresScale)
        : ((item.width * factor).round(), (item.height * factor).round());
    final ownSize = refine && _hiresScale <= 1;
    final ext = item.name.contains('.') ? item.name.split('.').last.toLowerCase() : 'png';
    final servers = _servers;
    final body = SingleChildScrollView(
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
            runSpacing: 8,
            children: [
              if (!refine)
                for (final f in _factors)
                  ChoiceChipButton(
                    key: ValueKey<String>('upscale-factor-${scaleText(f)}'),
                    label: f == _maxFactor && !upscaleSteps.contains(f) ? '${scaleText(f)}× max' : '${scaleText(f)}×',
                    selected: _factor == f,
                    onTap: _busy ? null : () => setState(() => _factor = f),
                  )
              else
                for (final f in _hiresScales)
                  ChoiceChipButton(
                    key: ValueKey<String>('hires-scale-${scaleText(f)}'),
                    label: f <= 1
                        ? 'Same size'
                        : f == _maxHires && !hiresSteps.contains(f)
                        ? '${scaleText(f)}× max'
                        : '${scaleText(f)}×',
                    selected: _hiresScale == f,
                    onTap: _busy ? null : () => setState(() => _hiresScale = f),
                  ),
            ],
          ),
          if (!refine && _factor == null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                many
                    ? 'The largest of these is already as big as an upscale here can be '
                          '(${widget.models.maxSide} on a side). A hires fix at the same size still works.'
                    : 'Already as big as an upscale here can be (${widget.models.maxSide} on a side). '
                          'A hires fix at the same size still works.',
                key: const ValueKey<String>('upscale-too-large'),
                style: const TextStyle(fontSize: 12, color: Palette.faint, height: 1.35),
              ),
            )
          else if (item.width > 0 && !many)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                ownSize ? '${item.width} × ${item.height}, redrawn at $w × $h' : '${item.width} × ${item.height} to $w × $h',
                key: const ValueKey<String>('upscale-size'),
                style: const TextStyle(fontSize: 12, color: Palette.faint),
              ),
            )
          else if (many)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                refine
                    ? 'Up to ${scaleText(_maxHires)}× for these: the largest of them decides.'
                    : 'Up to ${scaleText(_maxFactor)}× for these: the largest of them decides.',
                key: const ValueKey<String>('upscale-size'),
                style: const TextStyle(fontSize: 12, color: Palette.faint),
              ),
            ),
          if (refine && !ownSize && math.max(w, h) > hiresLargeSide)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'That is large for most models and graphics cards; a smaller size is gentler on the server.',
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
              ownSize
                  ? (many
                        ? '${widget.items.length} pictures, one after another: each sent to ${backendNames[_server]} at its own size, '
                              'nothing upscaled here, and saved beside its original as name_hires1, in ${AppState.upscaleCollection}'
                        : 'Sent to ${backendNames[_server]} at its own size, nothing upscaled here, and saved as '
                              '${_stem(item.name)}_hires1, in ${AppState.upscaleCollection}')
                  : refine
                  ? (many
                        ? '${widget.items.length} pictures, one after another: each upscaled here (not kept), '
                              'refined on ${backendNames[_server]} and saved beside its original as name_hires1, in ${AppState.upscaleCollection}'
                        : 'Upscaled here to ${scaleText(_hiresScale)}x (not kept), refined on ${backendNames[_server]} '
                              'and saved as ${_stem(item.name)}_hires1, in ${AppState.upscaleCollection}')
                  : _factor == null
                  ? 'Nothing to upscale at this size.'
                  : many
                  ? '${widget.items.length} pictures, one after another, each saved beside its original as name_up${scaleText(factor)}x, in ${AppState.upscaleCollection}'
                  : 'Saved as ${_stem(item.name)}_up${scaleText(factor)}x.$ext, in ${AppState.upscaleCollection}',
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
        ],
      ),
    );
    // The server (for a hires fix) and the button, kept at the bottom: the
    // same bar as Remix and Breed.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(child: body),
        ServerSendBar(
          state: widget.state,
          backend: _server,
          servers: servers,
          showServers: _refine && servers.isNotEmpty,
          chipKey: (k) => ValueKey<String>('hires-server-$k'),
          onBackend: (k) => setState(() {
            _server = k;
            _serverChosen = true;
          }),
          onServersChanged: () {
            if (mounted) setState(() {});
          },
          actionKey: const ValueKey<String>('upscale-start'),
          icon: Icons.photo_size_select_large,
          onSend: _canStart ? _start : null,
          action: ownSize
              ? (many ? 'Refine ${widget.items.length}' : 'Refine')
              : _chosen?.installed == false
              ? (refine ? 'Download, upscale and refine' : 'Download and upscale')
              : refine
              ? (many ? 'Upscale and refine ${widget.items.length}' : 'Upscale and refine')
              : many
              ? 'Upscale ${widget.items.length}'
              : 'Upscale',
        ),
      ],
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
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 6),
            child: Text('Pick the server beside the Upscale button.', style: TextStyle(fontSize: 11.5, color: Palette.faint)),
          ),
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

/// The sizes an upscale here is offered at, as far as the picture allows;
/// past the last of these that fits, the largest it may be is offered too.
const List<double> upscaleSteps = [1.5, 2, 3, 4, 6, 8, 12, 16];

/// The same for a hires fix. 1 is the picture at its own size: redrawn by
/// the server with nothing upscaled here first.
const List<double> hiresSteps = [1, 1.25, 1.5, 2, 3, 4];

/// The largest a server is asked to redraw at, on a side and in all. A
/// picture larger still is only ever sent at its own size, which the server
/// that made it can draw.
const int hiresMaxSide = 4096;
const int hiresMaxPixels = 4096 * 4096;

/// The sizes of [items] that are known, as (width, height).
Iterable<(int, int)> _sizes(List<MediaItem> items) => [
  for (final i in items)
    if (i.width > 0 && i.height > 0) (i.width, i.height),
];

/// How many times larger [items] may all be upscaled here, by
/// [models]' limits: the largest of them decides. To a tenth, rounded down,
/// and checked as the core checks it (sizes rounded), so what is offered
/// is made. Below 1.1 there is nothing worth offering, and it answers 1.
/// Pictures of unknown size leave it at 4, the model's own factor.
double maxUpscaleFactor(List<MediaItem> items, UpscaleModels models) {
  final sizes = _sizes(items).toList();
  if (sizes.isEmpty) return math.min(4.0, models.maxFactor);
  bool fits(double f) => sizes.every((s) {
    final (w, h) = ((s.$1 * f).round(), (s.$2 * f).round());
    return math.max(w, h) <= models.maxSide && w * h <= models.maxPixels;
  });
  var tenths = (models.maxFactor * 10).floor();
  for (final (w, h) in sizes) {
    final bySide = models.maxSide / math.max(w, h);
    final byPixels = math.sqrt(models.maxPixels / (w * h));
    tenths = math.min(tenths, (math.min(bySide, byPixels) * 10).floor());
  }
  while (tenths > 10 && !fits(tenths / 10)) {
    tenths--;
  }
  return tenths >= 11 ? tenths / 10 : 1.0;
}

/// The factors to offer up to [max]: the steps that fit, and [max] itself
/// when it is past the last of them by 0.2 or more. None when
/// [max] is 1.
List<double> upscaleFactors(double max) {
  final out = [for (final f in upscaleSteps) if (f <= max) f];
  // (0.15, not 0.2: tenths are not exact, and 1.7 − 1.5 comes out under 0.2.)
  if (max > 1 && (out.isEmpty || max - out.last > 0.15)) out.add(max);
  return out;
}

/// How many times larger a hires fix of [items] may be: as far as the
/// server's limits allow for the largest, to a twentieth, rounded down,
/// never past 4 and never below 1 (the picture at its own size). Pictures
/// of unknown size leave it at 2.
double maxHiresScale(List<MediaItem> items) {
  final sizes = _sizes(items).toList();
  if (sizes.isEmpty) return 2;
  var twentieths = 80;
  for (final (w, h) in sizes) {
    final bySide = hiresMaxSide / math.max(w, h);
    final byPixels = math.sqrt(hiresMaxPixels / (w * h));
    twentieths = math.min(twentieths, (math.min(bySide, byPixels) * 20).floor());
  }
  bool fits(double f) => sizes.every((s) {
    final (w, h) = hiresSize(s.$1, s.$2, f);
    return math.max(w, h) <= hiresMaxSide && w * h <= hiresMaxPixels;
  });
  while (twentieths > 20 && !fits(twentieths / 20)) {
    twentieths--;
  }
  return math.max(20, twentieths) / 20;
}

/// The hires sizes to offer up to [max], as [upscaleFactors] does.
List<double> hiresScalesFor(double max) {
  final out = [for (final f in hiresSteps) if (f <= max) f];
  if (max - out.last > 0.075) out.add(max);
  return out;
}

/// Where the hires size starts: 2× where it fits without being heavy for the
/// server ([hiresLargeSide]), else the largest of [scales] that is not, else
/// the picture's own size.
double defaultHiresScale(List<MediaItem> items, List<double> scales) {
  final sizes = _sizes(items).toList();
  bool light(double f) => sizes.every((s) {
    final (w, h) = hiresSize(s.$1, s.$2, f);
    return math.max(w, h) <= hiresLargeSide;
  });
  final ok = [for (final f in scales) if (f <= 2 && (f <= 1 || light(f))) f];
  return ok.isEmpty ? scales.first : ok.last;
}

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

/// Why a hires fix was not sent, though its upscale was made.
class HiresNotSent implements Exception {
  const HiresNotSent(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Hires fix, the second half: send [upscaled] (the upscale of [original]
/// made here) to the server [kind] as image to image, with [original]'s own
/// prompt, settings and seed, at [scale] times [original]'s size and
/// [strength]. What comes back is saved beside [original] as
/// `name_hires1.png` and put in the upscale collection. [upscaled] has been
/// read by the time this answers, so the caller may delete it.
/// Answers with a line to show; throws [HiresNotSent] (or the server's own
/// error) when it cannot be sent.
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
  if (base.isEmpty) throw HiresNotSent('not refined: $name is no longer set up');
  final GenInfo info;
  try {
    info = await state.metadata(original);
  } catch (_) {
    throw HiresNotSent('not refined: its generation data could not be read');
  }
  if (backendSupport(info)[kind] != null) {
    throw HiresNotSent('not refined: it has no generation data to refine with');
  }
  var (w, h) = (original.width, original.height);
  if (w <= 0 || h <= 0) (w, h) = recipeSize(info);
  if (w <= 0 || h <= 0) throw HiresNotSent('not refined: its size is not known');
  final (width, height) = hiresSize(w, h, scale);
  final ImageInput init;
  try {
    init = await prepareImageInput(path: upscaled, width: width, height: height, strength: strength, ops: const []);
  } catch (e) {
    throw HiresNotSent('not refined: could not read the upscale ($e)');
  }
  final seed = int.tryParse(info.seed.trim());
  final RemixTicket ticket;
  try {
    ticket = await sendRemix(
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
  } catch (e) {
    throw HiresNotSent('$name did not take the refine: $e');
  }
  state.collectRemix(original, ticket, label: 'hires');
  // What the server was given, model stand-ins and LoRAs left out included.
  return 'Hires fix of ${original.name} at $width × $height: ${ticket.message}';
}
