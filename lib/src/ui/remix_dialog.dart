import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/backends.dart';
import '../core/models.dart';
import '../core/spelling.dart';
import '../theme.dart';
import 'meta_panel.dart' show copyText, toast;
import 'prompt_editor.dart';
import 'sheet.dart';

/// Open the remix panel for [item]: its prompt to edit (with spelling and
/// weights), its seed, size and count, and a button that queues it on
/// ComfyUI, InvokeAI or Forge.
Future<void> openRemix(BuildContext context, AppState state, MediaItem item) async {
  final GenInfo info;
  try {
    info = await state.metadata(item);
  } catch (e) {
    if (context.mounted) toast(context, 'Could not read this file');
    return;
  }
  if (!context.mounted) return;
  if (!info.hasGeneration) {
    toast(context, 'This picture has no generation data to remix');
    return;
  }
  await showPanel<void>(
    context,
    title: 'Remix ${item.name}',
    icon: Icons.auto_fix_high,
    width: 760,
    builder: (context) => RemixPanel(state: state, item: item, info: info),
  );
}

class RemixPanel extends StatefulWidget {
  const RemixPanel({
    super.key,
    required this.state,
    required this.item,
    required this.info,
  });
  final AppState state;

  /// The picture being remixed: the new ones are saved beside it.
  final MediaItem item;
  final GenInfo info;

  @override
  State<RemixPanel> createState() => _RemixPanelState();
}

class _RemixPanelState extends State<RemixPanel> {
  late final PromptController _prompt = PromptController(text: widget.info.prompt);
  late final PromptController _negative = PromptController(text: widget.info.negative);
  late final TextEditingController _seed = TextEditingController(text: widget.info.seed);
  late final TextEditingController _width;
  late final TextEditingController _height;
  bool _random = false;
  int _count = 1;
  String? _backend;
  bool _sending = false;
  String? _error;

  GenInfo get info => widget.info;

  @override
  void initState() {
    super.initState();
    final (w, h) = recipeSize(info);
    _width = TextEditingController(text: w > 0 ? '$w' : '1024');
    _height = TextEditingController(text: h > 0 ? '$h' : '1024');
    final support = backendSupport(info);
    // The program that made it, if it is set up and can take it; else the
    // first that can.
    final made = switch (info.source) {
      'comfyui' => 'comfyui',
      'invokeai' => 'invokeai',
      'a1111' || 'forge' => 'forge',
      _ => null,
    };
    final usable = [
      for (final k in backendNames.keys)
        if (support[k] == null) k,
    ];
    // A server that is set up first, and of those the one that made it.
    final urls = widget.state.backendUrls;
    final ready = [
      for (final k in usable)
        if ((urls[k] ?? '').isNotEmpty) k,
    ];
    final pool = ready.isNotEmpty ? ready : usable;
    _backend = pool.contains(made) ? made : (pool.isEmpty ? null : pool.first);
    _loadSpelling();
  }

  Future<void> _loadSpelling() async {
    final base = await Spelling.load();
    final folder = await widget.state.vocabulary();
    final spelling = base.withWords([...folder, ...widget.state.userWords]);
    if (!mounted) return;
    _prompt.spelling = spelling;
    _negative.spelling = spelling;
  }

