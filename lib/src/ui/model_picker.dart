import 'package:flutter/material.dart';

import '../core/server_loras.dart';
import '../theme.dart';
import 'sheet.dart';

/// What was picked in the model picker: a model of the server's, or (null)
/// the picture's own.
class ModelPick {
  const ModelPick(this.model);
  final ServerModel? model;
}

/// Pick the model to render with from the server's [models], listed in
/// groups by kind (Krea 2, SDXL, FLUX.1…), with chips to show one kind
/// alone. A sheet on a narrow screen, a dialog on a wide one; null if
/// closed without picking.
///
/// [current] is the name of the one chosen now. [own], when given, is a
/// first row for going back to the picture's own model. [types] are the
/// kinds the user has set by hand, by [ServerModel.key]; [onSetType] saves
/// one (null to take it back), and without it kinds cannot be set here.
Future<ModelPick?> pickModel(
  BuildContext context, {
  required List<ServerModel> models,
  String? current,
  String? own,
  Map<String, String> types = const {},
  void Function(String key, String? family)? onSetType,
}) =>
    showPanel<ModelPick>(
      context,
      title: 'Choose a model',
      icon: Icons.category_outlined,
      width: 560,
      builder: (context) => ModelPicker(models: models, current: current, own: own, types: types, onSetType: onSetType),
    );

/// The name of a model's file alone: no folder, hash or extension.
String modelStem(String name) => name
    .replaceFirst(RegExp(r'\s*\[[0-9a-fA-F]+\]$'), '')
    .split(RegExp(r'[/\\]'))
    .last
    .replaceFirst(RegExp(r'\.(safetensors|ckpt|pt|pth|bin|gguf|sft)$', caseSensitive: false), '');

/// The folder a model is in on the server, if any.
String modelFolder(String name) {
  final parts = name.split(RegExp(r'[/\\]'));
  return parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
}

/// A small label naming a kind of model, as shown beside a model's name.
class FamilyTag extends StatelessWidget {
  const FamilyTag(this.family, {super.key});

  /// Null for a model whose kind cannot be told.
  final String? family;

  @override
  Widget build(BuildContext context) {
    final known = family != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: known ? Palette.accent.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: known ? Palette.accent.withValues(alpha: 0.5) : Palette.line),
      ),
      child: Text(
        known ? familyLabel(family!) : 'Type not known',
        style: TextStyle(fontSize: 11, color: known ? Palette.text : Palette.muted),
      ),
    );
  }
}

/// A menu for saying which kind of model a file is, for one that does not
/// say itself: every known kind, and a way to take a kind set by hand back.
class SetTypeButton extends StatelessWidget {
  const SetTypeButton({super.key, required this.set, required this.onSet});

  /// The kind set by hand now, if any.
  final String? set;
  final ValueChanged<String?> onSet;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: set == null ? 'Say which kind of model this is' : 'Change the kind you set',
      position: PopupMenuPosition.under,
      onSelected: (value) => onSet(value.isEmpty ? null : value),
      itemBuilder: (context) => [
        for (final f in knownFamilies)
          PopupMenuItem<String>(
            value: f,
            height: 38,
            child: Row(
              children: [
                SizedBox(width: 24, child: f == set ? const Icon(Icons.check, size: 16, color: Palette.accent) : null),
                Text(familyLabel(f)),
              ],
            ),
          ),
        if (set != null) ...[
          const PopupMenuDivider(height: 8),
          const PopupMenuItem<String>(
            value: '',
            height: 38,
            child: Row(children: [SizedBox(width: 24), Text('Not set')]),
          ),
        ],
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(set == null ? 'Set type' : 'Change', style: const TextStyle(fontSize: 12, color: Palette.accent)),
            const Icon(Icons.arrow_drop_down, size: 16, color: Palette.accent),
          ],
        ),
      ),
    );
  }
}

class ModelPicker extends StatefulWidget {
  const ModelPicker({super.key, required this.models, this.current, this.own, this.types = const {}, this.onSetType});
  final List<ServerModel> models;
  final String? current;
  final String? own;
  final Map<String, String> types;
  final void Function(String key, String? family)? onSetType;

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

/// The chip for the models whose kind cannot be told.
const String _unknown = '?';

class _ModelPickerState extends State<ModelPicker> {
  final TextEditingController _search = TextEditingController();

  /// The kinds set by hand, as they stand while the picker is open.
  late Map<String, String> _types = {...widget.types};

  /// The one kind shown: a family, [_unknown], or null for all of them.
  String? _only;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(ServerModel m) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    final name = m.name.toLowerCase();
    return q.split(RegExp(r'\s+')).every(name.contains);
  }

  void _setType(ServerModel m, String? family) {
    setState(() {
      if (family == null) {
        _types.remove(m.key);
      } else {
        _types[m.key] = family;
      }
    });
    widget.onSetType?.call(m.key, family);
  }

