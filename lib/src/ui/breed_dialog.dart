import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/backends.dart';
import '../core/lora_edits.dart';
import '../core/models.dart';
import '../core/prompt_edits.dart' show weightUp;
import '../theme.dart';
import '../core/audience.dart';
import 'audience_widgets.dart' show AudienceBadge, BreedAudienceSection;
import 'kit.dart';
import 'meta_panel.dart' show toast;
import 'remix_dialog.dart' show SizeField, SizeSlider, cfgText, openBackendSettings, remixTwoColumns, snapSize;
import 'sheet.dart';

/// The colours that tie each phrase of a bred prompt to its parent.
const List<Color> parentColors = [Palette.accent, keepGreen, attention, Color(0xFFC792EA)];

/// Breed new pictures from two to four [parents]: recipes mixed from
/// theirs, the likeliest liked first, sent to a server like a remix and
/// saved beside the parent each is made on, in the Remixes collection.
Future<void> openBreed(BuildContext context, AppState state, List<MediaItem> parents) async {
  final pictures = [for (final p in parents) if (!p.isVideo) p];
  if (pictures.length < 2 || pictures.length > 4) {
    toast(context, 'Tick two to four pictures to breed from');
    return;
  }
  final List<GenInfo> infos;
  try {
    infos = await Future.wait([for (final p in pictures) state.metadata(p)]);
  } catch (e) {
    if (context.mounted) toast(context, 'Could not read the pictures');
    return;
  }
  if (!context.mounted) return;
  if (infos.any((i) => !i.hasGeneration)) {
    toast(context, 'Every picture bred from needs its generation data');
    return;
  }
  await showPanel<void>(
    context,
    title: 'Breed new pictures from ${pictures.length}',
    icon: Icons.hub_outlined,
    width: MediaQuery.sizeOf(context).width >= 900 ? 1120 : 760,
    builder: (context) => BreedPanel(state: state, parents: pictures, infos: infos),
  );
}

class BreedPanel extends StatefulWidget {
  const BreedPanel({super.key, required this.state, required this.parents, required this.infos});
  final AppState state;
  final List<MediaItem> parents;
  final List<GenInfo> infos;

  @override
  State<BreedPanel> createState() => _BreedPanelState();
}

class _BreedPanelState extends State<BreedPanel> {
  bool _phrases = true;
  bool _loras = true;
  bool _settings = true;
  bool _model = false;
  double _change = 0.35;
  int _seed = 1;

  List<BredChild>? _children;
  bool _rated = false;
  bool _loading = false;
  String? _error;

  /// The audience level every candidate is aimed at; 0 for as bred.
  int _audience = 0;

  /// Each candidate aimed at [_audience], or what it reads as when 0.
  List<AudienceSteer?> _steers = const [];

  /// The children ticked to render.
  final Set<int> _ticked = {};

  String? _backend;
  bool _sending = false;

