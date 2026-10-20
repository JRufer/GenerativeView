import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/backends.dart';
import '../core/civitai.dart';
import '../core/lora_edits.dart';
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

  /// Width over height, as the picture is: kept while the size is locked.
  late final double _aspect;

  /// The picture's LoRAs, as the user sets them.
  late final List<LoraChoice> _loras = [for (final l in widget.info.loras) LoraChoice(l)];
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
    _aspect = w > 0 && h > 0 ? w / h : 1;
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
          loras: _loras.isEmpty ? null : [for (final l in _loras) l.copy()],
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
              SizeField(width: _width, height: _height, aspect: _aspect),
              _Stepper(value: _count, min: 1, max: 16, label: _count == 1 ? 'picture' : 'pictures', onChanged: (v) => setState(() => _count = v)),
            ],
          ),
          if (!_random && _count > 1)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Each further picture uses the next seed.', style: TextStyle(fontSize: 11.5, color: Palette.faint)),
            ),
          if (_loras.isNotEmpty) LoraSection(loras: _loras, prompt: _prompt),
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

/// Width and height in one box, with a lock above the swap button between
/// them. Locked (blue, the default), a new width brings the height along so
/// the picture keeps its shape, [aspect] (width over height), and the
/// reverse; the side brought along glows for a moment to say so. Unlocked
/// (white), either side is set freely.
class SizeField extends StatefulWidget {
  const SizeField({super.key, required this.width, required this.height, required this.aspect});
  final TextEditingController width;
  final TextEditingController height;
  final double aspect;

  @override
  State<SizeField> createState() => _SizeFieldState();
}

class _SizeFieldState extends State<SizeField> {
  bool _locked = true;
  late double _aspect = widget.aspect > 0 ? widget.aspect : 1;

  /// The side most recently brought along, while it glows.
  String? _glowing;
  Timer? _glow;

  @override
  void dispose() {
    _glow?.cancel();
    super.dispose();
  }

  void _typed(bool isWidth, String text) {
    if (!_locked) return;
    final v = int.tryParse(text);
    if (v == null || v <= 0) return;
    final other = math.max(1, (isWidth ? v / _aspect : v * _aspect).round());
    (isWidth ? widget.height : widget.width).text = '$other';
    _flash(isWidth ? 'height' : 'width');
  }

  void _flash(String side) {
    _glow?.cancel();
    setState(() => _glowing = side);
    _glow = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _glowing = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    Widget field(TextEditingController controller, String label, String side) {
      final glow = _glowing == side;
      return AnimatedContainer(
        key: ValueKey<String>('remix-$side-glow'),
        duration: still ? Duration.zero : Duration(milliseconds: glow ? 120 : 420),
        curve: Curves.easeOut,
        width: 76,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: glow ? Palette.accent : Colors.transparent, width: 1.5),
          boxShadow: [
            if (glow) BoxShadow(color: Palette.accent.withValues(alpha: 0.45), blurRadius: 8),
          ],
        ),
        child: TextField(
          key: ValueKey<String>('remix-$side'),
          controller: controller,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: _box(label).copyWith(fillColor: Colors.transparent),
          onChanged: (text) => _typed(side == 'width', text),
        ),
      );
    }

    Widget small({required Key key, required IconData icon, required String tooltip, required Color color, required VoidCallback onTap}) =>
        Tooltip(
          message: tooltip,
          child: InkResponse(
            key: key,
            onTap: onTap,
            radius: 18,
            child: SizedBox(width: 34, height: 26, child: Icon(icon, size: 18, color: color)),
          ),
        );

    return Container(
      key: const ValueKey<String>('remix-size'),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: Palette.raised, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          field(widget.width, 'Width', 'width'),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              small(
                key: const ValueKey<String>('remix-size-lock'),
                icon: _locked ? Icons.lock : Icons.lock_open,
                color: _locked ? Palette.accent : Colors.white,
                tooltip: _locked
                    ? 'Shape locked: changing one side changes the other. Tap to unlock'
                    : 'Shape unlocked: either side changes freely. Tap to lock',
                onTap: () => setState(() => _locked = !_locked),
              ),
              small(
                key: const ValueKey<String>('remix-size-swap'),
                icon: Icons.swap_horiz,
                color: Palette.text,
                tooltip: 'Swap width and height',
                onTap: () {
                  final w = widget.width.text;
                  widget.width.text = widget.height.text;
                  widget.height.text = w;
                  // Turned on its side, the shape kept is too.
                  _aspect = 1 / _aspect;
                },
              ),
            ],
          ),
          field(widget.height, 'Height', 'height'),
        ],
      ),
    );
  }
}

