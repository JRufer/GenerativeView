// Audience levels (G to NC-17) wherever they show: the badge on a tile, the
// filter section, the row in the info panel, and the target picker that
// Remix and Breed share. The core works the levels out (core/src/audience.rs).

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/audience.dart';
import '../core/models.dart';
import '../theme.dart';
import 'kit.dart';
import 'prompt_editor.dart' show PromptController;
import 'sheet.dart';

/// The colour a level is drawn in: calm to alarming.
Color audienceColor(int level) => switch (level) {
  Audience.g => const Color(0xFF7BC88F),
  Audience.pg => const Color(0xFFB4D17A),
  Audience.pg13 => const Color(0xFFE8C468),
  Audience.r => const Color(0xFFF0A35E),
  Audience.nc17 => Palette.danger,
  _ => Palette.faint,
};

/// A level as a small label: on a tile, in a list, beside a candidate.
class AudienceBadge extends StatelessWidget {
  const AudienceBadge(this.level, {super.key, this.onDark = false, this.large = false});
  final int level;

  /// Over a picture: a dark backing so it reads on anything.
  final bool onDark;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final color = audienceColor(level);
    return Tooltip(
      message: '${Audience.label(level)}: ${Audience.meaning(level)}',
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: large ? 8 : 5, vertical: large ? 3 : 1),
        decoration: BoxDecoration(
          color: onDark ? const Color(0xB3000000) : color.withValues(alpha: 0.14),
          border: Border.all(color: color.withValues(alpha: onDark ? 0.8 : 0.6)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          level == Audience.unknown ? '?' : Audience.label(level),
          style: TextStyle(fontSize: large ? 12.5 : 10.5, height: 1.25, fontWeight: FontWeight.w700, letterSpacing: 0.3, color: color),
        ),
      ),
    );
  }
}

/// One row of chips to pick a level: Any (0), then G to NC-17. [labelFor]
/// words each chip, for "up to" and "aim for" alike.
class AudienceChooser extends StatelessWidget {
  const AudienceChooser({
    super.key,
    required this.value,
    required this.onChanged,
    required this.keyPrefix,
    this.anyLabel = 'Any',
    this.inRange = false,
  });

  /// The chosen level; 0 for any.
  final int value;
  final ValueChanged<int> onChanged;
  final String keyPrefix;
  final String anyLabel;

  /// Light up every level up to the chosen one, for "up to" choices.
  final bool inRange;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        ChoiceChipButton(
          key: ValueKey<String>('$keyPrefix-any'),
          label: anyLabel,
          selected: value == 0,
          onTap: () => onChanged(0),
        ),
        for (final level in Audience.levels)
          ChoiceChipButton(
            key: ValueKey<String>('$keyPrefix-${Audience.word(level)}'),
            label: Audience.label(level),
            tooltip: Audience.meaning(level),
            selected: inRange ? value != 0 && level <= value : value == level,
            onTap: () => onChanged(level),
          ),
      ],
    );
  }
}

/// The audience part of the filter panel: show pictures up to a level,
/// whether to take in the not rated, what judges them, and the tile badges.
class AudienceFilterSection extends StatelessWidget {
  const AudienceFilterSection({
    super.key,
    required this.state,
    required this.max,
    required this.unrated,
    required this.onMax,
    required this.onUnrated,
  });
  final AppState state;
  final int max;
  final bool unrated;
  final ValueChanged<int> onMax;
  final VoidCallback onUnrated;

  @override
  Widget build(BuildContext context) {
    final source = state.audienceSource;
    Widget by(String value, String label, IconData icon, String tip) => ChoiceChipButton(
      key: ValueKey<String>('filter-audience-by-$value'),
      label: label,
      icon: icon,
      tooltip: tip,
      selected: source == value,
      onTap: () => state.setAudienceSource(value),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Show pictures rated up to', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
        const SizedBox(height: 6),
        AudienceChooser(value: max, keyPrefix: 'filter-audience', inRange: true, onChanged: onMax),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ChoiceChipButton(
              key: const ValueKey<String>('filter-audience-unrated'),
              label: max == 0 ? 'Only not rated yet' : 'Also not rated yet',
              icon: Icons.help_outline,
              tooltip: 'Pictures with no prompt to read and no picture score yet',
              selected: unrated,
              onTap: onUnrated,
            ),
            ChoiceChipButton(
              key: const ValueKey<String>('filter-audience-badges'),
              label: 'Badges on tiles',
              icon: Icons.label_outline,
              selected: state.audienceBadges,
              onTap: state.toggleAudienceBadges,
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('Rate by', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            by('image', 'What it shows', Icons.image_outlined, 'Content search looks at the picture itself'),
            by('prompt', 'Its prompt', Icons.notes, 'Read from the words it was made with: instant, but only as honest as the prompt'),
            by('both', 'Stricter of the two', Icons.shield_outlined, 'Whichever reading rates it higher'),
          ],
        ),
        const SizedBox(height: 6),
        PictureReadingStatus(state: state),
      ],
    );
  }
}

