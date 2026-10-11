import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'context_menu.dart';

/// Say something briefly at the foot of the window.
void toast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1100),
        width: 260,
      ),
    );
}

/// Copy [text] and say so briefly.
void copyText(BuildContext context, String text, String what) {
  Clipboard.setData(ClipboardData(text: text));
  toast(context, 'Copied $what');
}

/// The search field a setting can be filtered by exactly, if it has one.
String? _settingField(String name) => switch (name.toLowerCase()) {
  'steps' => 'steps',
  'cfg' || 'cfg scale' => 'cfg',
  'sampler' => 'sampler',
  'scheduler' => 'scheduler',
  _ => null,
};

/// From this width a panel that is wider than it is tall lays its sections
/// out in two columns.
const double _twoColumnWidth = 640;

/// How the selected image was made. Every value is a tap target that copies
/// itself; a right click or a press-and-hold on the seed, a model, a LoRA or
/// a sampler setting offers to show only the images that share it. Sits
/// beside the content, or under it in a portrait window.
class MetaPanel extends StatefulWidget {
  const MetaPanel({super.key, required this.state});
  final AppState state;

  @override
  State<MetaPanel> createState() => _MetaPanelState();
}

class _MetaPanelState extends State<MetaPanel> {
  final ScrollController _scroll = ScrollController();
  GenInfo? _info;
  String? _shownVersion;
  String? _wantedVersion;
  Object? _error;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    widget.state.removeListener(_sync);
    _scroll.dispose();
    super.dispose();
  }

  void _sync() {
    final item = widget.state.selected;
    final version = item == null
        ? null
        : '${item.path}/${item.mtime}/${item.size}';
    if (version == _wantedVersion) return;
    _wantedVersion = version;
    if (item == null) {
      if (mounted) {
        setState(() {
          _info = null;
          _shownVersion = null;
          _error = null;
        });
      }
      return;
    }
    widget.state
        .metadata(item)
        .then(
          (info) {
            if (!mounted || _wantedVersion != version) return;
            setState(() {
              _info = info;
              _shownVersion = version;
              _error = null;
            });
          },
          onError: (Object e) {
            if (!mounted || _wantedVersion != version) return;
            setState(() {
              _info = null;
              _shownVersion = version;
              _error = e;
            });
          },
        );
  }

  /// Offer to narrow the grid to the images that match [query].
  Future<void> _offerFilter(Offset position, String label, String query) async {
    final choice = await showContextMenu<bool>(context, position, [
      MenuEntry(true, label, Icons.filter_alt_outlined),
    ]);
    if (choice == true) widget.state.applyFilter(query);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.state.selected;
    final info = _info;
    if (item == null) {
      return const _PanelMessage('Select an image to see how it was made.');
    }
    if (_error != null) {
      return _PanelMessage('Could not read this file.\n$_error');
    }
    if (info == null || _shownVersion == null) {
      return const SizedBox.expand();
    }
    // What it is and what was asked for …
    final lead = <Widget>[
      _FileHeader(item: item, info: info),
      if (!info.hasGeneration)
        const Text(
          'No generation data found in this file.',
          style: TextStyle(color: Palette.muted, fontSize: 13),
        ),
      if (info.prompt.isNotEmpty)
        _Section(
          label: 'Prompt',
          child: _CopyBlock(
            text: info.prompt,
            what: 'prompt',
            semanticsLabel: 'Prompt',
          ),
        ),
      if (info.negative.isNotEmpty)
        _Section(
          label: 'Negative prompt',
          child: _CopyBlock(
            text: info.negative,
            what: 'negative prompt',
            semanticsLabel: 'Negative prompt',
          ),
        ),
    ];
    // … and what it was made with.
    final rest = <Widget>[
      if (info.seed.isNotEmpty || info.model.isNotEmpty)
        _Section(
          label: 'Generation',
          child: Column(
            children: [
              if (info.seed.isNotEmpty)
                _Field(
                  name: 'Seed',
                  value: info.seed,
                  mono: true,
                  onMenu: (at) => _offerFilter(
                    at,
                    'Show only images with this seed',
                    exactTerm('seed', info.seed),
                  ),
                ),
              if (info.model.isNotEmpty)
                _Field(
                  name: 'Model',
                  value: info.model,
                  onMenu: (at) => _offerFilter(
                    at,
                    'Show only images made with this model',
                    exactTerm('model', info.model),
                  ),
                ),
            ],
          ),
        ),
      if (info.loras.isNotEmpty)
        _Section(
          label: 'LoRAs',
          // Every LoRA listed here, at whatever strength.
          onMenu: (at) => _offerFilter(
            at,
            info.loras.length == 1
                ? 'Show only images using this LoRA'
                : 'Show only images using all ${info.loras.length} of these LoRAs',
            info.loras.map((l) => exactTerm('lora', l.name)).join(' '),
          ),
          action: _SectionAction(
            label: 'Copy as tags',
            onTap: () => copyText(
              context,
              info.loras.map((l) => l.tag).join(' '),
              'LoRA tags',
            ),
          ),
          child: Column(
            children: [
              for (final l in info.loras)
                _Field(
                  name: l.name,
                  value: l.weight == null
                      ? ''
                      : (l.weightClip != null && l.weightClip != l.weight
                            ? '${formatNumber(l.weight!)} / ${formatNumber(l.weightClip!)}'
                            : formatNumber(l.weight!)),
                  copyValue: l.name,
                  what: 'LoRA name',
                  nameIsValue: true,
                  onMenu: (at) => _offerFilter(
                    at,
                    'Show only images using this LoRA',
                    exactTerm('lora', l.name),
                  ),
                ),
            ],
          ),
        ),
      if (info.models.any((m) => m.name != info.model))
        _Section(
          label: 'Other models',
          child: Column(
            children: [
              for (final m in info.models)
                if (m.name != info.model)
                  _Field(
                    name: GenInfo.kindLabel(m.kind),
                    value: m.name,
                    onMenu: (at) => _offerFilter(
                      at,
                      'Show only images made with this model',
                      exactTerm('model', m.name),
                    ),
                  ),
            ],
          ),
        ),
      if (info.params.isNotEmpty)
        _Section(
          label: 'Settings',
          child: Column(
            children: [
              for (final p in info.params)
                _Field(
                  name: p.key,
                  value: p.value,
                  onMenu: switch (_settingField(p.key)) {
                    final field? => (at) => _offerFilter(
                      at,
                      'Show only images with this setting',
                      exactTerm(field, p.value),
                    ),
                    null => null,
                  },
                ),
            ],
          ),
        ),
      if (info.nodes.isNotEmpty) _WorkflowSection(nodes: info.nodes),
      if (info.raw.isNotEmpty)
        _Section(
          label: 'Raw metadata',
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final r in info.raw)
                _Chip(
                  label: '${r.key} · ${formatBytes(r.value.length)}',
                  tooltip: 'Copy ${r.key} exactly as stored in the file',
                  onTap: () => copyText(context, r.value, r.key),
                ),
            ],
          ),
        ),
    ];

    return ExcludeFocus(
      child: LayoutBuilder(
        builder: (context, box) {
          // Short and wide — the footer of a portrait window — reads better
          // as two columns than as one long scroll.
          final sideBySide =
              rest.isNotEmpty &&
              box.maxWidth >= _twoColumnWidth &&
              box.maxWidth > box.maxHeight;
          return Scrollbar(
            controller: _scroll,
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
              children: sideBySide
                  ? [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _stack(lead)),
                          const SizedBox(width: 24),
                          Expanded(child: _stack(rest)),
                        ],
                      ),
                    ]
                  : _spaced([...lead, ...rest]),
            ),
          );
        },
      ),
    );
  }

  static Widget _stack(List<Widget> sections) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _spaced(sections),
    );
  }

  static List<Widget> _spaced(List<Widget> sections) {
    return [
      for (final (i, section) in sections.indexed) ...[
        if (i > 0) const SizedBox(height: 18),
        section,
      ],
    ];
  }
}