/// The picture's LoRAs, folded away until opened: each with a switch to
/// leave it out of the remix and a slider for its weight, from −1 to 2,
/// that starts where the picture had it and shows in grey how far it has
/// been moved.
///
/// "Check trigger words" looks each LoRA up on Civitai (its name and hash
/// are all that is sent, and only when pressed) and lists the words that
/// trigger it: those already in [prompt] ticked, the rest a tap away from
/// being added. A LoRA left on with none of its words in the prompt is
/// pointed out, on its row and, folded, beside the heading. What was found
/// is remembered while the app is open, so the next remix shows it at once.
class LoraSection extends StatefulWidget {
  const LoraSection({super.key, required this.loras, this.prompt, this.lookUp});
  final List<LoraChoice> loras;

  /// The prompt being edited, to check and add trigger words to.
  final TextEditingController? prompt;

  /// How to look a LoRA up; Civitai, unless a test says otherwise.
  final ModelLookup? lookUp;

  @override
  State<LoraSection> createState() => _LoraSectionState();
}

/// What is known of one LoRA's trigger words.
class _Triggers {
  const _Triggers({this.looking = false, this.found = false, this.model, this.error});
  final bool looking;

  /// Looked up (whether or not Civitai knew it).
  final bool found;
  final CivitaiModel? model;
  final String? error;

  List<String> get words => model?.trainedWords.where((w) => w.trim().isNotEmpty).toList() ?? const [];
}

class _LoraSectionState extends State<LoraSection> {
  bool _open = false;
  late final List<_Triggers> _triggers = [
    for (final l in widget.loras) _cached(l.original),
  ];

  /// What lookups found while the app has been open, by name and hash.
  static final Map<String, CivitaiModel?> _known = {};

  static _Triggers _cached(LoraRef lora) {
    final key = '${lora.hash}|${lora.name}';
    if (_known.containsKey(key)) return _Triggers(found: true, model: _known[key]);
    // Looked up already from the metadata panel, perhaps.
    final (known, model) = cachedModel(name: lora.name, hash: lora.hash);
    return known ? _Triggers(found: true, model: model) : const _Triggers();
  }

  @override
  void initState() {
    super.initState();
    widget.prompt?.addListener(_promptChanged);
  }

  @override
  void dispose() {
    widget.prompt?.removeListener(_promptChanged);
    super.dispose();
  }

  void _promptChanged() {
    if (mounted) setState(() {});
  }

  bool get _looking => _triggers.any((t) => t.looking);

  Future<void> _check() async {
    final lookUp = widget.lookUp ?? lookUpModel;
    await Future.wait([
      for (var i = 0; i < widget.loras.length; i++)
        () async {
          if (_triggers[i].found) return;
          setState(() => _triggers[i] = const _Triggers(looking: true));
          final lora = widget.loras[i].original;
          _Triggers result;
          try {
            final model = await lookUp(name: lora.name, hash: lora.hash, kind: 'lora');
            _known['${lora.hash}|${lora.name}'] = model;
            result = _Triggers(found: true, model: model);
          } catch (e) {
            result = _Triggers(error: '$e');
          }
          if (mounted) setState(() => _triggers[i] = result);
        }(),
    ]);
  }

  /// Whether LoRA [i] is on, has trigger words, and none of them is in
  /// the prompt.
  bool _missing(int i) {
    final prompt = widget.prompt;
    if (prompt == null || !widget.loras[i].enabled) return false;
    final words = _triggers[i].words;
    return words.isNotEmpty && !words.any((w) => triggerPresent(prompt.text, w));
  }

