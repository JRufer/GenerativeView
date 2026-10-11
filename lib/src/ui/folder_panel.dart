import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'context_menu.dart';

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

String _baseName(String path) => path == '/' ? '/' : path.split('/').last;

String _parentOf(String path) {
  final cut = path.lastIndexOf('/');
  return cut <= 0 ? '/' : path.substring(0, cut);
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
    final index = rows.indexWhere((r) => r.path == state.folder && r.depth > 0);
    final fallback = index >= 0
        ? index
        : rows.indexWhere((r) => r.path == state.folder);
    if (fallback < 0) return;
    _seenReveal = state.treeRevealTick;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final top = fallback * _rowHeight;
      final visible =
          top >= position.pixels &&
          top + _rowHeight * 3 <= position.pixels + position.viewportDimension;
      if (!visible) {
        _scroll.jumpTo(
          (top - position.viewportDimension / 4)
              .clamp(0.0, position.maxScrollExtent)
              .toDouble(),
        );
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
      for (final child in state.children[parent] ?? const <DirNode>[]) {
        rows.add(
          _Row(
            child.name,
            child.path,
            depth,
            child.hasChildren,
            Icons.folder_outlined,
          ),
        );
        if (state.expanded.contains(child.path)) {
          addChildren(child.path, depth + 1);
        }
      }
    }

    for (final place in state.places) {
      rows.add(_Row(place.name, place.path, 0, true, _placeIcon(place.kind)));
      if (state.expanded.contains(place.path)) addChildren(place.path, 1);
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
    final rows = _rows();
    _scrollToCurrent(rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
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
                        return _FolderRow(
                          row: row,
                          current: row.path == state.folder,
                          pinned: state.isFolderPinned(row.path),
                          expanded: state.expanded.contains(row.path),
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