class _PanelMessage extends StatelessWidget {
  const _PanelMessage(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Palette.muted,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class _FileHeader extends StatelessWidget {
  const _FileHeader({required this.item, required this.info});
  final MediaItem item;
  final GenInfo info;

  @override
  Widget build(BuildContext context) {
    final w = info.width > 0 ? info.width : item.width;
    final h = info.height > 0 ? info.height : item.height;
    final facts = [
      if (w > 0 && h > 0) '$w × $h',
      if (item.durationMs > 0) formatDuration(item.durationMs),
      formatBytes(item.size),
      formatDate(item.mtime),
    ].join('  ·  ');
    final source = GenInfo.sourceLabel(info.source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Tappable(
          onTap: () => copyText(context, item.name, 'file name'),
          child: Text(
            item.name,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Palette.text,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(height: 2),
        _Tappable(
          onTap: () => copyText(context, item.path, 'file path'),
          child: Text(
            item.dir,
            style: const TextStyle(
              fontSize: 11.5,
              color: Palette.faint,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(facts, style: const TextStyle(fontSize: 12, color: Palette.muted)),
        const SizedBox(height: 10),
        Row(
          children: [
            if (source.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Palette.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  source,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Palette.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const Spacer(),
            if (info.hasGeneration)
              _Chip(
                label: 'Copy all',
                tooltip: 'Copy every field as text',
                onTap: () =>
                    copyText(context, info.summary(), 'all generation data'),
              ),
          ],
        ),
      ],
    );
  }
}

class _SectionAction {
  const _SectionAction({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
}

class _Section extends StatelessWidget {
  const _Section({
    required this.label,
    required this.child,
    this.action,
    this.onMenu,
  });
  final String label;
  final Widget child;
  final _SectionAction? action;

  /// Called with where the pointer was when the heading is right-clicked or
  /// pressed and held.
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) {
    final menu = onMenu;
    final heading = Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 10.5,
        letterSpacing: 0.9,
        fontWeight: FontWeight.w600,
        color: Palette.faint,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: menu == null
                  ? heading
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onSecondaryTapUp: (d) => menu(d.globalPosition),
                      onLongPressStart: (d) => menu(d.globalPosition),
                      // Tall enough to press with a finger.
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: heading,
                      ),
                    ),
            ),
            if (action != null)
              _Tappable(
                onTap: action!.onTap,
                child: Text(
                  action!.label,
                  style: const TextStyle(fontSize: 11.5, color: Palette.accent),
                ),
              ),
          ],
        ),
        SizedBox(height: menu == null ? 6 : 2),
        child,
      ],
    );
  }
}

/// Hover/press feedback without Material ink's height requirements.
class _Tappable extends StatelessWidget {
  const _Tappable({
    required this.onTap,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.onMenu,
  });
  final VoidCallback onTap;
  final Widget child;
  final EdgeInsets padding;

