import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/media_image.dart';
import '../core/models.dart';
import '../desktop_integration.dart';
import '../render_queue.dart';
import '../theme.dart';
import 'meta_panel.dart' show toast;
import '../platform.dart' show trashAsksFirst;
import 'presets_ui.dart';
import 'remix_dialog.dart' show BackendSettings;
import 'sheet.dart';
import '../updates.dart';
import 'update_ui.dart';

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
  viewer('Viewer', Icons.fullscreen),
  saved('Saved images', Icons.save_outlined),
  presets('Presets', Icons.bookmarks_outlined),
  remix('Remix and Breed', Icons.auto_fix_high),
  upscale('Upscale', Icons.photo_size_select_large),
  servers('Servers', Icons.dns_outlined),
  search('Search and AI', Icons.auto_awesome_outlined),
  notifications('Notifications', Icons.notifications_outlined),
  appearance('Appearance', Icons.palette_outlined),
  storage('Storage', Icons.storage_outlined);

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
      _Section.viewer => _Viewer(state: widget.state),
      _Section.remix => _Remix(state: widget.state),
      _Section.upscale => _Upscale(state: widget.state),
      _Section.notifications => _Notifications(state: widget.state),
      _Section.appearance => _Appearance(state: widget.state),
      _Section.storage => _Storage(state: widget.state),
      _Section.saved => _Saved(state: widget.state),
      _Section.presets => PresetSettings(state: widget.state),
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
      _Pref(state, 'pref_reopen', 'Reopen last folder on start', true),
      if (!trashAsksFirst)
        _Pref(state, 'pref_confirm_delete', 'Confirm before delete', true),
      _Switch(
        id: 'follow',
        title: 'Follow new pictures',
        detail: 'Select each new picture as it lands in the folder.',
        value: state.followNew,
        onChanged: (_) => state.toggleFollowNew(),
      ),
      const _DefaultViewer(),
      if (appUpdater?.canCheck ?? false) ...[
        _Pref(
          state,
          updateCheckPref,
          'Check for updates',
          true,
          detail: 'Look on GitHub for a newer build a little after the app starts, and every few hours while it is open. Nothing installs until you say so.',
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: UpdateCard(updater: appUpdater),
        ),
      ],
    ],
  );
}

/// On Linux, a way to make this the program pictures open in when
/// double-clicked in the file manager. Not shown where that can't be done.
class _DefaultViewer extends StatefulWidget {
  const _DefaultViewer();

  @override
  State<_DefaultViewer> createState() => _DefaultViewerState();
}

class _DefaultViewerState extends State<_DefaultViewer> {
  bool? _isDefault;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final value = await isDefaultImageViewer();
    if (mounted) setState(() => _isDefault = value);
  }

  Future<void> _make() async {
    setState(() => _busy = true);
    final ok = await makeDefaultImageViewer();
    await _check();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) toast(context, 'The desktop would not change it');
  }

  @override
  Widget build(BuildContext context) {
    final isDefault = _isDefault;
    if (isDefault == null) return const SizedBox.shrink();
    return _Line(
      title: 'Open pictures with GenerativeView',
      detail: isDefault
          ? 'Double-clicking a picture in the file manager opens it here, with the rest of its folder a swipe away.'
          : 'Make this the program a double-click on a picture opens. It is under "Open With" either way.',
      child: isDefault
          ? const Icon(Icons.check_circle, color: Palette.accent, size: 22)
          : OutlinedButton(
              key: const ValueKey<String>('settings-default-viewer'),
              onPressed: _busy ? null : _make,
              child: const Text('Make default'),
            ),
    );
  }
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
      _Slide(state, 'pref_gap', 'Gap between tiles', 3, 0, 12, 12, ' px'),
      _Pref(state, 'pref_dim_rejected', 'Fade rejected pictures', true),
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

class _Viewer extends StatelessWidget {
  const _Viewer({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Slide(state, 'pref_max_zoom', 'Highest zoom', 400, 100, 800, 14, '%'),
      _Slide(state, 'pref_swipe', 'Swipe distance to turn the page', 18, 5, 40, 7, '% of the width'),
      _Pref(state, 'pref_zoom_chip', 'Show the zoom percentage', true),
    ],
  );
}

class _Remix extends StatelessWidget {
  const _Remix({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Pref(state, 'pref_random_seed', 'Random seed each time', false),
      _Slide(state, 'pref_remix_count', 'Remix count', 1, 1, 8, 7, ''),
      _Slide(state, 'pref_breed_count', 'Breed candidates', 6, 1, 12, 11, ''),
      _Slide(state, 'pref_strength', 'Starting denoise strength', 0.6, 0.05, 1, 19, '', digits: 2),
      _Slide(state, 'pref_poll', 'Check servers for results every', 2, 1, 30, 29, ' s'),
      _Slide(state, 'pref_patience', 'Give up on a job after', 3, 1, 24, 23, ' h'),
      _Slide(state, 'pref_keep_days', 'Keep waiting for unfinished jobs for', 7, 1, 30, 29, ' days'),
      _Pref(
        state,
        queueAutoPref,
        'Look for an offline server automatically',
        true,
        detail: 'Renders queued while a server was offline start once it answers. Off, it is only looked for from "Check now" on the round button.',
      ),
      _Choice(
        id: queuePollPref,
        title: 'Look for an offline server every',
        detail: 'How often the app asks a server with renders queued for it whether it is back, while the app is open.',
        value: () {
          final seconds = state.prefNumber(queuePollPref, queuePollDefault.toDouble()).round();
          return '${queuePollChoices.contains(seconds) ? seconds : queuePollDefault}';
        }(),
        options: {for (final s in queuePollChoices) '$s': everyText(s)},
        onChanged: (v) => state.setPref(queuePollPref, v),
      ),
    ],
  );
}