  /// The size every new picture is made at: the first parent's to start,
  /// set as in Remix, with the same box, lock and slider.
  late final (int, int) _original = recipeSize(widget.infos.first);
  late final TextEditingController _width = TextEditingController(text: '${snapSize(_original.$1 > 0 ? _original.$1 : 1024)}');
  late final TextEditingController _height = TextEditingController(text: '${snapSize(_original.$2 > 0 ? _original.$2 : 1024)}');
  late final double _aspect = _original.$1 > 0 && _original.$2 > 0 ? _original.$1 / _original.$2 : 1;

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final urls = widget.state.backendUrls;
    final support = backendSupport(widget.infos.first);
    final ready = [
      for (final k in backendNames.keys)
        if (support[k] == null && (urls[k] ?? '').isNotEmpty) k,
    ];
    final made = switch (widget.infos.first.source) {
      'comfyui' => 'comfyui',
      'invokeai' => 'invokeai',
      'a1111' || 'forge' => 'forge',
      _ => null,
    };
    // A server that is set up, the one that made the first picture if it is;
    // otherwise the one that made it, to be set up on sending.
    _backend = ready.contains(made) ? made : (ready.isNotEmpty ? ready.first : (made ?? 'comfyui'));
    _write();
  }

  /// Ask for a new set of children, as the choices now are.
  Future<void> _write() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (children, rated) = await widget.state.breed(
        widget.parents,
        phrases: _phrases,
        loras: _loras,
        settings: _settings,
        model: _model,
        change: _change,
        seed: _seed,
      );
      if (!mounted) return;
      setState(() {
        _children = children;
        _rated = rated;
        _ticked
          ..clear()
          ..addAll([for (var i = 0; i < math.min(4, children.length); i++) i]);
      });
      await _aimAll();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Aim every candidate at the chosen audience level.
  Future<void> _aimAll() async {
    final children = _children;
    if (children == null) return;
    final target = _audience;
    final steers = await Future.wait([
      for (final child in children)
        widget.state.steerAudience(child.prompt, widget.infos[child.base].negative, target).then<AudienceSteer?>((s) => s, onError: (Object _) => null),
    ]);
    // A newer choice, or newer candidates, have taken over.
    if (mounted && target == _audience && identical(children, _children)) setState(() => _steers = steers);
  }

  void _toggle(VoidCallback change) {
    setState(change);
    _write();
  }

  Future<void> _send() async {
    final kind = _backend;
    final children = _children;
    if (kind == null || children == null || _ticked.isEmpty) return;
    if ((widget.state.backendUrls[kind] ?? '').isEmpty) {
      await openBackendSettings(context, widget.state, focus: kind);
      if (!mounted || (widget.state.backendUrls[kind] ?? '').isEmpty) return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    // Every server takes multiples of 16: a size typed otherwise is
    // rounded, and shown rounded.
    final width = snapSize(int.tryParse(_width.text) ?? 1024);
    final height = snapSize(int.tryParse(_height.text) ?? 1024);
    _width.text = '$width';
    _height.text = '$height';
    var sent = 0;
    try {
      for (final i in _ticked.toList()..sort()) {
        final child = children[i];
        final base = widget.parents[child.base];
        final info = widget.infos[child.base];
        // The base's LoRA tags stay in the prompt (Forge reads them there);
        // their weights follow the child's.
        final tags = RegExp(r'<lora:[^>]+>', caseSensitive: false).allMatches(info.prompt).map((m) => m.group(0)!).join(' ');
        final loras = [
          for (final l in info.loras)
            LoraChoice(l, weight: child.loras.where((c) => c.$1 == l.name).map((c) => c.$2).firstOrNull ?? l.weight),
        ];
        final aimed = _audience != 0 && i < _steers.length ? _steers[i] : null;
        final ticket = await sendRemix(
          kind,
          widget.state.backendUrls[kind]!,
          Remix(
            info: info,
            prompt: () {
              final text = aimed == null ? child.prompt : weightUp(aimed.prompt, aimed.emphasize);
              return tags.isEmpty ? text : '$text $tags';
            }(),
            negative: aimed?.negative ?? info.negative,
            seed: 0,
            randomSeed: true,
            count: 1,
            width: width,
            height: height,
            steps: child.steps,
            cfg: child.cfg,
            loras: loras.isEmpty ? null : loras,
          ),
        );
        widget.state.collectRemix(base, ticket, label: 'bred');
        sent++;
      }
      if (!mounted) return;
      toast(context, 'Sent $sent to ${backendNames[kind]}. They will be saved beside their parents and added to ${AppState.remixCollection}.');
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() => _error = sent == 0 ? '$e' : 'Sent $sent, then: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = <Widget>[
      const PanelHeading('Parents'),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ThumbStrip(state: widget.state, items: widget.parents, size: 64, borders: parentColors),
          const SizedBox(
            width: 220,
            child: Text(
              'Underlines show which picture each phrase came from; blue words are new.',
              style: TextStyle(fontSize: 11.5, color: Palette.faint, height: 1.35),
            ),
          ),
        ],
      ),
      const PanelHeading('Mix'),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          ChoiceChipButton(
            key: const ValueKey<String>('breed-mix-phrases'),
            label: 'Prompt phrases',
            icon: Icons.notes,
            selected: _phrases,
            onTap: () => _toggle(() => _phrases = !_phrases),
          ),
          ChoiceChipButton(
            key: const ValueKey<String>('breed-mix-loras'),
            label: 'LoRAs',
            icon: Icons.layers_outlined,
            selected: _loras,
            onTap: () => _toggle(() => _loras = !_loras),
          ),
          ChoiceChipButton(
            key: const ValueKey<String>('breed-mix-settings'),
            label: 'Settings',
            icon: Icons.tune,
            selected: _settings,
            onTap: () => _toggle(() => _settings = !_settings),
          ),
          ChoiceChipButton(
            key: const ValueKey<String>('breed-mix-model'),
            label: 'Model',
            icon: Icons.memory,
            tooltip: 'Make some on another parent\'s recipe and model, not only the first one\'s',
            selected: _model,
            onTap: () => _toggle(() => _model = !_model),
          ),
        ],
      ),
      BreedAudienceSection(
        target: _audience,
        onChanged: (level) {
          setState(() => _audience = level);
          _aimAll();
        },
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          const Text('Change', style: TextStyle(fontSize: 13, color: Palette.muted)),
          Expanded(
            child: Slider(
              key: const ValueKey<String>('breed-change'),
              value: _change,
              onChanged: (v) => setState(() => _change = v),
              onChangeEnd: (_) => _write(),
            ),
          ),
        ],
      ),
      const Padding(
        padding: EdgeInsets.only(left: 58),
        child: Row(
          children: [
            Text('Close to the parents', style: TextStyle(fontSize: 11, color: Palette.faint)),
            Spacer(),
            Text('Adventurous', style: TextStyle(fontSize: 11, color: Palette.faint)),
          ],
        ),
      ),
      const PanelHeading('Size'),
      SizeField(key: const ValueKey<String>('breed-size'), width: _width, height: _height, aspect: _aspect, expand: true),
      SizeSlider(key: const ValueKey<String>('breed-size-slider'), width: _width, height: _height, original: _original),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('Every picture rendered is made at this size.', style: TextStyle(fontSize: 11.5, color: Palette.faint)),
      ),
    ];
    final children = _children;
    final right = <Widget>[
      PanelHeading(
        'Candidates',
        trailing: TextButton.icon(
          key: const ValueKey<String>('breed-more'),
          onPressed: _loading
              ? null
              : () {
                  _seed++;
                  _write();
                },
          icon: const Icon(Icons.casino_outlined, size: 16),
          label: const Text('Write more'),
        ),
      ),
      if (!_rated && children != null && children.isNotEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Rate or flag some pictures and turn on content search, and the likeliest liked come first.',
            style: TextStyle(fontSize: 11.5, color: Palette.faint, height: 1.35),
          ),
        ),
      if (_loading && children == null)
        const Padding(padding: EdgeInsets.all(20), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))))
      else if (children != null)
        for (var i = 0; i < children.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _Candidate(
              key: ValueKey<String>('breed-child-$i'),
              candidate: children[i],
              steer: i < _steers.length ? _steers[i] : null,
              aiming: _audience != 0,
              ticked: _ticked.contains(i),
              faded: _loading,
              onTap: () => setState(() => _ticked.contains(i) ? _ticked.remove(i) : _ticked.add(i)),
            ),
          ),
    ];
    final body = LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= remixTwoColumns;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left)),
                    const SizedBox(width: 24),
                    Expanded(flex: 6, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
                  ],
                )
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...left, ...right]),
        );
      },
    );
    final support = backendSupport(widget.infos.first);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(child: body),
        ServerSendBar(
          state: widget.state,
          backend: _backend,
          support: support,
          onBackend: (k) => setState(() => _backend = k),
          onServersChanged: () {
            if (mounted) setState(() {});
          },
          chipKey: (k) => ValueKey<String>('breed-server-$k'),
          actionKey: const ValueKey<String>('breed-send'),
          action: 'Render ${_ticked.length}',
          onSend: _backend == null || _ticked.isEmpty || _loading ? null : _send,
          sending: _sending,
          error: _error,
          leading: Text('Results go to ${AppState.remixCollection}', style: const TextStyle(fontSize: 12, color: Palette.faint)),
        ),
      ],
    );
  }
}

