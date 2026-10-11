import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'stats_page.dart';

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
                      Expanded(
                        child: focus
                            ? _FocusTitle(state: state)
                            : _FolderTitle(state: state),
                      ),
                    ],
                  ),
                ),
              ),
              if (!focus) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: wide ? 320 : 170,
                  child: _SearchField(state: state, width: wide ? 320 : 170),
                ),
                const SizedBox(width: 4),
              ],
              ExcludeFocus(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!focus) ...[
                      _SortMenu(state: state, withStats: !wide),
                      _BarButton(
                        icon: Icons.account_tree_outlined,
                        tooltip: state.recursive
                            ? 'Sub-folders are included'
                            : 'Sub-folders are not included',
                        active: state.recursive,
                        onTap: () => state.setRecursive(!state.recursive),
                      ),
                      _BarButton(
                        icon: Icons.crop,
                        tooltip: state.cropTiles
                            ? 'Thumbnails are cropped to fill (C)'
                            : 'Thumbnails show the whole image (C)',
                        active: state.cropTiles,
                        onTap: state.toggleCrop,
                      ),
                      if (wide) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.photo_size_select_small,
                          size: 15,
                          color: Palette.faint,
                        ),
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
                    if (!focus && wide && state.folder != null)
                      _BarButton(
                        icon: Icons.bar_chart,
                        tooltip: 'Usage stats',
                        onTap: () => openStats(context, state),
                      ),
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
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });
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
            child: Icon(
              icon,
              size: 19,
              color: active ? Palette.text : Palette.muted,
            ),
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
      return const Text(
        'GenerativeView',
        style: TextStyle(fontSize: 14, color: Palette.muted),
      );
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
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Palette.text,
              ),
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
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Palette.text,
            ),
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