  void _add(String entry) {
    final prompt = widget.prompt;
    if (prompt == null) return;
    final text = addTrigger(prompt.text, entry);
    prompt.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    final loras = widget.loras;
    final changed = loras.where((l) => l.changed).length;
    final off = loras.where((l) => !l.enabled).length;
    final missing = [for (var i = 0; i < loras.length; i++) if (_missing(i)) i].length;
    final summary = [
      '${loras.length}',
      if (off > 0) '$off off',
      if (changed - off > 0) '${changed - off} changed',
    ].join(' · ');
    final unchecked = widget.prompt != null && _triggers.any((t) => !t.found);
    final rows = !_open
        ? const SizedBox(width: double.infinity)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (unchecked || _looking)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      TextButton.icon(
                        key: const ValueKey<String>('remix-lora-triggers'),
                        onPressed: _looking ? null : _check,
                        icon: _looking
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.travel_explore, size: 16),
                        label: const Text('Check trigger words'),
                      ),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'Looks each LoRA up on civitai.com by its name and hash; nothing else is sent.',
                          style: TextStyle(fontSize: 11.5, color: Palette.faint),
                        ),
                      ),
                    ],
                  ),
                ),
              for (var i = 0; i < loras.length; i++)
                _LoraRow(
                  key: ValueKey<String>('remix-lora-$i'),
                  index: i,
                  choice: loras[i],
                  triggers: _triggers[i],
                  prompt: widget.prompt?.text,
                  missing: _missing(i),
                  onAdd: _add,
                  onChanged: () => setState(() {}),
                ),
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        InkWell(
          key: const ValueKey<String>('remix-loras'),
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: still ? Duration.zero : const Duration(milliseconds: 180),
                  child: const Icon(Icons.chevron_right, size: 18, color: Palette.faint),
                ),
                const SizedBox(width: 4),
                const Text(
                  'LORAS',
                  style: TextStyle(fontSize: 10.5, letterSpacing: 0.9, fontWeight: FontWeight.w600, color: Palette.faint),
                ),
                const SizedBox(width: 8),
                Text(
                  summary,
                  key: const ValueKey<String>('remix-loras-summary'),
                  style: TextStyle(fontSize: 11.5, color: changed > 0 ? Palette.accent : Palette.faint),
                ),
                if (missing > 0) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.warning_amber_rounded, size: 15, color: _warn),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      missing == 1 ? '1 without its trigger words' : '$missing without their trigger words',
                      key: const ValueKey<String>('remix-loras-missing'),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: _warn),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // AnimatedSize cannot take a zero duration, so with motion turned
        // down the list simply appears.
        if (still)
          rows
        else
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: rows,
          ),
      ],
    );
  }
}

const Color _warn = Color(0xFFE6B450);

class _LoraRow extends StatelessWidget {
  const _LoraRow({
    super.key,
    required this.index,
    required this.choice,
    required this.onChanged,
    this.triggers = const _Triggers(),
    this.prompt,
    this.missing = false,
    this.onAdd,
  });
  final int index;
  final LoraChoice choice;
  final VoidCallback onChanged;
  final _Triggers triggers;

  /// The prompt as it stands, to tick the trigger words already in it.
  final String? prompt;

  /// On, with trigger words, none of them in the prompt.
  final bool missing;

  /// Put a trigger-word entry into the prompt.
  final ValueChanged<String>? onAdd;