/// One proposed recipe: its prompt with each phrase underlined in the
/// colour of the parent it came from, its settings, and how the user would
/// likely rate it.
class _Candidate extends StatelessWidget {
  const _Candidate({super.key, required this.candidate, required this.ticked, required this.onTap, this.faded = false, this.steer, this.aiming = false});
  final BredChild candidate;

  /// The candidate aimed at an audience level: parts it takes out are
  /// struck through, and the level shown is where it ends up.
  final AudienceSteer? steer;
  final bool aiming;
  final bool ticked;
  final bool faded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final child = candidate;
    final spans = <InlineSpan>[];
    for (var i = 0; i < child.phrases.length; i++) {
      final p = child.phrases[i];
      if (i > 0) spans.add(const TextSpan(text: ', '));
      final from = p.from;
      final out = aiming && (steer?.removed.contains(p.text.trim()) ?? false);
      if (out) {
        spans.add(TextSpan(
          text: p.text,
          style: const TextStyle(color: Palette.danger, decoration: TextDecoration.lineThrough, decorationColor: Palette.danger),
        ));
        continue;
      }
      spans.add(
        from == null
            ? TextSpan(text: p.text, style: const TextStyle(color: Palette.accent))
            : TextSpan(
                text: p.text,
                style: TextStyle(
                  decoration: TextDecoration.underline,
                  decorationColor: parentColors[from % parentColors.length],
                  decorationThickness: 2,
                ),
              ),
      );
    }
    final settings = [
      for (final (name, w) in child.loras) '${name.split(RegExp(r'[/\\]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '')} ${w.toStringAsFixed(2)}',
      if (child.cfg != null) 'CFG ${cfgText(child.cfg!)}',
      if (child.steps != null) '${child.steps} steps',
      if (child.base > 0) 'on picture ${child.base + 1}\'s recipe',
    ].join(' · ');
    final stars = child.stars;
    return Opacity(
      opacity: faded ? 0.5 : 1,
      child: Material(
        color: ticked ? Palette.accent.withValues(alpha: 0.08) : Palette.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: ticked ? Palette.accent.withValues(alpha: 0.55) : Palette.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(value: ticked, onChanged: (_) => onTap(), visualDensity: VisualDensity.compact),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 6),
                      Text.rich(TextSpan(children: spans), style: const TextStyle(fontSize: 12.5, height: 1.5, color: Color(0xFFCFCFD6))),
                      if (aiming && steer != null && steer!.emphasize.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Weighted up: ${steer!.emphasize.map((e) => '${e.$1} ${e.$2}').join(', ')}',
                          style: const TextStyle(fontSize: 11.5, color: Palette.accent),
                        ),
                      ],
                      if (aiming && steer?.blocked == 'minor') ...[
                        const SizedBox(height: 4),
                        const Text('About a child or a teenager: not aimed higher', style: TextStyle(fontSize: 11.5, color: Palette.danger)),
                      ],
                      if (aiming && steer != null && steer!.addedNegative.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Negative + ${steer!.addedNegative.join(', ')}',
                          style: const TextStyle(fontSize: 11.5, color: Color(0xFF7BC88F)),
                        ),
                      ],
                      if (settings.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(settings, style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 84,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Icon(Icons.star_rounded, size: 15, color: stars == null ? Palette.faint : const Color(0xFFF2C14E)),
                          const SizedBox(width: 2),
                          Text(
                            stars == null ? '–' : stars.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Palette.text),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ScoreBar(stars == null ? 0 : (stars - 1) / 4, color: keepGreen),
                      const SizedBox(height: 3),
                      const Text('likely stars', style: TextStyle(fontSize: 11, color: Palette.faint)),
                      if (steer != null) ...[
                        const SizedBox(height: 8),
                        AudienceBadge(aiming ? steer!.to : steer!.from, key: const ValueKey<String>('breed-child-audience')),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