  @override
  Widget build(BuildContext context) {
    // What the files and the server say, then what was set by hand over it.
    final all = withModelTypes(widget.models, _types);
    final groups = groupByFamily(all);
    final only = groups.any((g) => (g.family ?? _unknown) == _only) ? _only : null;
    final shown = [
      for (final g in groups)
        if (only == null || (g.family ?? _unknown) == only) (family: g.family, models: g.models.where(_matches).toList()),
    ].where((g) => g.models.isNotEmpty).toList();
    final unknown = all.where((m) => m.family == null).length;
    final String note;
    if (all.isEmpty) {
      note = 'The server has no models installed.';
    } else {
      final kinds = groups.where((g) => g.family != null).length;
      note = '${all.length} ${all.length == 1 ? 'model' : 'models'} of $kinds ${kinds == 1 ? 'kind' : 'kinds'}'
          '${unknown > 0 ? ' · $unknown whose kind the server and the file do not say' : ''}';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: Text(note, key: const ValueKey<String>('model-picker-note'), style: const TextStyle(fontSize: 12, color: Palette.muted, height: 1.35)),
        ),
        if (all.length > 6)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const ValueKey<String>('model-picker-search'),
              controller: _search,
              autofocus: MediaQuery.sizeOf(context).shortestSide >= 600,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search models',
              ),
            ),
          ),
        if (groups.length > 1)
          SizedBox(
            height: 40,
            child: ListView(
              key: const ValueKey<String>('model-picker-kinds'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              children: [
                ChoiceChipButton(
                  key: const ValueKey<String>('model-kind-all'),
                  label: 'All',
                  count: all.length,
                  selected: only == null,
                  onTap: () => setState(() => _only = null),
                ),
                for (final g in groups) ...[
                  const SizedBox(width: 6),
                  ChoiceChipButton(
                    key: ValueKey<String>('model-kind-${g.family ?? 'unknown'}'),
                    label: g.family == null ? 'Type not known' : familyLabel(g.family!),
                    count: g.models.length,
                    selected: only == (g.family ?? _unknown),
                    onTap: () => setState(() => _only = g.family ?? _unknown),
                  ),
                ],
              ],
            ),
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            children: [
              if (widget.own != null && _search.text.trim().isEmpty && only == null)
                ListTile(
                  key: const ValueKey<String>('model-picker-own'),
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  leading: Icon(
                    widget.current == null ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 18,
                    color: widget.current == null ? Palette.accent : Palette.muted,
                  ),
                  title: Text('The picture\'s: ${widget.own}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                  subtitle: const Text('Sent as the picture had it, with its own workflow', style: TextStyle(fontSize: 11.5, color: Palette.faint)),
                  onTap: () => Navigator.of(context).pop(const ModelPick(null)),
                ),
              for (final g in shown) ...[
                _heading(g.family, g.models.length),
                for (final m in g.models) _row(m),
              ],
              if (shown.isEmpty && all.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(10, 10, 10, 12),
                  child: Text('None of them match the search.', style: TextStyle(fontSize: 12.5, color: Palette.faint)),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _heading(String? family, int count) => Padding(
        key: ValueKey<String>('model-group-${family ?? 'unknown'}'),
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 4),
        child: Row(
          children: [
            Text(
              (family == null ? 'Type not known' : familyLabel(family)).toUpperCase(),
              style: const TextStyle(fontSize: 10.5, letterSpacing: 0.9, fontWeight: FontWeight.w600, color: Palette.faint),
            ),
            const SizedBox(width: 8),
            Text('$count', style: const TextStyle(fontSize: 11, color: Palette.faint)),
            const SizedBox(width: 10),
            const Expanded(child: Divider(height: 1, color: Palette.line)),
          ],
        ),
      );

  Widget _row(ServerModel m) {
    final chosen = widget.current == m.name;
    final byHand = _types[m.key];
    final folder = modelFolder(m.name);
    final sub = [
      if (folder.isNotEmpty) folder,
      if (byHand != null) 'type set by you',
    ].join(' · ');
    final canSet = widget.onSetType != null && (m.family == null || byHand != null);
    return ListTile(
      key: ValueKey<String>('model-picker-${m.key}'),
      dense: true,
      contentPadding: const EdgeInsets.only(left: 10, right: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      leading: Icon(
        chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 18,
        color: chosen ? Palette.accent : Palette.muted,
      ),
      title: Text(modelStem(m.name), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
      subtitle: sub.isEmpty ? null : Text(sub, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
      trailing: canSet
          ? SetTypeButton(key: ValueKey<String>('model-type-${m.key}'), set: byHand, onSet: (f) => _setType(m, f))
          : null,
      onTap: () => Navigator.of(context).pop(ModelPick(m)),
    );
  }
}