  @override
  Widget build(BuildContext context) {
    final c = choice;
    var name = c.original.name.split(RegExp(r'[/\\]')).last;
    name = name.replaceFirst(RegExp(r'\.(safetensors|ckpt|pt|pth|bin)$', caseSensitive: false), '');
    final offset = c.offset;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 4, 6, 6),
      decoration: BoxDecoration(
        color: Palette.raised,
        borderRadius: BorderRadius.circular(6),
        border: missing ? Border.all(color: _warn.withValues(alpha: 0.55)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (missing)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Tooltip(
                    message: 'None of its trigger words is in the prompt',
                    child: Icon(Icons.warning_amber_rounded, size: 16, color: _warn),
                  ),
                ),
              Expanded(
                child: Tooltip(
                  message: c.original.name,
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: c.enabled ? Palette.text : Palette.faint,
                      decoration: c.enabled ? null : TextDecoration.lineThrough,
                    ),
                  ),
                ),
              ),
              if (c.enabled) ...[
                Text(
                  weightText(c.weight),
                  key: ValueKey<String>('remix-lora-weight-$index'),
                  style: const TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()]),
                ),
                if (c.reweighted)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      '${offset > 0 ? '+' : '−'}${weightText(offset.abs())}',
                      key: ValueKey<String>('remix-lora-offset-$index'),
                      style: const TextStyle(fontSize: 11.5, color: Palette.muted, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
              ],
              SizedBox(
                width: 34,
                child: c.reweighted
                    ? IconButton(
                        key: ValueKey<String>('remix-lora-reset-$index'),
                        tooltip: 'Back to ${weightText(c.originalWeight)}, as the picture had it',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.undo, size: 16),
                        onPressed: () {
                          c.weight = c.originalWeight;
                          onChanged();
                        },
                      )
                    : null,
              ),
              Switch(
                key: ValueKey<String>('remix-lora-switch-$index'),
                value: c.enabled,
                onChanged: (v) {
                  c.enabled = v;
                  onChanged();
                },
              ),
            ],
          ),
          WeightSlider(
            key: ValueKey<String>('remix-lora-slider-$index'),
            value: c.weight,
            origin: c.originalWeight,
            enabled: c.enabled,
            onChanged: (v) {
              c.weight = v;
              onChanged();
            },
          ),
          ?_triggerLine(),
        ],
      ),
    );
  }

  /// The LoRA's trigger words, once looked up: those in the prompt ticked,
  /// the others to tap and add.
  Widget? _triggerLine() {
    final t = triggers;
    const note = TextStyle(fontSize: 11.5, color: Palette.faint);
    if (t.looking) return null;
    if (t.error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(t.error!, key: ValueKey<String>('remix-lora-trigger-error-$index'), style: note),
      );
    }
    if (!t.found) return null;
    if (t.model == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text('Not found on Civitai', key: ValueKey<String>('remix-lora-unknown-$index'), style: note),
      );
    }
    final words = t.words;
    if (words.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text('Civitai lists no trigger words for it', key: ValueKey<String>('remix-lora-nowords-$index'), style: note),
      );
    }
    final text = prompt ?? '';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var w = 0; w < words.length; w++)
            if (triggerPresent(text, words[w]))
              Tooltip(
                message: 'In the prompt',
                child: Chip(
                  key: ValueKey<String>('remix-lora-word-$index-$w'),
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.check, size: 14, color: Palette.accent),
                  label: Text(words[w], style: const TextStyle(fontSize: 12, color: Palette.muted)),
                ),
              )
            else
              ActionChip(
                key: ValueKey<String>('remix-lora-word-$index-$w'),
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.add, size: 14),
                tooltip: 'Add to the start of the prompt',
                label: Text(words[w], style: const TextStyle(fontSize: 12)),
                onPressed: onAdd == null ? null : () => onAdd!(words[w]),
              ),
        ],
      ),
    );
  }
}

/// A slider for a LoRA weight, from [loraWeightMin] to [loraWeightMax] in
/// steps of 0.05 (or wider, for a picture made outside that). A tick marks
/// [origin], the weight the picture was made with, and a grey band runs
/// from there to the thumb: how far it has been moved, and which way.
/// Drag or tap it; the arrow keys move it a step.
class WeightSlider extends StatefulWidget {
  const WeightSlider({
    super.key,
    required this.value,
    required this.origin,
    required this.onChanged,
    this.enabled = true,
  });
  final double value;
  final double origin;
  final ValueChanged<double> onChanged;
  final bool enabled;

  static const double step = 0.05;

  @override
  State<WeightSlider> createState() => _WeightSliderState();
}

class _WeightSliderState extends State<WeightSlider> {
  final FocusNode _focus = FocusNode(debugLabel: 'weight slider');
  bool _focused = false;
  bool _dragging = false;

  double get _min => math.min(loraWeightMin, widget.origin);
  double get _max => math.max(loraWeightMax, widget.origin);

  static const double _pad = 12;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  double _snap(double v) {
    final snapped = (v / WeightSlider.step).round() * WeightSlider.step;
    // The picture's own weight is a stop too, wherever it falls.
    final near = (v - widget.origin).abs() < WeightSlider.step / 2 ? widget.origin : snapped;
    return double.parse(near.clamp(_min, _max).toStringAsFixed(4));
  }

