import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'stats_page.dart';

const double topBarHeight = 48;

/// How long the things in the bar take to move.
const Duration _barMotion = Duration(milliseconds: 220);
const Curve _barCurve = Curves.easeOutCubic;

/// [time], or no time at all where the system asks for less motion.
Duration motion(BuildContext context, Duration time) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : time;

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
              ExcludeFocus(
                child: focus
                    ? _BarButton(
                        icon: Icons.arrow_back,
                        tooltip: 'Back to grid (Esc)',
                        onTap: state.closeFocus,
                      )
                    : _BarButton(
                        icon: Icons.folder_outlined,
                        tooltip: 'Folders ([)',
                        active: state.leftOpen,
                        onTap: state.toggleLeft,
                      ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: focus
                    ? ExcludeFocus(child: _FocusTitle(state: state))
                    : _TitleAndSearch(state: state, rest: wide ? 320 : 170),
              ),
              const SizedBox(width: 4),
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

/// The folder's name and how much is in it, with the search box to their
/// right. While the box has the keyboard it grows over the name, as far as
/// the bar allows, so that what is being typed can be read; the count stays.
class _TitleAndSearch extends StatelessWidget {
  const _TitleAndSearch({required this.state, required this.rest});
  final AppState state;

  /// How wide the search box is when nobody is typing in it.
  final double rest;

  /// Room kept for the count beside the grown box, and the gap between them.
  static const double _countRoom = 104;
  static const double _gap = 8;

  /// Past this a wider box is no easier to read.
  static const double _widest = 760;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth;
        final resting = math.min(rest, room);
        final grown = math.max(
          resting,
          math.min(room - _countRoom - _gap, _widest),
        );
        return ListenableBuilder(
          listenable: state.searchFocus,
          builder: (context, _) => TweenAnimationBuilder<double>(
            tween: Tween<double>(end: state.searchFocus.hasFocus ? 1 : 0),
            duration: motion(context, _barMotion),
            curve: _barCurve,
            builder: (context, t, _) {
              final width = resting + (grown - resting) * t;
              return Stack(
                children: [
                  // The name and count give way to the count alone.
                  if (t < 1)
                    Positioned(
                      key: const ValueKey<String>('bar-title'),
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: math.max(0.0, room - resting - _gap),
                      child: ExcludeFocus(
                        child: Opacity(
                          opacity: 1 - t,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _FolderTitle(state: state),
                          ),
                        ),
                      ),
                    ),
                  if (t > 0)
                    Positioned(
                      key: const ValueKey<String>('bar-count'),
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: math.max(0.0, room - grown - _gap),
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: t,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _FolderTitle(state: state, countOnly: true),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    key: const ValueKey<String>('bar-search'),
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: width,
                    child: Center(
                      child: _SearchField(
                        state: state,
                        pinsWidth: math.max(grown, 280.0),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _FolderTitle extends StatelessWidget {
  const _FolderTitle({required this.state, this.countOnly = false});
  final AppState state;

  /// Leave the folder's name out.
  final bool countOnly;

  @override
  Widget build(BuildContext context) {
    final folder = state.folder;
    if (folder == null) {
      if (countOnly) return const SizedBox.shrink();
      return const Text(
        'GenerativeView',
        style: TextStyle(fontSize: 14, color: Palette.muted),
      );
    }
    final name = folder == '/' ? '/' : folder.split('/').last;
    final count = state.items.length;
    final noun = count == 1 ? 'item' : 'items';
    if (countOnly) {
      if (!state.loaded) return const SizedBox.shrink();
      return Text(
        state.query.trim().isEmpty
            ? '${_groupThousands(count)} $noun'
            : '${_groupThousands(count)} ${count == 1 ? 'match' : 'matches'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12.5, color: Palette.muted),
      );
    }
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
/// The switch at its left end chooses between finding text in the metadata
/// and describing what the pictures show.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.state, required this.pinsWidth});
  final AppState state;

  /// How wide the list of pins under the box is.
  final double pinsWidth;

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
            width: widget.pinsWidth,
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
                padding: const EdgeInsets.only(left: 5, right: 4),
                child: _SearchKindSwitch(
                  content: describing,
                  onTap: state.toggleContentSearch,
                ),
              ),
              prefixIconConstraints: const BoxConstraints(),
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

/// The switch between the two kinds of search: a pill with a magnifying
/// glass (the metadata's text) and a magnifying glass over a picture (what
/// the pictures show), and a thumb that slides to whichever is on.
class _SearchKindSwitch extends StatelessWidget {
  const _SearchKindSwitch({required this.content, required this.onTap});

  /// Whether content search is the one that is on.
  final bool content;
  final VoidCallback onTap;

  static const double _slot = 25;
  static const double _height = 24;
  static const double _inset = 2;
  static const Color _thumb = Color(0xFF3B3B45);
  static const Color _onAccent = Color(0xFF0B1020);

  @override
  Widget build(BuildContext context) {
    final time = motion(context, _barMotion);
    return Tooltip(
      message: content
          ? 'Searching by what the pictures show.\n'
                'Click to search prompts and metadata.'
          : 'Searching prompts and metadata.\n'
                'Click to search by what the pictures show.',
      child: Semantics(
        button: true,
        toggled: content,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            // As tall as the box, so there is more to hit than the pill.
            child: SizedBox(
              width: _slot * 2 + _inset * 2,
              height: 34,
              child: Center(child: _pill(time)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(Duration time) {
    Widget slot(IconData glyph, bool on) => SizedBox(
      width: _slot,
      height: _height,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(
          end: !on
              ? Palette.faint
              : content
              ? _onAccent
              : Palette.text,
        ),
        duration: time,
        curve: _barCurve,
        builder: (context, color, _) => Icon(glyph, size: 15, color: color),
      ),
    );
    return Container(
      width: _slot * 2 + _inset * 2,
      height: _height,
      decoration: BoxDecoration(
        color: Palette.canvas,
        borderRadius: BorderRadius.circular(_height / 2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: _inset),
      child: Stack(
        children: [
          AnimatedAlign(
            alignment: content ? Alignment.centerRight : Alignment.centerLeft,
            duration: time,
            curve: _barCurve,
            child: AnimatedContainer(
              key: const ValueKey<String>('search-kind-thumb'),
              duration: time,
              curve: _barCurve,
              width: _slot,
              height: _height - _inset * 2,
              decoration: BoxDecoration(
                color: content ? Palette.accent : _thumb,
                borderRadius: BorderRadius.circular(_height / 2),
              ),
            ),
          ),
          Row(
            children: [
              slot(Icons.search, !content),
              slot(Icons.image_search, content),
            ],
          ),
        ],
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