  /// Called with where the pointer was on a right click or a long press.
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) {
    final menu = onMenu;
    final ink = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      hoverColor: Palette.hover,
      child: Padding(padding: padding, child: child),
    );
    return Material(
      type: MaterialType.transparency,
      child: menu == null
          ? ink
          : GestureDetector(
              onSecondaryTapUp: (d) => menu(d.globalPosition),
              onLongPressStart: (d) => menu(d.globalPosition),
              child: ink,
            ),
    );
  }
}

/// A block of text that copies itself when tapped.
class _CopyBlock extends StatelessWidget {
  const _CopyBlock({
    required this.text,
    required this.what,
    required this.semanticsLabel,
  });
  final String text;
  final String what;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$semanticsLabel, tap to copy',
      button: true,
      child: Material(
        color: Palette.raised,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: () => copyText(context, text, what),
          borderRadius: BorderRadius.circular(6),
          hoverColor: Palette.hover,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: Palette.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A name/value row; tapping copies the value.
class _Field extends StatelessWidget {
  const _Field({
    required this.name,
    required this.value,
    this.copyValue,
    this.what,
    this.mono = false,
    this.nameIsValue = false,
    this.onMenu,
  });

  final String name;
  final String value;
  final String? copyValue;
  final String? what;

  /// Called with where the pointer was on a right click or a long press.
  final ValueChanged<Offset>? onMenu;

  /// Fixed-width digits, for long numbers.
  final bool mono;

  /// For rows like LoRAs where the left side is the thing worth copying.
  final bool nameIsValue;

  @override
  Widget build(BuildContext context) {
    final nameStyle = TextStyle(
      fontSize: 12.5,
      height: 1.35,
      color: nameIsValue ? Palette.text : Palette.muted,
    );
    final valueStyle = TextStyle(
      fontSize: 12.5,
      height: 1.35,
      color: nameIsValue ? Palette.muted : Palette.text,
      fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
    );
    return _Tappable(
      onTap: () =>
          copyText(context, copyValue ?? value, what ?? name.toLowerCase()),
      onMenu: onMenu,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (nameIsValue)
            Expanded(child: Text(name, style: nameStyle))
          else
            SizedBox(width: 104, child: Text(name, style: nameStyle)),
          const SizedBox(width: 8),
          if (nameIsValue)
            Text(value, style: valueStyle)
          else
            Expanded(child: Text(value, style: valueStyle)),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap, this.tooltip});
  final String label;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Material(
      color: Palette.raised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(5),
        side: const BorderSide(color: Palette.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: Palette.hover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Palette.text),
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// The whole ComfyUI graph, one collapsible entry per node.
class _WorkflowSection extends StatefulWidget {
  const _WorkflowSection({required this.nodes});
  final List<GraphNode> nodes;

  @override
  State<_WorkflowSection> createState() => _WorkflowSectionState();
}

class _WorkflowSectionState extends State<_WorkflowSection> {
  bool _open = false;
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final nodes = widget.nodes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Tappable(
          onTap: () => setState(() => _open = !_open),
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'WORKFLOW  ·  ${nodes.length} NODES',
                  style: const TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 0.9,
                    fontWeight: FontWeight.w600,
                    color: Palette.faint,
                  ),
                ),
              ),
              Icon(
                _open ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: Palette.faint,
              ),
            ],
          ),
        ),
        if (_open)
          for (final node in nodes) ...[
            const SizedBox(height: 4),
            _Tappable(
              onTap: () => setState(() {
                if (!_expanded.remove(node.id)) _expanded.add(node.id);
              }),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Row(
                children: [
                  Icon(
                    _expanded.contains(node.id)
                        ? Icons.arrow_drop_down
                        : Icons.arrow_right,
                    size: 18,
                    color: Palette.faint,
                  ),
                  Expanded(
                    child: Text(
                      node.title.isEmpty ? node.type : node.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Palette.text,
                      ),
                    ),
                  ),
                  Text(
                    node.title == node.type || node.title.isEmpty
                        ? '#${node.id}'
                        : '${node.type}  #${node.id}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Palette.faint,
                    ),
                  ),
                ],
              ),
            ),
            if (_expanded.contains(node.id))
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: Column(
                  children: [
                    for (final input in node.inputs)
                      _Field(name: input.key, value: input.value),
                  ],
                ),
              ),
          ],
      ],
    );
  }
}