  void _toX(double dx, double width) {
    final track = width - 2 * _pad;
    if (track <= 0) return;
    final t = ((dx - _pad) / track).clamp(0.0, 1.0);
    final v = _snap(_min + t * (_max - _min));
    if (v != widget.value) widget.onChanged(v);
  }

  void _nudge(int steps) {
    final v = _snap(widget.value + steps * WeightSlider.step);
    if (v != widget.value) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return Semantics(
      slider: true,
      enabled: enabled,
      value: weightText(widget.value),
      increasedValue: weightText(_snap(widget.value + WeightSlider.step)),
      decreasedValue: weightText(_snap(widget.value - WeightSlider.step)),
      onIncrease: enabled ? () => _nudge(1) : null,
      onDecrease: enabled ? () => _nudge(-1) : null,
      child: Focus(
        focusNode: _focus,
        canRequestFocus: enabled,
        onFocusChange: (f) => setState(() => _focused = f),
        onKeyEvent: (node, event) {
          if (!enabled || event is KeyUpEvent) return KeyEventResult.ignored;
          final k = event.logicalKey;
          if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowUp) {
            _nudge(1);
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowDown) {
            _nudge(-1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: enabled
                  ? (d) {
                      _focus.requestFocus();
                      _toX(d.localPosition.dx, width);
                    }
                  : null,
              onHorizontalDragStart: enabled
                  ? (d) {
                      _focus.requestFocus();
                      setState(() => _dragging = true);
                      _toX(d.localPosition.dx, width);
                    }
                  : null,
              onHorizontalDragUpdate: enabled ? (d) => _toX(d.localPosition.dx, width) : null,
              onHorizontalDragEnd: enabled ? (_) => setState(() => _dragging = false) : null,
              onHorizontalDragCancel: enabled ? () => setState(() => _dragging = false) : null,
              child: SizedBox(
                height: 36,
                width: width,
                child: CustomPaint(
                  painter: _WeightPainter(
                    min: _min,
                    max: _max,
                    value: widget.value,
                    origin: widget.origin,
                    enabled: enabled,
                    active: _focused || _dragging,
                    pad: _pad,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WeightPainter extends CustomPainter {
  _WeightPainter({
    required this.min,
    required this.max,
    required this.value,
    required this.origin,
    required this.enabled,
    required this.active,
    required this.pad,
  });
  final double min;
  final double max;
  final double value;
  final double origin;
  final bool enabled;
  final bool active;
  final double pad;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final left = pad;
    final right = size.width - pad;
    double x(double v) => left + (v - min) / (max - min) * (right - left);
    final dim = enabled ? 1.0 : 0.4;

    // The track.
    canvas.drawRRect(
      RRect.fromLTRBR(left, y - 2, right, y + 2, const Radius.circular(2)),
      Paint()..color = Palette.line.withValues(alpha: dim),
    );
    // Zero, faintly: below it a LoRA works against itself.
    canvas.drawRect(
      Rect.fromLTWH(x(0) - 0.5, y - 4, 1, 8),
      Paint()..color = Palette.faint.withValues(alpha: 0.6 * dim),
    );
    // How far it has moved from where the picture had it.
    final ox = x(origin);
    final vx = x(value);
    if ((vx - ox).abs() > 0.5) {
      canvas.drawRRect(
        RRect.fromLTRBR(math.min(ox, vx), y - 4, math.max(ox, vx), y + 4, const Radius.circular(3)),
        Paint()..color = const Color(0xFF8A8A96).withValues(alpha: 0.55 * dim),
      );
    }
    // Where the picture had it.
    canvas.drawRRect(
      RRect.fromLTRBR(ox - 1.5, y - 8, ox + 1.5, y + 8, const Radius.circular(1.5)),
      Paint()..color = Palette.muted.withValues(alpha: dim),
    );
    // The thumb.
    if (active && enabled) {
      canvas.drawCircle(Offset(vx, y), 14, Paint()..color = Palette.accent.withValues(alpha: 0.18));
    }
    canvas.drawCircle(
      Offset(vx, y),
      8,
      Paint()..color = enabled ? Palette.accent : Palette.faint,
    );
  }

  @override
  bool shouldRepaint(_WeightPainter old) =>
      old.value != value || old.origin != origin || old.enabled != enabled || old.active != active || old.min != min || old.max != max;
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