class _Upscale extends StatelessWidget {
  const _Upscale({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Slide(state, 'pref_upscale_size', 'Default size', 2, 1.5, 4, 5, '×', digits: 1),
      _Pref(state, 'pref_keep_metadata', 'Keep metadata', true),
      _Pref(state, 'pref_refine', 'Refine on a server by default', false),
    ],
  );
}

class _Notifications extends StatelessWidget {
  const _Notifications({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Pref(state, 'pref_notify_remix', 'Notify when a remix finishes', true, detail: 'While the app is in the background.'),
      _Pref(state, 'pref_saved_note', 'Say when a file is saved', true),
    ],
  );
}

class _Appearance extends StatelessWidget {
  const _Appearance({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      _Slide(state, 'pref_text_size', 'Text size', 100, 80, 150, 14, '%'),
      _Pref(state, 'pref_reduce_motion', 'Reduce animations', false),
    ],
  );
}

class _Storage extends StatefulWidget {
  const _Storage({required this.state});
  final AppState state;

  @override
  State<_Storage> createState() => _StorageState();
}

class _StorageState extends State<_Storage> {
  int? _bytes;
  ({int entries, int folders})? _stale;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final size = await state.core.call('thumbs_size');
    final stale = await state.core.call('notes_prune', {'apply': false});
    if (!mounted) return;
    setState(() {
      _bytes = ((size as Map)['bytes'] as num).toInt();
      _stale = (entries: ((stale as Map)['entries'] as num).toInt(), folders: (stale['folders'] as num).toInt());
    });
  }

  Future<void> _clear() async {
    await state.core.call('thumbs_clear');
    state.thumbs.clear();
    await _measure();
    state.rescan();
  }

  Future<void> _prune() async {
    await state.core.call('notes_prune', {'apply': true});
    state.notesTick.value++;
    await _measure();
    if (mounted) toast(context, 'Cleaned up');
  }

  Future<void> _reset() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset all settings?'),
        content: const Text('Your presets, servers, pins and ratings are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Reset')),
        ],
      ),
    );
    if (yes == true) state.resetPrefs();
  }

  @override
  Widget build(BuildContext context) {
    final mb = _bytes == null ? '…' : '${(_bytes! / 1000000).toStringAsFixed(0)} MB';
    final stale = _stale;
    return _Page(
      children: [
        _Line(
          title: 'Thumbnail cache',
          detail: mb,
          child: OutlinedButton(key: const ValueKey<String>('settings-clear-thumbs'), onPressed: _bytes == null ? null : _clear, child: const Text('Clear')),
        ),
        _Line(
          title: 'Clean up data for missing files',
          detail: stale == null
              ? 'Checking…'
              : stale.entries == 0
              ? 'Nothing to clean up.'
              : '${stale.entries} ${stale.entries == 1 ? 'entry' : 'entries'} in ${stale.folders} ${stale.folders == 1 ? 'folder' : 'folders'} for files that are gone. '
                    'A folder with none of its files is left alone, in case a drive is unplugged or a sync is under way.',
          child: OutlinedButton(key: const ValueKey<String>('settings-prune'), onPressed: stale == null || stale.entries == 0 ? null : _prune, child: const Text('Clean up')),
        ),
        _Line(
          title: 'Reset all settings',
          detail: 'Presets, servers, pins and ratings are kept.',
          child: OutlinedButton(key: const ValueKey<String>('settings-reset'), onPressed: _reset, child: const Text('Reset…')),
        ),
      ],
    );
  }
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

/// A saved on-or-off setting.
class _Pref extends StatelessWidget {
  const _Pref(this.state, this.prefKey, this.title, this.fallback, {this.detail});
  final AppState state;
  final String prefKey;
  final String title;
  final bool fallback;
  final String? detail;

  @override
  Widget build(BuildContext context) => _Switch(
    id: prefKey,
    title: title,
    detail: detail,
    value: state.prefFlag(prefKey, fallback),
    onChanged: (v) => state.setPref(prefKey, v),
  );
}

/// A saved number on a slider.
class _Slide extends StatelessWidget {
  const _Slide(this.state, this.prefKey, this.title, this.fallback, this.min, this.max, this.divisions, this.unit, {this.digits = 0});
  final AppState state;
  final String prefKey;
  final String title;
  final double fallback;
  final double min;
  final double max;
  final int divisions;
  final String unit;
  final int digits;

  @override
  Widget build(BuildContext context) {
    final value = state.prefNumber(prefKey, fallback).clamp(min, max).toDouble();
    return _Line(
      title: title,
      detail: '${value.toStringAsFixed(digits)}$unit',
      child: SizedBox(
        width: 170,
        child: Slider(
          key: ValueKey<String>('settings-$prefKey'),
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (v) => state.setPref(prefKey, v),
        ),
      ),
    );
  }
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
