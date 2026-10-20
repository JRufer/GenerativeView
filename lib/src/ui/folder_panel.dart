import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart' show exactTerm, normalizePath;
import '../theme.dart';
import 'context_menu.dart';
import 'filter_sheet.dart';
import 'sheet.dart';
import 'smart_editor.dart';

/// The left-hand panel: pinned folders, then places to start from and a
/// lazily loaded folder tree. Tap a folder to view it; tap its arrow to look
/// inside without leaving the current view; right-click or press and hold it
/// to pin it.
class FolderPanel extends StatefulWidget {
  const FolderPanel({super.key, required this.state, this.onPicked});
  final AppState state;

  /// Called after a folder is chosen (used to close the panel on small screens).
  final VoidCallback? onPicked;

  @override
  State<FolderPanel> createState() => _FolderPanelState();
}

const double _rowHeight = 32;

/// The filled, blue folder that marks a pinned folder wherever it is listed.
const IconData pinnedFolderIcon = Icons.folder;

class _Row {
  const _Row(this.name, this.path, this.depth, this.expandable, this.icon);
  final String name;
  final String path;
  final int depth;
  final bool expandable;
  final IconData icon;
}

String _baseName(String path) {
  if (path == '/' || RegExp(r'^[A-Za-z]:/?$').hasMatch(path)) return path;
  final clean = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final idx = clean.lastIndexOf('/');
  return idx >= 0 ? clean.substring(idx + 1) : clean;
}

String _parentOf(String path) {
  final clean = (path.length > 3 && path.endsWith('/')) ? path.substring(0, path.length - 1) : path;
  final cut = clean.lastIndexOf('/');
  if (cut < 0) return '/';
  if (cut == 0) return '/';
  if (cut == 2 && clean[1] == ':' && RegExp(r'^[A-Za-z]').hasMatch(clean)) {
    return clean.substring(0, 3);
  }
  return clean.substring(0, cut);
}


