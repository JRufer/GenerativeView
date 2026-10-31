import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'meta_panel.dart' show toast;
import 'filter_sheet.dart';
import 'notes_widgets.dart' show starColor;
import 'smart_editor.dart';

/// Over the grid while filters are on: each filter as a chip that takes it
/// off, a way to take them all off, and to keep them as a smart collection
/// (or, when a smart collection is showing, to change it).
class FilterBar extends StatelessWidget {
  const FilterBar({super.key, required this.state});
  final AppState state;

  /// Whether there is anything for the bar to show.
  static bool wanted(AppState state) {
    if (state.folder == null || state.contentSearch || state.mode != ViewMode.grid) return false;
    return state.showingSmart != null || !FilterSet.parse(state.query).isEmpty;
  }

  void _set(FilterSet filters) => state.applySearch(filters.toQuery(), content: false);

  @override
  Widget build(BuildContext context) {
    final filters = FilterSet.parse(state.query);
    final smart = state.showingSmart;
    final chips = <Widget>[];
    void chip(String key, String label, void Function(FilterSet f) remove, {IconData? icon}) {
      chips.add(
        _FilterChip(
          key: ValueKey<String>('filter-bar-$key'),
          label: label,
          icon: icon,
          onRemove: () {
            final next = FilterSet.parse(state.query);
            remove(next);
            _set(next);
          },
        ),
      );
    }

    for (final MapEntry(key: field, value: values) in filters.chosen.entries) {
      for (final v in values) {
        final shown = v.length > 40 ? '${v.substring(0, 39)}…' : v;
        chip('$field-$v', '${facetLabel(field)}: $shown', (f) => f.toggle(field, v));
      }
    }
    if (filters.minRating > 0) {
      chip(
        'rating',
        filters.minRating < 5 ? '${filters.minRating} stars or more' : '5 stars',
        (f) => f.minRating = 0,
        icon: Icons.star_rounded,
      );
    }
    if (filters.unrated) chip('unrated', 'Not rated', (f) => f.unrated = false);
    for (final flag in filters.flags) {
      chip('flag-${flag.word}', flag.label, (f) => f.flags.remove(flag));
    }
    if (filters.media != MediaShown.both) {
      chip('media', filters.media == MediaShown.images ? 'Images only' : 'Videos only', (f) => f.media = MediaShown.both);
    }
    if (filters.duplicates) chip('duplicates', 'Near-duplicates', (f) => f.duplicates = false);
    if (filters.taste != null) {
      chip('taste', filters.taste == 'keep' ? 'Likely keepers' : 'Suggested rejects', (f) => f.taste = null);
    }

    final count = state.items.length;
    return Container(
      key: const ValueKey<String>('filter-bar'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: const BoxDecoration(
        color: Palette.panel,
        border: Border(bottom: BorderSide(color: Palette.line)),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (smart != null)
            _SmartChip(
              smart: smart,
              onEdit: () => openSmartEditor(context, state, existing: smart),
              onClose: () => state.applyFilter(''),
            ),
          ...chips,
          if (chips.isNotEmpty)
            TextButton(
              key: const ValueKey<String>('filter-bar-clear'),
              onPressed: () => clearFilters(state),
              style: TextButton.styleFrom(minimumSize: const Size(0, 34), foregroundColor: Palette.muted),
              child: Text(chips.length > 1 ? 'Clear all' : 'Clear'),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              'Showing $count',
              style: const TextStyle(fontSize: 12.5, color: Palette.muted),
            ),
          ),
          if (filters.duplicates && state.duplicateGroups.isNotEmpty)
            TextButton.icon(
              key: const ValueKey<String>('filter-bar-best'),
              onPressed: () {
                final n = state.tickAllButBest();
                toast(context, '$n ticked; the best of each group is left unticked');
              },
              style: TextButton.styleFrom(minimumSize: const Size(0, 34)),
              icon: const Icon(Icons.workspace_premium_outlined, size: 16),
              label: const Text('Tick all but the best'),
            ),
          if (smart == null)
            OutlinedButton.icon(
              key: const ValueKey<String>('filter-bar-save'),
              onPressed: () => openSmartEditor(context, state, query: state.query.trim()),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                foregroundColor: Palette.accent,
                side: BorderSide(color: Palette.accent.withValues(alpha: 0.6)),
              ),
              icon: const Icon(Icons.auto_awesome_motion_outlined, size: 16),
              label: const Text('Save as smart collection'),
            ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({super.key, required this.label, required this.onRemove, this.icon});
  final String label;
  final VoidCallback onRemove;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: Palette.accent.withValues(alpha: 0.14),
        border: Border.all(color: Palette.accent.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 15, color: starColor), const SizedBox(width: 6)],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Palette.text)),
          ),
          SizedBox(
            width: 34,
            height: 34,
            child: IconButton(
              tooltip: 'Take this filter off',
              padding: EdgeInsets.zero,
              iconSize: 15,
              onPressed: onRemove,
              icon: const Icon(Icons.close, color: Palette.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The smart collection showing: its name, a way to change it, and a way
/// back to the whole folder.
class _SmartChip extends StatelessWidget {
  const _SmartChip({required this.smart, required this.onEdit, required this.onClose});
  final SmartCollection smart;
  final VoidCallback onEdit;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('filter-bar-smart'),
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: Palette.raised,
        border: Border.all(color: Palette.line),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome_motion_outlined, size: 15, color: Palette.accent),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              smart.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Palette.text),
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            key: const ValueKey<String>('filter-bar-edit-smart'),
            onPressed: onEdit,
            style: TextButton.styleFrom(minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: const Text('Edit'),
          ),
          SizedBox(
            width: 34,
            height: 34,
            child: IconButton(
              tooltip: 'Show the whole folder',
              padding: EdgeInsets.zero,
              iconSize: 15,
              onPressed: onClose,
              icon: const Icon(Icons.close, color: Palette.muted),
            ),
          ),
        ],
      ),
    );
  }
}
