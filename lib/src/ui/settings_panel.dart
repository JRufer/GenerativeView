import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/media_image.dart';
import '../core/models.dart';
import '../theme.dart';
import 'meta_panel.dart' show toast;
import 'remix_dialog.dart' show BackendSettings;
import 'sheet.dart';

/// Below this width the sections are a list that opens one at a time;
/// above it they sit beside the one that is open.
const double _sideBySideWidth = 640;

/// The orders a folder can open in.
const Map<String, String> _sorts = {
  'newest': 'Newest first',
  'oldest': 'Oldest first',
  'name': 'Name A to Z',
  'name_desc': 'Name Z to A',
  'size': 'Largest first',
  'rating': 'Best rated first',
  'taste': 'Likely keepers first',
};

enum _Section {
  general('General', Icons.tune),
  grid('Grid', Icons.grid_view),
  saved('Saved images', Icons.save_outlined),
  servers('Servers', Icons.dns_outlined),
  search('Search and AI', Icons.auto_awesome_outlined);

  const _Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The settings panel, from the ⋮ menu or `Ctrl ,`.
Future<void> openSettings(BuildContext context, AppState state) => showPanel<void>(
  context,
  title: 'Settings',
  icon: Icons.settings_outlined,
  width: 860,
  builder: (context) => SettingsPanel(state: state),
);

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key, required this.state});
  final AppState state;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  _Section _open = _Section.general;

  /// On a narrow screen, whether a section is open or the list is showing.
  bool _inSection = false;

  Widget _body() => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => switch (_open) {
      _Section.general => _General(state: widget.state),
      _Section.grid => _Grid(state: widget.state),
      _Section.saved => _Saved(state: widget.state),
      _Section.servers => BackendSettings(state: widget.state),
      _Section.search => _Search(state: widget.state),
    },
  );

  Widget _nav({required bool narrow}) => ListView(
    shrinkWrap: narrow,
    padding: const EdgeInsets.all(10),
    children: [
      for (final section in _Section.values)
        ListTile(
          key: ValueKey<String>('settings-${section.name}'),
          dense: !narrow,
          leading: Icon(section.icon, size: 18),
          title: Text(section.label),
          selected: !narrow && section == _open,
          selectedColor: Palette.text,
          selectedTileColor: Palette.hover,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          onTap: () => setState(() {
            _open = section;
            _inSection = true;
          }),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final height = math.min(620.0, MediaQuery.sizeOf(context).height * 0.75);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth >= _sideBySideWidth) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 210, child: _nav(narrow: false)),
                const VerticalDivider(width: 1),
                Expanded(child: _body()),
              ],
            );
          }
          if (!_inSection) return _nav(narrow: true);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    key: const ValueKey<String>('settings-back'),
                    tooltip: 'Back to Settings',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => setState(() => _inSection = false),
                  ),
                  Text(_open.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                ],
              ),
              const Divider(),
              Expanded(child: _body()),
            ],
          );
        },
      ),
    );
  }
}

