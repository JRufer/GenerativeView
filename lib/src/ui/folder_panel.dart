import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

/// The left-hand panel: places to start from and a lazily loaded folder tree.
/// Tap a folder to view it; tap its arrow to look inside without leaving the
/// current view.
class FolderPanel extends StatefulWidget {
  const FolderPanel({super.key, required this.state, this.onPicked});
  final AppState state;

  /// Called after a folder is chosen (used to close the panel on small screens).
  final VoidCallback? onPicked;

  @override
  State<FolderPanel> createState() => _FolderPanelState();
}

const double _rowHeight = 32;

class _Row {
  const _Row(this.name, this.path, this.depth, this.expandable, this.icon);
  final String name;
  final String path;
  final int depth;
  final bool expandable;
  final IconData icon;
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
    final fallback = index >= 0 ? index : rows.indexWhere((r) => r.path == state.folder);
    if (fallback < 0) return;
    _seenReveal = state.treeRevealTick;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final top = fallback * _rowHeight;
      final visible = top >= position.pixels && top + _rowHeight * 3 <= position.pixels + position.viewportDimension;
      if (!visible) {
        _scroll.jumpTo((top - position.viewportDimension / 4).clamp(0.0, position.maxScrollExtent).toDouble());
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
        rows.add(_Row(child.name, child.path, depth, child.hasChildren, Icons.folder_outlined));
        if (state.expanded.contains(child.path)) addChildren(child.path, depth + 1);
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
                prefixIcon: const Icon(Icons.subdirectory_arrow_right, size: 16, color: Palette.faint),
                prefixIconConstraints: const BoxConstraints(minWidth: 32),
                filled: true,
                fillColor: Palette.raised,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
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
                        expanded: state.expanded.contains(row.path),
                        onOpen: () => _pick(row.path),
                        onToggle: () => state.toggleExpanded(row.path),
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

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.row,
    required this.current,
    required this.expanded,
    required this.onOpen,
    required this.onToggle,
  });

  final _Row row;
  final bool current;
  final bool expanded;
  final VoidCallback onOpen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: current ? Palette.accent.withValues(alpha: 0.16) : Colors.transparent,
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
              Icon(row.icon, size: 16, color: current ? Palette.accent : Palette.muted),
              const SizedBox(width: 8),
              Expanded(
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
            ],
          ),
        ),
      ),
    );
  }
}