  @override
  void dispose() {
    _prompt.dispose();
    _negative.dispose();
    _seed.dispose();
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final kind = _backend;
    if (kind == null) return;
    final url = widget.state.backendUrls[kind];
    if (url == null || url.isEmpty) {
      await openBackendSettings(context, widget.state, focus: kind);
      if (!mounted || (widget.state.backendUrls[kind] ?? '').isEmpty) return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final ticket = await sendRemix(
        kind,
        widget.state.backendUrls[kind]!,
        Remix(
          info: info,
          prompt: _prompt.text,
          negative: _negative.text,
          seed: int.tryParse(_seed.text.trim()) ?? 0,
          randomSeed: _random || int.tryParse(_seed.text.trim()) == null,
          count: _count,
          width: int.tryParse(_width.text) ?? 1024,
          height: int.tryParse(_height.text) ?? 1024,
        ),
      );
      // Waited for in the background, panel or no panel.
      widget.state.collectRemix(widget.item, ticket.results);
      if (!mounted) return;
      toast(
        context,
        '${ticket.message}. ${ticket.count == 1 ? 'It' : 'They'} will be '
        'saved beside the original and added to ${AppState.remixCollection}.',
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final support = backendSupport(info);
    final urls = widget.state.backendUrls;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PromptEditor(
            key: const ValueKey<String>('remix-prompt'),
            controller: _prompt,
            label: 'Prompt',
            minLines: 4,
            onAddWord: widget.state.addUserWord,
          ),
          const SizedBox(height: 4),
          const Text(
            'Select words to weight them; the caret in an underlined word offers corrections.',
            style: TextStyle(fontSize: 11.5, color: Palette.faint),
          ),
          const SizedBox(height: 12),
          PromptEditor(
            key: const ValueKey<String>('remix-negative'),
            controller: _negative,
            label: 'Negative prompt',
            minLines: 2,
            maxLines: 5,
            onAddWord: widget.state.addUserWord,
          ),
          const PanelHeading('Seed, size and count'),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 210,
                child: TextField(
                  key: const ValueKey<String>('remix-seed'),
                  controller: _seed,
                  enabled: !_random,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _box('Seed').copyWith(
                    suffixIcon: IconButton(
                      tooltip: 'A new random seed',
                      icon: const Icon(Icons.casino_outlined, size: 18),
                      onPressed: () => _seed.text = '${math.Random().nextInt(1 << 32)}',
                    ),
                  ),
                ),
              ),
              // The box is drawn on and off rather than a tick added, so
              // the chip keeps its size either way.
              FilterChip(
                key: const ValueKey<String>('remix-random'),
                showCheckmark: false,
                avatar: Icon(
                  _random ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 18,
                  color: _random ? Palette.accent : Palette.muted,
                ),
                label: const Text('Random each time'),
                selected: _random,
                onSelected: (v) => setState(() => _random = v),
              ),
              // Width and height are one control, kept on one line: when
              // they don't fit beside the seed they move down together.
              _SizeField(width: _width, height: _height),
              _Stepper(value: _count, min: 1, max: 16, label: _count == 1 ? 'picture' : 'pictures', onChanged: (v) => setState(() => _count = v)),
            ],
          ),
          if (!_random && _count > 1)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Each further picture uses the next seed.', style: TextStyle(fontSize: 11.5, color: Palette.faint)),
            ),
          PanelHeading(
            'Send to',
            trailing: TextButton.icon(
              onPressed: () async {
                await openBackendSettings(context, widget.state);
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.dns_outlined, size: 16),
              label: const Text('Servers…'),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final MapEntry(key: kind, value: name) in backendNames.entries)
                ChoiceChipButton(
                  label: name,
                  selected: _backend == kind,
                  icon: (urls[kind] ?? '').isEmpty ? Icons.link_off : Icons.dns_outlined,
                  tooltip: support[kind] ?? urls[kind] ?? 'Not set up yet: you will be asked where it is',
                  onTap: support[kind] == null ? () => setState(() => _backend = kind) : null,
                ),
            ],
          ),
          if (_backend != null && (urls[_backend] ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(urls[_backend]!, style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
            ),
          // Said in the panel, not only in a tooltip, so it reads on a tablet.
          if (_backend != null && _backend != 'forge' && !carriesGraph(_backend!, info))
            Padding(
              key: const ValueKey<String>('remix-built-graph'),
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'This picture was not made in ${backendNames[_backend]}, so it will get a standard '
                'text-to-image ${_backend == 'comfyui' ? 'workflow' : 'graph'} built from its settings: '
                'the same model and LoRAs (by name), prompt, seed, steps, CFG, sampler and size.',
                style: const TextStyle(fontSize: 11.5, color: Palette.muted),
              ),
            ),
          if (support.values.any((why) => why != null))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                support.values.firstWhere((why) => why != null)!,
                style: const TextStyle(fontSize: 11.5, color: Palette.faint),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: const TextStyle(fontSize: 12.5, color: Palette.danger, height: 1.35)),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => copyText(context, _prompt.text, 'prompt'),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy prompt'),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const ValueKey<String>('remix-send'),
                onPressed: _backend == null || _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send, size: 18),
                label: Text(_backend == null ? 'No server can take this' : 'Send to ${backendNames[_backend]}'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

InputDecoration _box(String label) => InputDecoration(
  labelText: label,
  isDense: true,
  filled: true,
  fillColor: Palette.raised,
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
);

/// Width, a swap button, and height, in one box.
class _SizeField extends StatelessWidget {
  const _SizeField({required this.width, required this.height});
  final TextEditingController width;
  final TextEditingController height;

  @override
  Widget build(BuildContext context) {
    Widget field(TextEditingController controller, String label, String key) => SizedBox(
          width: 76,
          child: TextField(
            key: ValueKey<String>(key),
            controller: controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: _box(label).copyWith(fillColor: Colors.transparent),
          ),
        );
    return Container(
      key: const ValueKey<String>('remix-size'),
      decoration: BoxDecoration(color: Palette.raised, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          field(width, 'Width', 'remix-width'),
          IconButton(
            tooltip: 'Swap width and height',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.swap_horiz, size: 20),
            onPressed: () {
              final w = width.text;
              width.text = height.text;
              height.text = w;
            },
          ),
          field(height, 'Height', 'remix-height'),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.min, required this.max, required this.label, required this.onChanged});
  final int value;
  final int min;
  final int max;
  final String label;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Palette.raised, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(tooltip: 'Fewer', icon: const Icon(Icons.remove, size: 18), onPressed: value > min ? () => onChanged(value - 1) : null),
          Text('$value $label', style: const TextStyle(fontSize: 13)),
          IconButton(tooltip: 'More', icon: const Icon(Icons.add, size: 18), onPressed: value < max ? () => onChanged(value + 1) : null),
        ],
      ),
    );
  }
}

