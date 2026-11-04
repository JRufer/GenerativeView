import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
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
