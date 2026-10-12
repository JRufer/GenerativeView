import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'meta_panel.dart' show toast;
import 'sheet.dart';

/// Open the upscale panel for [item]: which model, how much bigger, and
/// what to do with the metadata. The upscale itself runs on this device in
/// the background; [UpscaleJobs] shows how it is going.
Future<void> openUpscale(BuildContext context, AppState state, MediaItem item) async {
  if (item.isVideo) {
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
    title: 'Upscale ${item.name}',
    icon: Icons.photo_size_select_large,
    width: 520,
    builder: (context) => UpscalePanel(state: state, item: item, models: models),
  );
}

class UpscalePanel extends StatefulWidget {
  const UpscalePanel({super.key, required this.state, required this.item, required this.models});
  final AppState state;
  final MediaItem item;
  final UpscaleModels models;

  @override
  State<UpscalePanel> createState() => _UpscalePanelState();
}

class _UpscalePanelState extends State<UpscalePanel> {
  late String _model = widget.models.models.isEmpty ? '' : widget.models.models.first.id;
  int _factor = 2;
  bool _keepMetadata = true;
  bool _busy = false;

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
    await widget.state.startUpscale(widget.item, model: model.id, factor: _factor, keepMetadata: _keepMetadata);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final w = item.width * _factor;
    final h = item.height * _factor;
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
              for (final f in const [2, 4])
                ChoiceChipButton(
                  key: ValueKey<String>('upscale-factor-$f'),
                  label: '$f×',
                  selected: _factor == f,
                  onTap: _busy ? null : () => setState(() => _factor = f),
                ),
            ],
          ),
          if (item.width > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${item.width} × ${item.height}  →  $w × $h',
                style: const TextStyle(fontSize: 12, color: Palette.faint),
              ),
            ),
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
              'Saved as ${item.name.replaceFirst(RegExp(r'\.[^.]+$'), '')}_up${_factor}x.$ext',
              style: const TextStyle(fontSize: 12, color: Palette.faint),
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
              label: Text(_chosen?.installed == false ? 'Download and upscale' : 'Upscale'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Upscales under way, in the corner of the window: progress, and a way to
/// stop each.
class UpscaleJobs extends StatelessWidget {
  const UpscaleJobs({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<UpscaleJob>>(
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
                                'Upscaling ${job.name} ${job.factor}×',
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
                          tooltip: 'Stop',
                          iconSize: 18,
                          onPressed: () => state.cancelUpscale(job.id),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