/// Where the generation servers are. [focus] is the one to fill in now.
Future<void> openBackendSettings(BuildContext context, AppState state, {String? focus}) {
  return showPanel<void>(
    context,
    title: 'Generation servers',
    icon: Icons.dns_outlined,
    width: 520,
    builder: (context) => _BackendSettings(state: state, focus: focus),
  );
}

class _BackendSettings extends StatefulWidget {
  const _BackendSettings({required this.state, this.focus});
  final AppState state;
  final String? focus;

  @override
  State<_BackendSettings> createState() => _BackendSettingsState();
}

class _BackendSettingsState extends State<_BackendSettings> {
  late final Map<String, TextEditingController> _urls = {
    for (final k in backendNames.keys) k: TextEditingController(text: widget.state.backendUrls[k] ?? ''),
  };
  final Map<String, String> _status = {};

  @override
  void dispose() {
    for (final c in _urls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _test(String kind) async {
    final url = _urls[kind]!.text.trim().replaceFirst(RegExp(r'/+$'), '');
    widget.state.setBackendUrl(kind, url);
    if (url.isEmpty) return;
    setState(() => _status[kind] = 'Checking…');
    try {
      final what = await probeBackend(kind, url);
      if (mounted) setState(() => _status[kind] = '✓ $what');
    } catch (e) {
      if (mounted) setState(() => _status[kind] = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Remixed prompts are sent to these addresses. Leave one empty if you do not use it. '
            'Nothing is sent anywhere until you press Send.',
            style: TextStyle(fontSize: 12.5, color: Palette.muted, height: 1.4),
          ),
          for (final MapEntry(key: kind, value: name) in backendNames.entries) ...[
            PanelHeading(name),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urls[kind],
                    autofocus: widget.focus == kind,
                    keyboardType: TextInputType.url,
                    decoration: _box('Address').copyWith(hintText: backendDefaults[kind]),
                    onSubmitted: (_) => _test(kind),
                    onChanged: (v) => widget.state.setBackendUrl(kind, v),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: () => _test(kind), child: const Text('Test')),
              ],
            ),
            if (_status[kind] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _status[kind]!,
                  style: TextStyle(fontSize: 12, color: _status[kind]!.startsWith('✓') ? const Color(0xFF7BC88F) : Palette.muted),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