/// Where rating by what the pictures show stands for this folder: the model
/// to fetch, pictures still being looked at, or what each choice means.
class PictureReadingStatus extends StatelessWidget {
  const PictureReadingStatus({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    const note = TextStyle(fontSize: 11.5, color: Palette.faint, height: 1.4);
    return ValueListenableBuilder<ContentStatus>(
      valueListenable: state.content,
      builder: (context, status, _) => ValueListenableBuilder<DownloadProgress?>(
        valueListenable: state.download,
        builder: (context, progress, _) {
          final source = state.audienceSource;
          final unseen = status.total - status.embedded;
          final String text;
          Widget? action;
          if (source == 'prompt') {
            text = 'Instant, from what each picture was made with. Pictures with no prompt count as not rated.';
          } else if (progress != null) {
            final pct = progress.total > 0 ? (progress.received * 100 ~/ progress.total) : 0;
            text = 'Fetching the content search model: $pct%.';
          } else if (status.known && !status.installed) {
            text = source == 'image'
                ? 'Rating by what a picture shows needs the content search model (${status.downloadBytes ~/ 1000000} MB, once). Until then nothing is rated.'
                : 'Rating by what a picture shows needs the content search model (${status.downloadBytes ~/ 1000000} MB, once). Until then the prompt decides.';
            action = TextButton.icon(
              key: const ValueKey<String>('filter-audience-download'),
              onPressed: state.downloadModel,
              style: TextButton.styleFrom(minimumSize: const Size(0, 32), padding: const EdgeInsets.symmetric(horizontal: 8)),
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Get the model'),
            );
          } else if (status.indexing && status.todo > 0) {
            text = source == 'image'
                ? 'Looking at pictures: ${status.done} of ${status.todo}. The rest count as not rated until then.'
                : 'Looking at pictures: ${status.done} of ${status.todo}. The rest go by their prompt until then.';
          } else if (status.known && unseen > 0) {
            text = source == 'image'
                ? '$unseen not looked at yet count as not rated.'
                : '$unseen not looked at yet go by their prompt.';
          } else {
            text = source == 'image'
                ? 'From what content search sees in each picture, on this device.'
                : 'A picture is only as safe as the less forgiving reading: what it shows or what its prompt asks for.';
          }
          return Column(
            key: const ValueKey<String>('filter-audience-note'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(text, style: note),
              if (action != null) Align(alignment: Alignment.centerLeft, child: action),
            ],
          );
        },
      ),
    );
  }
}

/// The audience row in the info panel: the level, what it rests on, and a
/// way to set it by hand.
class AudienceRow extends StatefulWidget {
  const AudienceRow({super.key, required this.state, required this.item, required this.prompt});
  final AppState state;
  final MediaItem item;
  final String prompt;

