import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'kit.dart';
import 'meta_panel.dart' show copyText;
import 'remix_dialog.dart' show openRemix;

/// In the metadata panel, for a picture with no generation data (one
/// shared in, a screenshot, a JPEG with its data stripped): a button that
/// describes it, and then the described prompt, as phrases grouped by
/// subject, setting, style and light, each switched in or out with a tap,
/// ready to remix or copy. Only when asked: describing takes a moment.
class DescribeCard extends StatefulWidget {
  const DescribeCard({super.key, required this.state, required this.item});
  final AppState state;
  final MediaItem item;

  @override
  State<DescribeCard> createState() => _DescribeCardState();
}

class _DescribeCardState extends State<DescribeCard> {
  Description? _description;
  String? _for;
  bool _busy = false;
  String? _error;

  /// Phrases switched from how they started.
  final Set<String> _flipped = {};

  @override
  void didUpdateWidget(DescribeCard old) {
    super.didUpdateWidget(old);
    if (old.item.path != widget.item.path) {
      _description = null;
      _for = null;
      _error = null;
      _flipped.clear();
    }
  }

  Future<void> _describe() async {
    final path = widget.item.path;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = await widget.state.describe(widget.item);
      if (!mounted || widget.item.path != path) return;
      setState(() {
        _description = d;
        _for = path;
        _flipped.clear();
      });
    } catch (e) {
      if (mounted && widget.item.path == path) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _on(DescribedPhrase p) => p.on != _flipped.contains(p.text);

  String get _prompt => [
    for (final (_, phrases) in _description?.groups ?? const <(String, List<DescribedPhrase>)>[])
      for (final p in phrases)
        if (_on(p)) p.text,
  ].join(', ');

  /// Remix the picture with the described prompt: from the picture itself
  /// (image to image), on the model the folder's pictures use most.
  Future<void> _remix() async {
    final state = widget.state;
    final item = widget.item;
    var model = '';
    try {
      final usage = await state.usage();
      for (final g in usage.groups) {
        if (g.kind == 'model' && g.items.isNotEmpty) model = g.items.first.value;
      }
    } catch (_) {
      // No model to name: the server's own.
    }
    if (!mounted) return;
    final recipe = GenInfo(
      source: 'described',
      prompt: _prompt,
      negative: '',
      seed: '',
      model: model,
      models: [if (model.isNotEmpty) ModelRef('checkpoint', model, '')],
      loras: const [],
      params: const [],
      nodes: const [],
      raw: const [],
      width: item.width,
      height: item.height,
      durationMs: 0,
    );
    await openRemix(context, state, item, recipe: recipe, imageToImage: true);
  }

  @override
  Widget build(BuildContext context) {
    final installed = widget.state.content.value.installed;
    final description = _for == widget.item.path ? _description : null;
    if (description == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('No generation data found in this file.', style: TextStyle(color: Palette.muted, fontSize: 13)),
            const SizedBox(height: 8),
            if (installed)
              OutlinedButton.icon(
                key: const ValueKey<String>('describe-start'),
                onPressed: _busy || widget.item.isVideo ? null : _describe,
                icon: _busy
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.text_snippet_outlined, size: 16),
                label: Text(_busy ? 'Describing…' : 'Describe it'),
              )
            else
              const Text(
                'Turn on content search (the picture button in the search box) to describe pictures like this one.',
                style: TextStyle(fontSize: 12, color: Palette.faint, height: 1.35),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!, style: const TextStyle(fontSize: 12, color: Palette.danger)),
              ),
          ],
        ),
      );
    }
    final prompt = _prompt;
    return Column(
      key: const ValueKey<String>('describe-result'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'DESCRIBED PROMPT',
                  style: TextStyle(fontSize: 10.5, letterSpacing: 0.9, fontWeight: FontWeight.w600, color: Palette.faint),
                ),
              ),
              TextButton.icon(
                key: const ValueKey<String>('describe-again'),
                onPressed: _busy ? null : _describe,
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('Describe again'),
              ),
            ],
          ),
        ),
        const Text(
          'No generation data in this file, so this is what the picture model sees in it. Tap a phrase to leave it in or out.',
          style: TextStyle(fontSize: 11.5, color: Palette.faint, height: 1.35),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Palette.raised, borderRadius: BorderRadius.circular(6)),
          child: SelectableText(
            prompt.isEmpty ? 'Nothing switched on.' : prompt,
            key: const ValueKey<String>('describe-prompt'),
            style: TextStyle(fontSize: 13, height: 1.45, color: prompt.isEmpty ? Palette.faint : const Color(0xFFCFCFD6)),
          ),
        ),
        for (final (name, phrases) in description.groups)
          if (phrases.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 60,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Text('${name[0].toUpperCase()}${name.substring(1)}', style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
                    ),
                  ),
                  Expanded(
                    child: Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [
                        for (final p in phrases)
                          PhraseChip(
                            key: ValueKey<String>('describe-phrase-${p.text}'),
                            text: p.text,
                            look: _on(p) ? PhraseLook.seen : PhraseLook.off,
                            confidence: p.confidence,
                            tooltip: _on(p) ? 'In the prompt: tap to leave it out' : 'Left out: tap to put it in',
                            onTap: () => setState(() => _flipped.contains(p.text) ? _flipped.remove(p.text) : _flipped.add(p.text)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            FilledButton.tonalIcon(
              key: const ValueKey<String>('describe-remix'),
              onPressed: prompt.isEmpty ? null : _remix,
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: const Text('Remix with this prompt'),
            ),
            TextButton.icon(
              key: const ValueKey<String>('describe-copy'),
              onPressed: prompt.isEmpty ? null : () => copyText(context, prompt, 'prompt'),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
            ),
          ],
        ),
      ],
    );
  }
}
