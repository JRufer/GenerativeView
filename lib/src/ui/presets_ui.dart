import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../core/backends.dart' show recipeCfg, recipeSteps;
import '../core/models.dart';
import '../core/presets.dart';
import '../platform.dart' show canShareFiles, shareFiles;
import '../theme.dart';
import 'meta_panel.dart' show toast;
import 'sheet.dart';

/// What a preset of [info] could carry, for the Save panel to pick from.
Preset presetOf(GenInfo info) => Preset(
  id: '',
  name: '',
  prompt: info.prompt,
  negative: info.negative,
  loras: [for (final l in info.loras) PresetLora(l.name, l.weight ?? 1.0)],
  steps: recipeSteps(info),
  cfg: recipeCfg(info),
  width: info.width > 0 ? info.width : null,
  height: info.height > 0 ? info.height : null,
);

/// The preset chips of Remix and Breed. Tap one to apply it; its cross takes
/// it off again.
class PresetStrip extends StatelessWidget {
  const PresetStrip({super.key, required this.state, required this.active, required this.onApply, required this.onClear, this.onSave});
  final AppState state;
  final Preset? active;
  final ValueChanged<Preset> onApply;
  final VoidCallback onClear;

  /// Save what is in the panel; null to not offer it.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Column(
        key: const ValueKey<String>('preset-strip'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Presets', style: TextStyle(fontSize: 12, color: Palette.muted))),
              if (onSave != null)
                TextButton(
                  key: const ValueKey<String>('preset-save'),
                  onPressed: onSave,
                  child: const Text('Save as preset…'),
                ),
            ],
          ),
          if (state.presets.isEmpty)
            const Text('No presets yet.', style: TextStyle(fontSize: 12, color: Palette.faint))
          else
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final preset in state.presets)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Center(
                        child: active?.id == preset.id
                            ? InputChip(
                                key: ValueKey<String>('preset-chip-${preset.name}'),
                                selected: true,
                                label: Text(preset.name),
                                onDeleted: onClear,
                                deleteButtonTooltipMessage: 'Take off ${preset.name}',
                                onPressed: onClear,
                              )
                            : ActionChip(
                                key: ValueKey<String>('preset-chip-${preset.name}'),
                                label: Text(preset.name),
                                tooltip: preset.parts.join(', '),
                                onPressed: () => onApply(preset),
                              ),
                      ),
                    ),
                ],
              ),
            ),
          if (active != null && active!.loras.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'A LoRA the server does not have is left out, and you are told when it is sent.',
                style: TextStyle(fontSize: 11.5, color: Palette.faint),
              ),
            ),
        ],
      ),
    );
  }
}

/// The panel that names a preset and picks what it carries from [draft].
/// With [editing], changes that preset instead.
Future<void> openSavePreset(BuildContext context, AppState state, Preset draft, {Preset? editing}) => showPanel<void>(
  context,
  title: editing == null ? 'Save as preset' : 'Edit preset',
  icon: Icons.bookmark_add_outlined,
  width: 520,
  builder: (context) => _SavePreset(state: state, draft: draft, editing: editing),
);

class _SavePreset extends StatefulWidget {
  const _SavePreset({required this.state, required this.draft, this.editing});
  final AppState state;
  final Preset draft;
  final Preset? editing;

  @override
  State<_SavePreset> createState() => _SavePresetState();
}

class _SavePresetState extends State<_SavePreset> {
  late final TextEditingController _name = TextEditingController(text: widget.editing?.name ?? '');
  late final TextEditingController _prompt = TextEditingController(text: widget.draft.prompt ?? '');
  late final TextEditingController _negative = TextEditingController(text: widget.draft.negative ?? '');