  @override
  State<AudienceRow> createState() => _AudienceRowState();
}

class _AudienceRowState extends State<AudienceRow> {
  /// A reading: its level, then what set it, each in its level's colour.
  static Widget _reasons(int level, List<({String phrase, int level, String topic})> why, String none) {
    const value = TextStyle(fontSize: 12, color: Color(0xFFCFCFD6));
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        AudienceBadge(level),
        if (why.isEmpty)
          Text(level == Audience.unknown ? '' : none, style: value)
        else
          for (final r in why)
            Text('“${r.phrase}”${r.topic.isEmpty || r.topic == r.phrase ? '' : ' · ${r.topic}'}', style: value.copyWith(color: audienceColor(r.level))),
      ],
    );
  }

  AudienceInfo? _info;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    widget.state.notesTick.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(AudienceRow old) {
    super.didUpdateWidget(old);
    if (old.item.path != widget.item.path || old.prompt != widget.prompt) _load();
  }

  @override
  void dispose() {
    widget.state.notesTick.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final path = widget.item.path;
    try {
      final info = await widget.state.audienceInfo(widget.item, widget.prompt);
      if (mounted && widget.item.path == path) setState(() => _info = info);
    } catch (_) {}
  }

  Future<void> _setByHand(Offset at) async {
    final info = _info;
    final choice = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        for (final level in Audience.levels)
          PopupMenuItem(
            key: ValueKey<String>('audience-set-${Audience.word(level)}'),
            value: level,
            child: Row(
              children: [
                SizedBox(width: 52, child: Align(alignment: Alignment.centerLeft, child: AudienceBadge(level))),
                Text(Audience.meaning(level), style: const TextStyle(fontSize: 12.5, color: Palette.muted)),
              ],
            ),
          ),
        if (info?.own != null) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(key: ValueKey<String>('audience-set-auto'), value: 0, child: Text('Go back to the app\'s reading')),
        ],
      ],
    );
    if (choice != null) await widget.state.setAudience(widget.item, choice);
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) return const SizedBox.shrink();
    const label = TextStyle(fontSize: 12, color: Palette.muted);
    final reasons = info.promptReasons.where((r) => r.level >= Audience.pg).take(3).toList();
    Widget line(String name, Widget body, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 64, child: Text(name, style: label)),
          Expanded(child: body),
        ],
      ),
    );
    final bySource = switch (info.source) {
      'image' => 'by what it shows',
      'prompt' => 'by its prompt',
      _ => 'the stricter reading',
    };
    return Padding(
      key: const ValueKey<String>('audience-row'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey<String>('audience-toggle'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.shield_outlined, size: 14, color: Palette.faint),
                  const SizedBox(width: 6),
                  const Text('Audience', style: label),
                  const SizedBox(width: 8),
                  AudienceBadge(info.level),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      info.own != null ? 'set by you' : bySource,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: Palette.faint),
                    ),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: Palette.faint),
                ],
              ),
            ),
          ),
          if (_open)
            Container(
              key: const ValueKey<String>('audience-detail'),
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              decoration: BoxDecoration(color: Palette.raised, borderRadius: BorderRadius.circular(8), border: Border.all(color: Palette.line)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  line(
                    'Picture',
                    info.image != null
                        ? _reasons(info.image!, info.imageReasons.where((r) => r.level >= Audience.pg).take(3).toList(), 'Nothing that raises it')
                        : Text(
                            info.model ? 'Not looked at yet' : 'Needs the content search model',
                            style: const TextStyle(fontSize: 12, color: Palette.faint),
                          ),
                    key: const ValueKey<String>('audience-picture'),
                  ),
                  line(
                    'Prompt',
                    _reasons(info.prompt, reasons, info.prompt == Audience.unknown ? 'No prompt to read' : 'Nothing that raises it'),
                    key: const ValueKey<String>('audience-prompt'),
                  ),
                  line(
                    'Yours',
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Builder(
                        builder: (context) => TextButton.icon(
                          key: const ValueKey<String>('audience-set'),
                          style: TextButton.styleFrom(minimumSize: const Size(0, 30), padding: const EdgeInsets.symmetric(horizontal: 8)),
                          onPressed: () {
                            final box = context.findRenderObject() as RenderBox;
                            _setByHand(box.localToGlobal(Offset(0, box.size.height)));
                          },
                          icon: const Icon(Icons.edit_outlined, size: 15),
                          label: Text(info.own != null ? 'Set to ${Audience.label(info.own!)} · change' : 'Set it yourself'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// What steering a prompt changed: parts taken out (struck through) and
/// words added to or lifted from the negative prompt.
class AudienceSteerNote extends StatelessWidget {
  const AudienceSteerNote(this.steer, {super.key, this.target});
  final AudienceSteer steer;
  final int? target;

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(fontSize: 11.5, color: Palette.faint);
    const strike = TextStyle(fontSize: 12, color: Palette.danger, decoration: TextDecoration.lineThrough, decorationColor: Palette.danger);
    const added = TextStyle(fontSize: 12, color: Color(0xFF7BC88F));
    final rows = <Widget>[];
    void row(String name, List<String> items, TextStyle style) {
      if (items.isEmpty) return;
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$name  ', style: label),
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const TextSpan(text: ', ', style: label),
                TextSpan(text: items[i], style: style),
              ],
            ]),
          ),
        ),
      );
    }

    row('Taken out of the prompt', steer.removed, strike);
    row('Added to the negative', steer.addedNegative, added);
    row('Lifted from the negative', steer.liftedNegative, strike.copyWith(color: Palette.muted, decorationColor: Palette.muted));
    if (rows.isEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          target != null && steer.from <= target! ? 'Already within ${Audience.label(target!)}: nothing to change.' : 'Nothing to change.',
          style: label,
        ),
      ));
    }
    return Column(key: const ValueKey<String>('audience-steer-note'), crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

/// The audience section of Remix: what the prompt reads as now, a level to
/// aim for, and what aiming there changes. The prompt and negative prompt
/// are changed in place, from what they were when a target was first
/// picked, so picking another level or Any starts from the original again.
class RemixAudienceSection extends StatefulWidget {
  const RemixAudienceSection({super.key, required this.state, required this.prompt, required this.negative});
  final AppState state;
  final PromptController prompt;
  final PromptController negative;

  @override
  State<RemixAudienceSection> createState() => _RemixAudienceSectionState();
}

class _RemixAudienceSectionState extends State<RemixAudienceSection> {
  int _target = 0;
  int? _now;
  AudienceSteer? _steer;
  (String, String)? _original;

  @override
  void initState() {
    super.initState();
    _read();
  }

  /// What the prompt as written reads as.
  Future<void> _read() async {
    try {
      final s = await widget.state.steerAudience(widget.prompt.text, widget.negative.text, 0);
      if (mounted) setState(() => _now = s.from);
    } catch (_) {}
  }

  Future<void> _aim(int target) async {
    _original ??= (widget.prompt.text, widget.negative.text);
    final (prompt, negative) = _original!;
    if (target == 0) {
      _set(widget.prompt, prompt);
      _set(widget.negative, negative);
      setState(() {
        _target = 0;
        _steer = null;
        _original = null;
      });
      return;
    }
    try {
      final s = await widget.state.steerAudience(prompt, negative, target);
      if (!mounted) return;
      _set(widget.prompt, s.prompt);
      _set(widget.negative, s.negative);
      setState(() {
        _target = target;
        _steer = s;
      });
    } catch (_) {}
  }

  static void _set(TextEditingController c, String text) {
    if (c.text != text) c.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final steer = _steer;
    final summary = [
      if (now != null) 'reads as ${Audience.label(now)}',
      if (_target != 0) 'aiming for ${Audience.label(_target)}',
      if (steer != null && steer.removed.isNotEmpty) '${steer.removed.length} taken out',
    ].join(' · ');
    return FoldSection(
      key: const ValueKey<String>('remix-audience'),
      toggleKey: const ValueKey<String>('remix-audience-toggle'),
      summaryKey: const ValueKey<String>('remix-audience-summary'),
      label: 'Audience',
      summary: summary,
      highlight: _target != 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 2),
          const Text('Aim the result at', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
          const SizedBox(height: 6),
          AudienceChooser(value: _target, keyPrefix: 'remix-audience', anyLabel: 'As written', onChanged: _aim),
          if (steer != null) AudienceSteerNote(steer, target: _target),
          const SizedBox(height: 6),
          const Text(
            'Going down takes the parts that rate higher out of the prompt and guards against them in the negative. Going up only lifts those guards; it never adds content.',
            style: TextStyle(fontSize: 11.5, color: Palette.faint, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// The audience heading and picker of Breed, which aims every candidate.
class BreedAudienceSection extends StatelessWidget {
  const BreedAudienceSection({super.key, required this.target, required this.onChanged});
  final int target;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelHeading('Audience'),
        AudienceChooser(value: target, keyPrefix: 'breed-audience', anyLabel: 'As bred', onChanged: onChanged),
        const SizedBox(height: 6),
        Text(
          target == 0
              ? 'Pick a level and every candidate is aimed at it: parts that rate higher are struck out and guarded against.'
              : 'Every candidate is aimed at ${Audience.label(target)}. Struck-out parts are left out when it is rendered.',
          style: const TextStyle(fontSize: 11.5, color: Palette.faint, height: 1.4),
        ),
      ],
    );
  }
}