class _FolderPanelState extends State<FolderPanel> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _path = TextEditingController();
  final FocusNode _pathFocus = FocusNode();

  int _seenReveal = -1;

  AppState get state => widget.state;

  /// After the tree has been opened down to the current folder, bring that
  /// row into view (it can be hundreds of rows down in a big tree).
  void _scrollToCurrent(List<_Row> rows) {
    if (state.treeRevealTick == _seenReveal) return;
    final target = normalizePath(state.folder ?? '');
    final index = rows.indexWhere(
      (r) => normalizePath(r.path) == target && r.depth > 0,
    );
    final fallback = index >= 0
        ? index
        : rows.indexWhere((r) => normalizePath(r.path) == target);
    if (fallback < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final top = fallback * _rowHeight;
      final visible =
          top >= position.pixels &&
          top + _rowHeight * 3 <= position.pixels + position.viewportDimension;
      if (!visible) {
        if (position.maxScrollExtent > 0 || fallback == 0) {
          _scroll.jumpTo(
            (top - position.viewportDimension / 4)
                .clamp(0.0, position.maxScrollExtent)
                .toDouble(),
          );
          _seenReveal = state.treeRevealTick;
        }
      } else {
        _seenReveal = state.treeRevealTick;
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _path.dispose();
    _pathFocus.dispose();
    super.dispose();
  }

  IconData _placeIcon(String kind) => switch (kind) {
    'home' => Icons.home_outlined,
    'drive' => Icons.storage_outlined,
    'root' => Icons.dns_outlined,
    _ => Icons.folder_outlined,
  };

  /// Flatten places and their expanded descendants into display rows.
  List<_Row> _rows() {
    final rows = <_Row>[];
    void addChildren(String parent, int depth) {
      final childrenList = state.children[parent] ??
          state.children[normalizePath(parent)] ??
          const <DirNode>[];
      for (final child in childrenList) {
        rows.add(
          _Row(
            child.name,
            child.path,
            depth,
            child.hasChildren,
            Icons.folder_outlined,
          ),
        );
        final childNorm = normalizePath(child.path);
        if (state.expanded.contains(child.path) ||
            state.expanded.contains(childNorm)) {
          addChildren(child.path, depth + 1);
        }
      }
    }

    for (final place in state.places) {
      rows.add(_Row(place.name, place.path, 0, true, _placeIcon(place.kind)));
      final placeNorm = normalizePath(place.path);
      if (state.expanded.contains(place.path) ||
          state.expanded.contains(placeNorm)) {
        addChildren(place.path, 1);
      }
    }
    return rows;
  }

  void _pick(String path) {
    state.openFolder(path);
    widget.onPicked?.call();
  }

  void _goToTypedPath() {
    final text = _path.text.trim();
    if (text.isEmpty) return;
    _pick(text);
    _path.clear();
    _pathFocus.unfocus();
  }

  /// The right-click / press-and-hold menu of a folder, wherever it is listed.
  Future<void> _menu(String path, Offset position) async {
    final pinned = state.isFolderPinned(path);
    final choice = await showContextMenu<String>(context, position, [
      MenuEntry(
        'pin',
        pinned ? 'Unpin this folder' : 'Pin this folder',
        pinned ? Icons.push_pin_outlined : Icons.push_pin,
      ),
    ]);
    if (choice == 'pin') state.toggleFolderPin(path);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _PanelTabs(state: state);
    if (state.leftTab == LeftTab.filters) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          tabs,
          Expanded(
            child: state.folder == null
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('Open a folder to filter it.', style: TextStyle(color: Palette.muted, fontSize: 13)),
                  )
                : FilterPanel(key: const ValueKey<String>('docked-filters'), state: state, docked: true),
          ),
        ],
      );
    }
    final rows = _rows();
    _scrollToCurrent(rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tabs,
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: SizedBox(
            height: 34,
            child: TextField(
              controller: _path,
              focusNode: _pathFocus,
              onSubmitted: (_) => _goToTypedPath(),
              style: const TextStyle(fontSize: 13),
              cursorColor: Palette.accent,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Go to folder path…',
                hintStyle: const TextStyle(color: Palette.faint, fontSize: 13),
                prefixIcon: const Icon(
                  Icons.subdirectory_arrow_right,
                  size: 16,
                  color: Palette.faint,
                ),
                prefixIconConstraints: const BoxConstraints(minWidth: 32),
                filled: true,
                fillColor: Palette.raised,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 9,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        _PinnedFolders(state: state, onOpen: _pick, onMenu: _menu),
        if (state.folder != null) _SmartCollections(state: state, onPicked: widget.onPicked),
        _Collections(state: state, onPicked: widget.onPicked),
        Expanded(
          child: rows.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'No folders to show yet.',
                    style: TextStyle(color: Palette.muted, fontSize: 13),
                  ),
                )
              : ExcludeFocus(
                  child: Scrollbar(
                    controller: _scroll,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.only(bottom: 16),
                      itemExtent: _rowHeight,
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        final rowNorm = normalizePath(row.path);
                        return _FolderRow(
                          row: row,
                          current: rowNorm == normalizePath(state.folder ?? ''),
                          pinned: state.isFolderPinned(row.path),
                          expanded: state.expanded.contains(row.path) ||
                              state.expanded.contains(rowNorm),
                          onOpen: () => _pick(row.path),
                          onToggle: () => state.toggleExpanded(row.path),
                          onMenu: (position) => _menu(row.path, position),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// The folders the user has pinned, one tap from anywhere. The heading is
/// always there; tapping it folds the list away.
class _PinnedFolders extends StatelessWidget {
  const _PinnedFolders({
    required this.state,
    required this.onOpen,
    required this.onMenu,
  });
  final AppState state;
  final ValueChanged<String> onOpen;
  final void Function(String path, Offset position) onMenu;

  @override
  Widget build(BuildContext context) {
    final pins = state.pinnedFolders;
    final open = state.pinsOpen;
    // Two pins with the same name are told apart by where they live.
    final names = [for (final path in pins) _baseName(path)];
    return ExcludeFocus(
      key: const ValueKey<String>('pinned-folders'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: state.togglePins,
              hoverColor: Palette.hover,
              child: SizedBox(
                height: 28,
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 26,
                      child: Icon(
                        open ? Icons.expand_more : Icons.chevron_right,
                        size: 18,
                        color: Palette.faint,
                      ),
                    ),
                    const Expanded(
                      child: Text(
                        'PINNED',
                        style: TextStyle(
                          fontSize: 10.5,
                          letterSpacing: 0.9,
                          fontWeight: FontWeight.w600,
                          color: Palette.faint,
                        ),
                      ),
                    ),
                    if (pins.isNotEmpty)
                      Text(
                        '${pins.length}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Palette.faint,
                        ),
                      ),
                    const SizedBox(width: 12),
                  ],
                ),
              ),
            ),
          ),
          if (open && pins.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(30, 2, 12, 8),
              child: Text(
                'Right-click a folder, or press and hold it, to pin it here.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: Palette.faint,
                ),
              ),
            ),
          if (open && pins.isNotEmpty)
            ConstrainedBox(
              // Room for a handful; more than that scrolls.
              constraints: const BoxConstraints(maxHeight: _rowHeight * 6.5),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemExtent: _rowHeight,
                itemCount: pins.length,
                itemBuilder: (context, index) {
                  final path = pins[index];
                  final name = names[index];
                  final twin = names.where((n) => n == name).length > 1;
                  return _FolderRow(
                    row: _Row(name, path, 0, false, pinnedFolderIcon),
                    detail: twin ? _baseName(_parentOf(path)) : null,
                    current: path == state.folder,
                    pinned: true,
                    expanded: false,
                    onOpen: () => onOpen(path),
                    onMenu: (position) => onMenu(path, position),
                  );
                },
              ),
            ),
          const Divider(height: 9),
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.row,
    required this.current,
    required this.pinned,
    required this.expanded,
    required this.onOpen,
    required this.onMenu,
    this.onToggle,
    this.detail,
  });

  final _Row row;
  final bool current;
  final bool pinned;
  final bool expanded;
  final VoidCallback onOpen;
  final VoidCallback? onToggle;

  /// Called with where the pointer was on a right click or a long press.
  final ValueChanged<Offset> onMenu;

  /// Shown, faint, after the name.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: current
          ? Palette.accent.withValues(alpha: 0.16)
          : Colors.transparent,
      child: GestureDetector(
        onSecondaryTapUp: (details) => onMenu(details.globalPosition),
        onLongPressStart: (details) => onMenu(details.globalPosition),
        child: InkWell(
          onTap: onOpen,
          hoverColor: Palette.hover,
          child: Padding(
            padding: EdgeInsets.only(left: 4.0 + row.depth * 14.0, right: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 26,
                  height: 32,
                  child: row.expandable
                      ? InkResponse(
                          onTap: onToggle,
                          radius: 14,
                          child: Icon(
                            expanded ? Icons.expand_more : Icons.chevron_right,
                            size: 18,
                            color: Palette.faint,
                          ),
                        )
                      : null,
                ),
                Icon(
                  pinned ? pinnedFolderIcon : row.icon,
                  size: 16,
                  color: pinned || current ? Palette.accent : Palette.muted,
                ),
                const SizedBox(width: 8),
                Flexible(
                  fit: detail == null ? FlexFit.tight : FlexFit.loose,
                  child: Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: current ? Palette.text : const Color(0xFFCFCFD6),
                      fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Palette.faint,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The collections pictures have been put in, wherever they are. Tapping
/// one shows its pictures in the current folder (and below it).
class _Collections extends StatefulWidget {
  const _Collections({required this.state, this.onPicked});
  final AppState state;
  final VoidCallback? onPicked;

  @override
  State<_Collections> createState() => _CollectionsState();
}

class _CollectionsState extends State<_Collections> {
  List<(String, int)> _names = const [];
  bool _open = true;

  @override
  void initState() {
    super.initState();
    widget.state.notesTick.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.state.notesTick.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final names = await widget.state.collections();
    if (mounted) setState(() => _names = names);
  }

  /// A right click or a long press on a collection: delete it, once the
  /// user has said yes.
  Future<void> _menu(String name, int count, Offset position) async {
    final choice = await showContextMenu<String>(context, position, const [
      MenuEntry('delete', 'Delete collection…', Icons.delete_outline),
    ]);
    if (choice != 'delete' || !mounted) return;
    final pictures = count == 1 ? '1 picture' : '$count pictures';
    final yes = await confirmAction(
      context,
      title: 'Delete "$name"?',
      message: 'The $pictures in it are taken out of the collection and the collection goes away. The pictures themselves are not deleted.',
      action: 'Delete collection',
    );
    if (yes) await widget.state.deleteCollection(name);
  }

  @override
  Widget build(BuildContext context) {
    if (_names.isEmpty) return const SizedBox.shrink();
    final current = widget.state.query.trim();
    return ExcludeFocus(
      key: const ValueKey<String>('collections'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              hoverColor: Palette.hover,
              child: SizedBox(
                height: 28,
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 26,
                      child: Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 18, color: Palette.faint),
                    ),
                    const Expanded(
                      child: Text(
                        'COLLECTIONS',
                        style: TextStyle(fontSize: 10.5, letterSpacing: 0.9, fontWeight: FontWeight.w600, color: Palette.faint),
                      ),
                    ),
                    Text('${_names.length}', style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
                    const SizedBox(width: 12),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _rowHeight * 5.5),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemExtent: _rowHeight,
                itemCount: _names.length,
                itemBuilder: (context, index) {
                  final (name, count) = _names[index];
                  final query = exactTerm('collection', name);
                  final on = current == query;
                  return Material(
                    color: on ? Palette.accent.withValues(alpha: 0.16) : Colors.transparent,
                    child: GestureDetector(
                      key: ValueKey<String>('collection-$name'),
                      onSecondaryTapUp: (details) => _menu(name, count, details.globalPosition),
                      onLongPressStart: (details) => _menu(name, count, details.globalPosition),
                      child: InkWell(
                        onTap: () {
                          widget.state.applyFilter(on ? '' : query);
                          widget.onPicked?.call();
                        },
                        hoverColor: Palette.hover,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 30, right: 12),
                          child: Row(
                            children: [
                              Icon(Icons.collections_bookmark_outlined, size: 16, color: on ? Palette.accent : Palette.muted),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Color(0xFFCFCFD6))),
                              ),
                              Text('$count', style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          const Divider(height: 9),
        ],
      ),
    );
  }
}

/// The panel's two tabs: the folders (with pins and collections), and the
/// filters, docked beside the grid. The Filters tab shows how many filters
/// are on.
class _PanelTabs extends StatelessWidget {
  const _PanelTabs({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final on = state.contentSearch ? 0 : FilterSet.parse(state.query).count;
    Widget tab(LeftTab tab, String label, IconData icon, {int badge = 0}) {
      final selected = state.leftTab == tab;
      return Expanded(
        child: Semantics(
          selected: selected,
          button: true,
          child: InkWell(
            key: ValueKey<String>('left-tab-${tab.name}'),
            onTap: () => state.setLeftTab(tab),
            hoverColor: Palette.hover,
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: selected ? Palette.accent : Colors.transparent, width: 2)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 16, color: selected ? Palette.accent : Palette.muted),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? Palette.text : Palette.muted,
                    ),
                  ),
                  if (badge > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: Palette.accent, borderRadius: BorderRadius.circular(9)),
                      child: Text('$badge', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Palette.canvas)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ExcludeFocus(
      child: DecoratedBox(
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Palette.line))),
        child: Row(
          children: [
            tab(LeftTab.folders, 'Folders', Icons.folder_outlined),
            tab(LeftTab.filters, 'Filters', Icons.tune, badge: on),
          ],
        ),
      ),
    );
  }
}

/// Searches kept under a name, saved beside the pictures: each shows the
/// pictures that match it now. Tap one to show it; right-click or press and
/// hold it to change or delete it.
class _SmartCollections extends StatefulWidget {
  const _SmartCollections({required this.state, this.onPicked});
  final AppState state;
  final VoidCallback? onPicked;

  @override
  State<_SmartCollections> createState() => _SmartCollectionsState();
}

class _SmartCollectionsState extends State<_SmartCollections> {
  bool _open = true;

  AppState get state => widget.state;

  Future<void> _menu(SmartCollection smart, Offset position) async {
    final choice = await showContextMenu<String>(context, position, const [
      MenuEntry('edit', 'Edit smart collection…', Icons.edit_outlined),
      MenuEntry('delete', 'Delete smart collection…', Icons.delete_outline),
    ]);
    if (!mounted) return;
    if (choice == 'edit') {
      await openSmartEditor(context, state, existing: smart);
    } else if (choice == 'delete') {
      final yes = await confirmAction(
        context,
        title: 'Delete \u201c${smart.name}\u201d?',
        message: 'The smart collection goes away. The pictures it shows are not touched.',
        action: 'Delete',
      );
      if (yes) await state.deleteSmartCollection(smart);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = state.smart;
    final current = state.contentSearch ? '' : state.query.trim();
    return ExcludeFocus(
      key: const ValueKey<String>('smart-collections'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              hoverColor: Palette.hover,
              child: SizedBox(
                height: 28,
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 26,
                      child: Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 18, color: Palette.faint),
                    ),
                    const Expanded(
                      child: Text(
                        'SMART COLLECTIONS',
                        style: TextStyle(fontSize: 10.5, letterSpacing: 0.9, fontWeight: FontWeight.w600, color: Palette.faint),
                      ),
                    ),
                    if (list.isNotEmpty) Text('${list.length}', style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
                    SizedBox(
                      width: 32,
                      height: 28,
                      child: IconButton(
                        key: const ValueKey<String>('smart-new'),
                        tooltip: 'New smart collection',
                        padding: EdgeInsets.zero,
                        iconSize: 17,
                        onPressed: () => openSmartEditor(context, state, query: current),
                        icon: const Icon(Icons.add, color: Palette.muted),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ),
          if (_open && list.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(30, 2, 12, 8),
              child: Text(
                'Filters or a search, kept under a name. They stay up to date as pictures come and go.',
                style: TextStyle(fontSize: 12, height: 1.35, color: Palette.faint),
              ),
            ),
          if (_open && list.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _rowHeight * 5.5),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemExtent: _rowHeight,
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final smart = list[index];
                  final on = current == smart.query.trim();
                  return Material(
                    color: on ? Palette.accent.withValues(alpha: 0.16) : Colors.transparent,
                    child: GestureDetector(
                      key: ValueKey<String>('smart-${smart.name}'),
                      onSecondaryTapUp: (details) => _menu(smart, details.globalPosition),
                      onLongPressStart: (details) => _menu(smart, details.globalPosition),
                      child: InkWell(
                        onTap: () {
                          state.applyFilter(on ? '' : smart.query);
                          widget.onPicked?.call();
                        },
                        hoverColor: Palette.hover,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 30, right: 12),
                          child: Row(
                            children: [
                              Icon(Icons.auto_awesome_motion_outlined, size: 16, color: on ? Palette.accent : Palette.muted),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  smart.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13, color: Color(0xFFCFCFD6)),
                                ),
                              ),
                              if (smart.count >= 0)
                                Text('${smart.count}', style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          const Divider(height: 9),
        ],
      ),
    );
  }
}