  // Saving a whole picture's recipe is rarely what is meant by a style, so
  // only the words start ticked unless a preset is being edited.
  late bool _usePrompt = widget.draft.prompt != null;
  late bool _useNegative = widget.draft.negative != null && widget.draft.negative!.isNotEmpty;
  late bool _useLoras = widget.draft.loras.isNotEmpty;
  late bool _useSampling = widget.editing != null && (widget.draft.steps != null || widget.draft.cfg != null);
  late bool _useSize = widget.editing != null && widget.draft.width != null;
  late bool _replacePrompt = widget.draft.replacePrompt;
  late bool _replaceNegative = widget.draft.replaceNegative;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _negative.dispose();
    super.dispose();
  }

  bool get _ready =>
      _name.text.trim().isNotEmpty &&
      ((_usePrompt && _prompt.text.trim().isNotEmpty) || (_useNegative && _negative.text.trim().isNotEmpty) || _useLoras || _useSampling || _useSize);

  void _save() {
    final d = widget.draft;
    widget.state.savePreset(
      Preset(
        id: widget.editing?.id ?? widget.state.newPresetId(),
        name: _name.text.trim(),
        prompt: _usePrompt && _prompt.text.trim().isNotEmpty ? _prompt.text.trim() : null,
        replacePrompt: _replacePrompt,
        negative: _useNegative && _negative.text.trim().isNotEmpty ? _negative.text.trim() : null,
        replaceNegative: _replaceNegative,
        loras: _useLoras ? d.loras : const [],
        steps: _useSampling ? d.steps : null,
        cfg: _useSampling ? d.cfg : null,
        width: _useSize ? d.width : null,
        height: _useSize ? d.height : null,
      ),
    );
    Navigator.of(context).maybePop();
  }

  Widget _tick(String id, String title, String? detail, bool value, ValueChanged<bool> onChanged, {Widget? child}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      CheckboxListTile(
        key: ValueKey<String>('preset-use-$id'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(title),
        subtitle: detail == null ? null : Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
        value: value,
        onChanged: (v) => onChanged(v ?? false),
      ),
      if (value && child != null) Padding(padding: const EdgeInsets.only(left: 12, bottom: 8), child: child),
    ],
  );

  Widget _text(String id, TextEditingController controller, bool replace, ValueChanged<bool> onReplace) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: ValueKey<String>('preset-$id'),
        controller: controller,
        minLines: 2,
        maxLines: 4,
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 6),
      SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: false, label: Text('Add')),
          ButtonSegment(value: true, label: Text('Replace')),
        ],
        selected: {replace},
        onSelectionChanged: (s) => onReplace(s.first),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey<String>('preset-name'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          const Text(
            'Tick what this preset should carry. Anything left out stays as it is when you apply it.',
            style: TextStyle(fontSize: 12, color: Palette.muted, height: 1.35),
          ),
          if (d.prompt != null)
            _tick('prompt', 'Prompt phrases', null, _usePrompt, (v) => setState(() => _usePrompt = v),
                child: _text('prompt', _prompt, _replacePrompt, (v) => setState(() => _replacePrompt = v))),
          if (d.negative != null)
            _tick('negative', 'Negative prompt', null, _useNegative, (v) => setState(() => _useNegative = v),
                child: _text('negative', _negative, _replaceNegative, (v) => setState(() => _replaceNegative = v))),
          if (d.loras.isNotEmpty)
            _tick('loras', 'LoRAs', [for (final l in d.loras) '${l.name} at ${l.weight}'].join(', '), _useLoras, (v) => setState(() => _useLoras = v)),
          if (d.steps != null || d.cfg != null)
            _tick('sampling', 'Steps and CFG', '${d.steps ?? '–'} steps, CFG ${d.cfg ?? '–'}', _useSampling, (v) => setState(() => _useSampling = v)),
          if (d.width != null && d.height != null)
            _tick('size', 'Size', '${d.width} × ${d.height}', _useSize, (v) => setState(() => _useSize = v)),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey<String>('preset-confirm'),
              onPressed: _ready ? _save : null,
              child: const Text('Save preset'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings › Presets: the list, and getting presets in and out of the app.
class PresetSettings extends StatelessWidget {
  const PresetSettings({super.key, required this.state});
  final AppState state;

  static const String fileName = 'generativeview-presets.json';

  Future<void> _export(BuildContext context) async {
    final dir = state.folder;
    if (dir == null) return toast(context, 'Open a folder to export into');
    final path = '$dir/$fileName';
    try {
      await state.exportPresets(path);
      if (context.mounted) toast(context, 'Saved $path');
    } catch (e) {
      if (context.mounted) toast(context, 'Could not export: $e');
    }
  }

  Future<void> _share(BuildContext context) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$fileName';
      await state.exportPresets(path);
      final shared = await shareFiles([path]);
      if (!shared && context.mounted) toast(context, 'Could not share the presets');
    } catch (e) {
      if (context.mounted) toast(context, 'Could not share: $e');
    }
  }

  Future<void> _import(BuildContext context) async {
    final dir = state.folder;
    final path = await showDialog<String>(
      context: context,
      builder: (context) {
        final box = TextEditingController(text: dir == null ? '' : '$dir/$fileName');
        return AlertDialog(
          title: const Text('Import presets'),
          content: TextField(
            key: const ValueKey<String>('preset-import-path'),
            controller: box,
            decoration: const InputDecoration(labelText: 'Path of the presets file'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(box.text.trim()), child: const Text('Import')),
          ],
        );
      },
    );
    if (path == null || path.isEmpty || !context.mounted) return;
    try {
      if (!File(path).existsSync()) return toast(context, 'There is no file at $path');
      final added = await state.importPresets(path);
      if (context.mounted) toast(context, added == 1 ? 'Added 1 preset' : 'Added $added presets');
    } catch (e) {
      if (context.mounted) toast(context, 'Could not import: $e');
    }
  }

  Future<void> _delete(BuildContext context, Preset preset) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${preset.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes == true) state.deletePreset(preset);
  }

  @override
  Widget build(BuildContext context) {
    final presets = state.presets;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Saving and sharing', style: TextStyle(fontSize: 13.5)),
          const SizedBox(height: 3),
          const Text(
            'Presets are kept in the app, not in your picture folders, and go if the app is uninstalled. '
            'Export a file to back them up, move them to another device, or share them.',
            style: TextStyle(fontSize: 12, color: Palette.muted, height: 1.35),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton(key: const ValueKey<String>('preset-import'), onPressed: () => _import(context), child: const Text('Import…')),
              OutlinedButton(key: const ValueKey<String>('preset-export'), onPressed: presets.isEmpty ? null : () => _export(context), child: const Text('Export')),
              if (canShareFiles) OutlinedButton(onPressed: presets.isEmpty ? null : () => _share(context), child: const Text('Share…')),
            ],
          ),
          const Divider(height: 22),
          Expanded(
            child: presets.isEmpty
                ? const Center(
                    child: Text(
                      'Save one from Remix, or a picture\'s menu.',
                      style: TextStyle(fontSize: 12.5, color: Palette.faint),
                    ),
                  )
                : ReorderableListView(
                    buildDefaultDragHandles: true,
                    onReorder: state.movePreset,
                    children: [
                      for (final preset in presets)
                        ListTile(
                          key: ValueKey<String>('preset-row-${preset.id}'),
                          contentPadding: const EdgeInsets.only(right: 28),
                          title: Text(preset.name),
                          subtitle: Text(preset.parts.join(', ')),
                          onTap: () => openSavePreset(context, state, preset, editing: preset),
                          trailing: IconButton(
                            tooltip: 'Delete ${preset.name}',
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () => _delete(context, preset),
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
