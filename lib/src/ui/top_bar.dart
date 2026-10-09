import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

const double topBarHeight = 48;

String _groupThousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// The single strip of chrome above the content.
class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final focus = state.mode == ViewMode.focus;
    return Container(
      height: topBarHeight,
      decoration: const BoxDecoration(
        color: Palette.panel,
        border: Border(bottom: BorderSide(color: Palette.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          // Buttons, menus and the slider never hold keyboard focus (see
          // ShortcutLayer); only the search field does.
          return Row(
            children: [
              Expanded(
                child: ExcludeFocus(
                  child: Row(
                    children: [
                      if (focus)
                        _BarButton(
                          icon: Icons.arrow_back,
                          tooltip: 'Back to grid (Esc)',
                          onTap: state.closeFocus,
                        )
                      else
                        _BarButton(
                          icon: Icons.folder_outlined,
                          tooltip: 'Folders ([)',
                          active: state.leftOpen,
                          onTap: state.toggleLeft,
                        ),
                      const SizedBox(width: 6),
                      Expanded(child: focus ? _FocusTitle(state: state) : _FolderTitle(state: state)),
                    ],
                  ),
                ),
              ),
              if (!focus) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: wide ? 320 : 170,
                  child: _SearchField(state: state, controller: state.searchText, focusNode: state.searchFocus),
                ),
                const SizedBox(width: 4),
              ],
              ExcludeFocus(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!focus) ...[
                      _SortMenu(state: state),
                      _BarButton(
                        icon: Icons.account_tree_outlined,
                        tooltip: state.recursive ? 'Sub-folders are included' : 'Sub-folders are not included',
                        active: state.recursive,
                        onTap: () => state.setRecursive(!state.recursive),
                      ),
                      if (wide) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.photo_size_select_small, size: 15, color: Palette.faint),
                        SizedBox(
                          width: 120,
                          child: Slider(
                            value: state.tileSize,
                            min: minTileSize,
                            max: maxTileSize,
                            onChanged: state.setTileSize,
                          ),
                        ),
                      ],
                    ],
                    _BarButton(
                      icon: Icons.info_outline,
                      tooltip: 'Generation data (I)',
                      active: state.rightOpen,
                      onTap: state.toggleRight,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.tooltip, required this.onTap, this.active = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? Palette.hover : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          hoverColor: Palette.hover,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 19, color: active ? Palette.text : Palette.muted),
          ),
        ),
      ),
    );
  }
}

class _FolderTitle extends StatelessWidget {
  const _FolderTitle({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final folder = state.folder;
    if (folder == null) {
      return const Text('GenerativeView', style: TextStyle(fontSize: 14, color: Palette.muted));
    }
    final name = folder == '/' ? '/' : folder.split('/').last;
    final count = state.items.length;
    final noun = count == 1 ? 'item' : 'items';
    return Tooltip(
      message: folder,
      child: Row(
        children: [
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Palette.text),
            ),
          ),
          if (state.loaded) ...[
            const SizedBox(width: 10),
            Text(
              state.query.trim().isEmpty
                  ? '${_groupThousands(count)} $noun'
                  : '${_groupThousands(count)} ${count == 1 ? 'match' : 'matches'}',
              maxLines: 1,
              style: const TextStyle(fontSize: 12.5, color: Palette.muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _FocusTitle extends StatelessWidget {
  const _FocusTitle({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final item = state.selected;
    if (item == null) return const SizedBox.shrink();
    return Row(
      children: [
        Flexible(
          child: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Palette.text),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '${_groupThousands(state.selectedIndex + 1)} of ${_groupThousands(state.items.length)}',
          maxLines: 1,
          style: const TextStyle(fontSize: 12.5, color: Palette.muted),
        ),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.state, required this.controller, required this.focusNode});
  final AppState state;
  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: state.setQuery,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 13.5),
        cursorColor: Palette.accent,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search prompts, models, names',
          hintStyle: const TextStyle(color: Palette.faint, fontSize: 13.5),
          prefixIcon: const Icon(Icons.search, size: 17, color: Palette.faint),
          prefixIconConstraints: const BoxConstraints(minWidth: 34),
          suffixIcon: state.query.isEmpty
              ? null
              : InkResponse(
                  radius: 14,
                  onTap: () {
                    controller.clear();
                    state.setQuery('');
                  },
                  child: const Icon(Icons.close, size: 16, color: Palette.muted),
                ),
          suffixIconConstraints: const BoxConstraints(minWidth: 30),
          filled: true,
          fillColor: Palette.raised,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Palette.accent, width: 1),
          ),
        ),
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.state});
  final AppState state;

  static const Map<String, String> _labels = {
    'newest': 'Newest first',
    'oldest': 'Oldest first',
    'name': 'Name A to Z',
    'name_desc': 'Name Z to A',
    'size': 'Largest first',
  };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Sort and refresh',
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value == '_rescan') {
          state.rescan();
        } else {
          state.setSort(value);
        }
      },
      itemBuilder: (context) => [
        for (final entry in _labels.entries)
          PopupMenuItem<String>(
            value: entry.key,
            height: 36,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: state.sort == entry.key
                      ? const Icon(Icons.check, size: 16, color: Palette.accent)
                      : null,
                ),
                Text(entry.value),
              ],
            ),
          ),
        const PopupMenuDivider(height: 8),
        const PopupMenuItem<String>(
          value: '_rescan',
          height: 36,
          child: Row(
            children: [
              SizedBox(width: 24, child: Icon(Icons.refresh, size: 16, color: Palette.muted)),
              Text('Rescan folder (F5)'),
            ],
          ),
        ),
      ],
      child: const SizedBox(
        width: 36,
        height: 36,
        child: Icon(Icons.sort, size: 19, color: Palette.muted),
      ),
    );
  }
}