class _General extends StatelessWidget {
  const _General({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Switch(
        id: 'recursive',
        title: 'Include sub-folders',
        detail: 'Show pictures from the folders inside the open one.',
        value: state.recursive,
        onChanged: state.setRecursive,
      ),
      _Line(
        title: 'Folder order',
        detail: 'How a folder is sorted when no search is showing.',
        child: DropdownButton<String>(
          key: const ValueKey<String>('settings-sort'),
          value: _sorts.containsKey(state.sort) ? state.sort : 'newest',
          underline: const SizedBox.shrink(),
          items: [
            for (final entry in _sorts.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (value) {
            if (value != null) state.setFolderSort(value);
          },
        ),
      ),
      _Switch(
        id: 'follow',
        title: 'Follow new pictures',
        detail: 'Select each new picture as it lands in the folder.',
        value: state.followNew,
        onChanged: (_) => state.toggleFollowNew(),
      ),
    ],
  );
}

class _Grid extends StatelessWidget {
  const _Grid({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Line(
        title: 'Tile size',
        detail: '${state.tileSize.round()} px',
        child: SizedBox(
          width: 180,
          child: Slider(
            key: const ValueKey<String>('settings-tile-size'),
            value: state.tileSize.clamp(minTileSize, maxTileSize).toDouble(),
            min: minTileSize,
            max: maxTileSize,
            onChanged: state.setTileSize,
          ),
        ),
      ),
      _Switch(
        id: 'crop',
        title: 'Crop tiles to fill',
        detail: 'Off shows each whole picture.',
        value: state.cropTiles,
        onChanged: (_) => state.toggleCrop(),
      ),
      _Switch(
        id: 'audience-badges',
        title: 'Audience badges',
        detail: 'Show each picture\'s rating, G to NC-17, on its tile.',
        value: state.audienceBadges,
        onChanged: (_) => state.toggleAudienceBadges(),
      ),
      _Switch(
        id: 'prewarm',
        title: 'Load ahead while scrolling',
        detail: 'Faster scrolling, using a little more memory.',
        value: state.prewarm,
        onChanged: state.setPrewarm,
      ),
    ],
  );
}

class _Saved extends StatelessWidget {
  const _Saved({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Choice(
        id: 'remix-format',
        title: 'Remixes and Breeds',
        detail: 'The server sends a PNG. This decides what is kept.',
        value: state.remixFormat,
        options: const {'png': 'PNG', 'jxl': 'JXL'},
        onChanged: state.setRemixFormat,
      ),
      _Choice(
        id: 'upscale-format',
        title: 'Upscales and hires fixes',
        detail: 'Upscales are the largest files, so they gain the most.',
        value: state.upscaleFormat,
        options: const {'same': 'Same as original', 'jxl': 'JXL'},
        onChanged: state.setUpscaleFormat,
      ),
      _Choice(
        id: 'jxl-quality',
        title: 'JXL quality',
        detail: 'Lossless keeps every pixel. High looks the same at normal viewing.',
        value: state.jxlQuality,
        options: const {'lossless': 'Lossless, 25–45% smaller', 'high': 'High, ~85% smaller'},
        onChanged: state.setJxlQuality,
      ),
      Container(
        key: const ValueKey<String>('settings-jxl-note'),
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Palette.raised,
          border: Border.all(color: Palette.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text.rich(
          TextSpan(
            style: TextStyle(fontSize: 12.5, height: 1.45),
            children: [
              TextSpan(
                text: 'JXL files are smaller and keep their prompt and workflow, and they work everywhere in '
                    'GenerativeView: Remix, Breed, Upscale, search and rating. ',
              ),
              TextSpan(
                text: 'InvokeAI, ComfyUI and Forge can\'t open a .jxl file themselves, and many other apps can\'t '
                    'either. When a server needs the picture, GenerativeView sends it a PNG copy.',
                style: TextStyle(color: Palette.muted),
              ),
            ],
          ),
        ),
      ),
      _Choice(
        id: 'send-jxl',
        title: 'When copying or sharing a JXL',
        detail: 'A PNG copy opens anywhere and carries the same prompt and workflow.',
        value: sendJxlAsPng ? 'png' : 'jxl',
        options: const {'png': 'Send PNG', 'jxl': 'Send JXL'},
        onChanged: (v) => state.setSendJxlAsPng(v == 'png'),
      ),
      _Line(
        title: 'Convert to JXL',
        detail: 'PNG and WebP only. The originals go to the trash, so you can get them back.',
        child: OutlinedButton(
          key: const ValueKey<String>('settings-convert'),
          onPressed: () => showPanel<void>(
            context,
            title: 'Convert to JXL',
            width: 460,
            builder: (context) => ConvertPanel(state: state),
          ),
          child: const Text('Convert…'),
        ),
      ),
    ],
  );
}

/// Convert pictures already saved: pick which, watch it go, stop any time.
class ConvertPanel extends StatefulWidget {
  const ConvertPanel({super.key, required this.state});
  final AppState state;

  @override
  State<ConvertPanel> createState() => _ConvertPanelState();
}

class _ConvertPanelState extends State<ConvertPanel> {
  String _which = 'remixes';
  List<MediaItem>? _items;
  int _done = 0;
  int _failed = 0;
  int _saved = 0;
  String? _error;
  bool _running = false;
  bool _stop = false;

  Map<String, String> get _choices => {
    'remixes': 'Remixes',
    'upscales': 'Upscales',
    'folder': 'This folder',
    if (widget.state.checkedItems.isNotEmpty) 'selection': 'Selected pictures',
  };

  @override
  void initState() {
    super.initState();
    _list();
  }

  @override
  void dispose() {
    _stop = true;
    super.dispose();
  }

  Future<void> _list() async {
    setState(() => _items = null);
    final which = _which;
    final state = widget.state;
    final items = switch (which) {
      'remixes' => await state.convertible('collection:="${AppState.remixCollection}"'),
      'upscales' => await state.convertible('collection:="${AppState.upscaleCollection}"'),
      'selection' => [
        for (final i in state.checkedItems)
          if (RegExp(r'\.(png|webp)$', caseSensitive: false).hasMatch(i.name)) i,
      ],
      _ => await state.convertible(''),
    };
    if (mounted && which == _which) setState(() => _items = items);
  }

  Future<void> _start() async {
    final items = _items ?? const <MediaItem>[];
    setState(() {
      _running = true;
      _stop = false;
      _done = _failed = _saved = 0;
      _error = null;
    });
    final converted = <MediaItem>[];
    for (final item in items) {
      if (_stop) break;
      try {
        _saved += await widget.state.convertToJxl(item);
        converted.add(item);
      } catch (e) {
        _failed++;
        _error = '$e';
      }
      _done++;
      if (mounted) setState(() {});
    }
    final kept = await widget.state.trashConverted(converted);
    if (!mounted) return;
    setState(() {
      _running = false;
      if (kept != null) _error = 'Converted, but the originals are still there: $kept';
    });
    final mb = (_saved / 1000000).toStringAsFixed(1);
    toast(context, 'Converted ${_done - _failed}, saving $mb MB${_failed > 0 ? '; $_failed could not be' : ''}');
    await _list();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButton<String>(
            key: const ValueKey<String>('convert-which'),
            isExpanded: true,
            value: _which,
            items: [
              for (final entry in _choices.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: _running
                ? null
                : (value) {
                    if (value == null) return;
                    _which = value;
                    _list();
                  },
          ),
          const SizedBox(height: 8),
          Text(
            items == null
                ? 'Counting…'
                : _running
                ? '$_done of ${items.length}'
                : '${items.length} ${items.length == 1 ? 'picture' : 'pictures'} to convert, ${widget.state.jxlQuality == 'high' ? 'High' : 'Lossless'}',
            style: const TextStyle(fontSize: 12.5, color: Palette.muted),
          ),
          if (_running) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: items == null || items.isEmpty ? null : _done / items.length, minHeight: 3),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(fontSize: 12, color: Palette.danger)),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: _running
                ? OutlinedButton(onPressed: () => setState(() => _stop = true), child: const Text('Stop'))
                : FilledButton(
                    key: const ValueKey<String>('convert-start'),
                    onPressed: items == null || items.isEmpty ? null : _start,
                    child: const Text('Convert'),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Search extends StatelessWidget {
  const _Search({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Line(
        title: 'Rate audience from',
        detail: 'The picture, its prompt, or the stricter of the two.',
        child: DropdownButton<String>(
          key: const ValueKey<String>('settings-audience-source'),
          value: state.audienceSource,
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(value: 'both', child: Text('Both')),
            DropdownMenuItem(value: 'image', child: Text('Picture')),
            DropdownMenuItem(value: 'prompt', child: Text('Prompt')),
          ],
          onChanged: (value) {
            if (value != null) state.setAudienceSource(value);
          },
        ),
      ),
    ],
  );
}

class _Page extends StatelessWidget {
  const _Page({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
    children: children,
  );
}

/// A setting: what it is on the left, its control on the right.
class _Line extends StatelessWidget {
  const _Line({required this.title, required this.child, this.detail});
  final String title;
  final String? detail;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 56),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Palette.line))),
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: const TextStyle(fontSize: 13.5)),
              if (detail != null) ...[
                const SizedBox(height: 3),
                Text(detail!, style: const TextStyle(fontSize: 12, color: Palette.muted, height: 1.3)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 16),
        child,
      ],
    ),
  );
}

/// A setting with a choice of a few: the choice under it, where long labels
/// fit on a phone too.
class _Choice extends StatelessWidget {
  const _Choice({required this.id, required this.title, required this.detail, required this.value, required this.options, required this.onChanged});
  final String id;
  final String title;
  final String detail;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Palette.line))),
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontSize: 13.5)),
        const SizedBox(height: 3),
        Text(detail, style: const TextStyle(fontSize: 12, color: Palette.muted, height: 1.3)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          key: ValueKey<String>('settings-$id'),
          showSelectedIcon: false,
          segments: [
            for (final entry in options.entries)
              ButtonSegment(value: entry.key, label: Text(entry.value, maxLines: 2, textAlign: TextAlign.center)),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ],
    ),
  );
}

class _Switch extends StatelessWidget {
  const _Switch({required this.id, required this.title, required this.value, required this.onChanged, this.detail});
  final String id;
  final String title;
  final String? detail;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _Line(
    title: title,
    detail: detail,
    child: Switch(key: ValueKey<String>('settings-$id'), value: value, onChanged: onChanged),
  );
}