/// The search box. While it has focus the pinned searches hang under it;
/// the pin beside the clear button keeps (or lets go of) the current one.
/// The magnifying glass switches between finding text in the metadata and
/// describing what the pictures show.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.state, required this.width});
  final AppState state;

  /// How wide the box is; the list of pins is at least this wide.
  final double width;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _pins = OverlayPortalController();

  /// Whether the text has been edited since the box took focus. Until then
  /// every pinned search is offered; after that, the ones that contain it.
  bool _edited = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.searchFocus.addListener(_onFocus);
    // The box can come back (from the focus view, say) already focused.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onFocus());
  }

  @override
  void dispose() {
    state.searchFocus.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    final focused = state.searchFocus.hasFocus;
    if (focused == _pins.isShowing) return;
    if (focused) {
      _edited = false;
      _pins.show();
    } else {
      _pins.hide();
    }
  }

  List<PinnedSearch> _offered() {
    final pins = state.pinnedSearches;
    final typed = state.searchText.text.trim().toLowerCase();
    if (!_edited || typed.isEmpty) return pins;
    return [
      for (final pin in pins)
        if (pin.query.toLowerCase().contains(typed)) pin,
    ];
  }

  void _pick(PinnedSearch pin) {
    state.applySearch(pin.query, content: pin.content);
    state.searchFocus.unfocus();
  }

  Widget _buildPins(BuildContext context) {
    final pins = _offered();
    if (pins.isEmpty) return const SizedBox.shrink();
    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: Alignment.bottomLeft,
      offset: const Offset(0, 4),
      child: Align(
        alignment: Alignment.topLeft,
        // Part of the text field as far as "tapped outside" goes, so
        // choosing a pin does not first take the focus away.
        child: TextFieldTapRegion(
          child: _PinnedSearches(
            width: math.max(widget.width, 280.0),
            pins: pins,
            onPick: _pick,
            onRemove: state.unpinSearch,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = state.query;
    final current = state.currentSearch;
    final pinned = state.isSearchPinned(current);
    final describing = state.contentSearch;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _pins,
        overlayChildBuilder: _buildPins,
        child: SizedBox(
          height: 34,
          child: TextField(
            controller: state.searchText,
            focusNode: state.searchFocus,
            onChanged: (text) {
              _edited = true;
              state.setQuery(text);
            },
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 13.5),
            cursorColor: Palette.accent,
            decoration: InputDecoration(
              isDense: true,
              hintText: describing
                  ? 'Describe what the picture shows'
                  : 'Search prompts, models, names',
              hintStyle: const TextStyle(color: Palette.faint, fontSize: 13.5),
              prefixIcon: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: _FieldButton(
                  icon: describing ? Icons.image_search : Icons.search,
                  color: describing ? Palette.accent : Palette.faint,
                  tooltip: describing
                      ? 'Searching by what the pictures show.\n'
                            'Click to search prompts and metadata.'
                      : 'Searching prompts and metadata.\n'
                            'Click to search by what the pictures show.',
                  onTap: state.toggleContentSearch,
                ),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 34),
              suffixIcon: query.trim().isEmpty
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _FieldButton(
                            icon: pinned
                                ? Icons.push_pin
                                : Icons.push_pin_outlined,
                            color: pinned ? Palette.accent : Palette.faint,
                            tooltip: pinned
                                ? 'Unpin this search'
                                : 'Pin this search',
                            onTap: () => pinned
                                ? state.unpinSearch(current)
                                : state.pinSearch(current),
                          ),
                          _FieldButton(
                            icon: Icons.close,
                            tooltip: 'Clear search',
                            onTap: () {
                              state.searchText.clear();
                              state.setQuery('');
                            },
                          ),
                        ],
                      ),
                    ),
              suffixIconConstraints: const BoxConstraints(minWidth: 30),
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
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Palette.accent, width: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small icon button inside the search box.
class _FieldButton extends StatelessWidget {
  const _FieldButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = Palette.muted,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        radius: 14,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}

/// The list of pinned searches that hangs under the search box.
class _PinnedSearches extends StatelessWidget {
  const _PinnedSearches({
    required this.width,
    required this.pins,
    required this.onPick,
    required this.onRemove,
  });
  final double width;
  final List<PinnedSearch> pins;
  final ValueChanged<PinnedSearch> onPick;
  final ValueChanged<PinnedSearch> onRemove;

  @override
  Widget build(BuildContext context) {
    // Never takes the keyboard focus: that stays in the search box.
    return ExcludeFocus(
      child: Material(
        key: const ValueKey<String>('pinned-searches'),
        color: Palette.raised,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Palette.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: 332),
          child: SizedBox(
            width: width,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                for (final pin in pins)
                  _PinnedSearchRow(
                    pin: pin,
                    onPick: () => onPick(pin),
                    onRemove: () => onRemove(pin),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PinnedSearchRow extends StatelessWidget {
  const _PinnedSearchRow({
    required this.pin,
    required this.onPick,
    required this.onRemove,
  });
  final PinnedSearch pin;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPick,
      hoverColor: Palette.hover,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            const SizedBox(width: 10),
            // A magnifying glass over a picture marks a content search.
            Icon(
              pin.content ? Icons.image_search : Icons.push_pin,
              size: 14,
              color: Palette.faint,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                pin.query,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Palette.text),
              ),
            ),
            Tooltip(
              message: 'Remove from pinned searches',
              child: InkResponse(
                radius: 16,
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.close, size: 15, color: Palette.muted),
                ),
              ),
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.state, required this.withStats});
  final AppState state;

  /// Where the bar has no room for a usage button, the menu offers it.
  final bool withStats;

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
        } else if (value == '_stats') {
          openStats(context, state);
        } else {
          state.setSort(value);
        }
      },
      itemBuilder: (context) => [
        for (final entry in {
          // Only a search has matches to put in order.
          if (state.searching) 'relevance': 'Best match first',
          ..._labels,
        }.entries)
          PopupMenuItem<String>(
            value: entry.key,
            height: 36,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: state.activeSort == entry.key
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
              SizedBox(
                width: 24,
                child: Icon(Icons.refresh, size: 16, color: Palette.muted),
              ),
              Text('Rescan folder (F5)'),
            ],
          ),
        ),
        if (withStats && state.folder != null)
          const PopupMenuItem<String>(
            value: '_stats',
            height: 36,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Icon(Icons.bar_chart, size: 16, color: Palette.muted),
                ),
                Text('Usage stats'),
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
