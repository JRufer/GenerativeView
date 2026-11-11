import 'package:flutter/material.dart';

import '../core/recipe_graphs.dart' show modelKey;
import '../core/server_loras.dart';
import '../theme.dart';
import 'model_picker.dart' show SetTypeButton;
import 'sheet.dart';

/// Pick a LoRA on the server to add to a remix, from those made for the
/// same kind of model as [model]. A sheet on a narrow screen, a dialog on a
/// wide one; null if closed without picking.
///
/// [family] is the kind of model the remix renders with, null when it could
/// not be told: then every LoRA is listed, with a line saying so. LoRAs
/// whose own kind cannot be told are kept behind a switch.
Future<ServerModel?> pickLora(
  BuildContext context, {
  required Future<List<ServerModel>> loras,
  required String? family,
  required String model,
  required Set<String> have,
  Map<String, String> types = const {},
  void Function(String key, String? family)? onSetType,
}) =>
    showPanel<ServerModel>(
      context,
      title: 'Add a LoRA',
      icon: Icons.add_circle_outline,
      width: 520,
      builder: (context) => LoraPicker(loras: loras, family: family, model: model, have: have, types: types, onSetType: onSetType),
    );

class LoraPicker extends StatefulWidget {
  const LoraPicker({
    super.key,
    required this.loras,
    required this.family,
    required this.model,
    this.have = const {},
    this.types = const {},
    this.onSetType,
  });

  /// The server's LoRAs, still being asked for perhaps.
  final Future<List<ServerModel>> loras;
  final String? family;

  /// The model's name, to say what they are listed for.
  final String model;

  /// Keys ([modelKey]) of the LoRAs the remix already has.
  final Set<String> have;

  /// The kinds of model the user has said LoRAs are for, by key, for files
  /// that do not say; [onSetType] saves one (null takes it back).
  final Map<String, String> types;
  final void Function(String key, String? family)? onSetType;

  @override
  State<LoraPicker> createState() => _LoraPickerState();
}

class _LoraPickerState extends State<LoraPicker> {
  final TextEditingController _search = TextEditingController();
  bool _showUnknown = false;

  /// The kinds set by hand, as they stand while the picker is open.
  late final Map<String, String> _types = {...widget.types};

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
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static String _stem(String name) => name
      .replaceFirst(RegExp(r'\s*\[[0-9a-fA-F]+\]$'), '')
      .split(RegExp(r'[/\\]'))
      .last
      .replaceFirst(RegExp(r'\.(safetensors|ckpt|pt|pth|bin|gguf|sft)$', caseSensitive: false), '');

  /// The folder a LoRA is in on the server, if any.
  static String _folder(String name) {
    final parts = name.split(RegExp(r'[/\\]'));
    return parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
  }

  bool _matches(ServerModel m) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    final name = m.name.toLowerCase();
    return q.split(RegExp(r'\s+')).every(name.contains);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ServerModel>>(
      future: widget.loras,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
            child: Text(
              'Could not list the server\'s LoRAs: ${snap.error}',
              key: const ValueKey<String>('lora-picker-error'),
              style: const TextStyle(fontSize: 13, color: Palette.danger, height: 1.35),
            ),
          );
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
                SizedBox(height: 12),
                Text('Asking the server which LoRAs it has…', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
              ],
            ),
          );
        }
        return _list(snap.data!);
      },
    );
  }

  Widget _list(List<ServerModel> listed) {
    final all = withModelTypes(listed, _types);
    final family = widget.family;
    final sorted = sortLoras(all, family);
    final fitting = sorted.fitting.where(_matches).toList();
    final unknown = sorted.unknown.where(_matches).toList();
    final showUnknown = family == null || _showUnknown;
    final model = modelKey(widget.model).isEmpty ? 'this model' : _stem(widget.model);
    final String note;
    if (all.isEmpty) {
      note = 'The server has no LoRAs installed.';
    } else if (family == null) {
      note = 'Could not tell what kind of model $model is, so all ${all.length} are listed. Some may not work with it.';
    } else {
      final n = sorted.fitting.length;
      note = '$n made for ${familyLabel(family)}, like $model'
          '${sorted.other > 0 ? ' · ${sorted.other} for other kinds hidden' : ''}';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: Text(note, key: const ValueKey<String>('lora-picker-note'), style: const TextStyle(fontSize: 12, color: Palette.muted, height: 1.35)),
        ),
        if (all.length > 6)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: TextField(
              key: const ValueKey<String>('lora-picker-search'),
              controller: _search,
              autofocus: MediaQuery.sizeOf(context).shortestSide >= 600,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search LoRAs',
              ),
            ),
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            children: [
              for (final m in fitting) _row(m),
              if (family != null && fitting.isEmpty && sorted.fitting.isNotEmpty)
                const _Empty('None of them match the search.'),
              if (family != null && sorted.fitting.isEmpty && all.isNotEmpty)
                _Empty('None of the server\'s LoRAs are marked as made for ${familyLabel(family)}.'),
              if (family != null && sorted.unknown.isNotEmpty)
                SwitchListTile(
                  key: const ValueKey<String>('lora-picker-unknown'),
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  value: _showUnknown,
                  onChanged: (v) => setState(() => _showUnknown = v),
                  title: Text(
                    'Also show ${sorted.unknown.length} that can\'t be checked',
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: const Text(
                    'Their files don\'t say which kind of model they are for.',
                    style: TextStyle(fontSize: 11.5, color: Palette.faint),
                  ),
                ),
              if (showUnknown) for (final m in unknown) _row(m, unchecked: family != null),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(ServerModel m, {bool unchecked = false}) {
    final have = widget.have.contains(m.key);
    final folder = _folder(m.name);
    final byHand = _types[m.key];
    final sub = [
      if (folder.isNotEmpty) folder,
      if (unchecked) 'not checked',
      if (byHand != null) 'type set by you',
      if (have) 'already added',
    ].join(' · ');
    final canSet = widget.onSetType != null && (m.family == null || byHand != null);
    return ListTile(
      key: ValueKey<String>('lora-picker-${m.key}'),
      dense: true,
      enabled: !have,
      contentPadding: EdgeInsets.only(left: 10, right: canSet ? 2 : 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      leading: Icon(have ? Icons.check : Icons.add, size: 18, color: have ? Palette.accent : Palette.muted),
      title: Text(_stem(m.name), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
      subtitle: sub.isEmpty ? null : Text(sub, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
      trailing: canSet
          ? SetTypeButton(key: ValueKey<String>('lora-type-${m.key}'), set: byHand, onSet: (f) => _setType(m, f))
          : (m.family == null || widget.family == m.family
              ? null
              : Text(familyLabel(m.family!), style: const TextStyle(fontSize: 11.5, color: Palette.faint))),
      onTap: have ? null : () => Navigator.of(context).pop(m),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        child: Text(text, style: const TextStyle(fontSize: 12.5, color: Palette.faint)),
      );
}
