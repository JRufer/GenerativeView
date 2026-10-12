import 'package:flutter/material.dart';

import '../core/civitai.dart';
import '../platform.dart';
import '../theme.dart';
import 'meta_panel.dart' show copyText;
import 'sheet.dart';

/// Look up a model or LoRA on Civitai and show what it is: base model,
/// trigger words (tap to copy), and a link to its page.
Future<void> openCivitai(BuildContext context, {required String name, String hash = '', String kind = ''}) {
  return showPanel<void>(
    context,
    title: modelStem(name),
    icon: Icons.travel_explore,
    width: 520,
    builder: (context) => _CivitaiPanel(name: name, hash: hash, kind: kind),
  );
}

class _CivitaiPanel extends StatefulWidget {
  const _CivitaiPanel({required this.name, required this.hash, required this.kind});
  final String name;
  final String hash;
  final String kind;

  @override
  State<_CivitaiPanel> createState() => _CivitaiPanelState();
}

class _CivitaiPanelState extends State<_CivitaiPanel> {
  late final Future<CivitaiModel?> _found = lookUpModel(name: widget.name, hash: widget.hash, kind: widget.kind);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CivitaiModel?>(
      future: _found,
      builder: (context, snap) {
        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Padding(
            padding: EdgeInsets.all(28),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        } else if (snap.hasError) {
          body = _note('${snap.error}');
        } else if (snap.data == null) {
          body = _note(
            'Civitai does not list ${widget.hash.isEmpty ? 'a file called' : 'this file or one called'} '
            '“${modelStem(widget.name)}”. It may be from somewhere else, or renamed.',
          );
        } else {
          body = _details(context, snap.data!);
        }
        return SingleChildScrollView(padding: const EdgeInsets.fromLTRB(18, 0, 18, 18), child: body);
      },
    );
  }

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(text, style: const TextStyle(fontSize: 13, color: Palette.muted, height: 1.4)),
  );

  Widget _details(BuildContext context, CivitaiModel m) {
    final facts = [
      if (m.type.isNotEmpty) m.type,
      if (m.baseModel.isNotEmpty) m.baseModel,
      if (m.version.isNotEmpty) m.version,
      if (m.creator.isNotEmpty) 'by ${m.creator}',
    ].join('  ·  ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(m.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(facts, style: const TextStyle(fontSize: 12.5, color: Palette.muted)),
        const SizedBox(height: 4),
        Text(
          m.matchedBy == 'hash' ? 'Matched by the file\'s hash: this exact file.' : 'Matched by file name.',
          style: const TextStyle(fontSize: 11.5, color: Palette.faint),
        ),
        if (m.preview != null) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: Image.network(
                m.preview!,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ],
        PanelHeading(
          'Trigger words',
          trailing: m.trainedWords.isEmpty
              ? null
              : TextButton(
                  onPressed: () => copyText(context, m.trainedWords.join(', '), 'trigger words'),
                  child: const Text('Copy all'),
                ),
        ),
        if (m.trainedWords.isEmpty)
          const Text('None listed.', style: TextStyle(fontSize: 12.5, color: Palette.muted))
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final w in m.trainedWords)
                ChoiceChipButton(label: w, selected: false, tooltip: 'Copy', onTap: () => copyText(context, w, 'trigger word')),
            ],
          ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: () => openUrl(m.url),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Open on Civitai'),
          ),
        ),
      ],
    );
  }
}
