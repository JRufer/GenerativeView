import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'notes_widgets.dart' show starColor;
import 'sheet.dart';
import 'smart_editor.dart';

/// The facets the filter panel offers, in order: (usage kind, search field,
/// heading).
const List<(String, String, String)> _facets = [
  ('model', 'model', 'Models'),
  ('lora', 'lora', 'LoRAs'),
  ('collection', 'collection', 'Collections'),
  ('prompt', 'fullprompt', 'Prompts'),
  ('word', 'prompt', 'Prompt words'),
  ('sampler', 'sampler', 'Samplers'),
  ('scheduler', 'scheduler', 'Schedulers'),
  ('steps', 'steps', 'Steps'),
  ('cfg', 'cfg', 'CFG'),
  ('size', 'size', 'Sizes'),
  ('source', 'source', 'Made with'),
];

/// Fields whose values all have to match, one term each, rather than any.
const Set<String> _allOf = {'prompt'};

/// What the filter panel has chosen, and the rest of the search it leaves
/// alone.
/// Which kinds of file the grid shows.
enum MediaShown { both, images, videos }

class FilterSet {
  FilterSet({
    required this.free,
    required this.chosen,
    this.minRating = 0,
    this.unrated = false,
    Set<Flag>? flags,
    this.media = MediaShown.both,
    this.duplicates = false,
  }) : flags = flags ?? {};

  /// Terms the panel does not manage: typed words, dates, negations.
  final List<String> free;

  /// Values chosen per search field.
  final Map<String, Set<String>> chosen;
  int minRating;
  bool unrated;
  final Set<Flag> flags;
  MediaShown media;

  /// Only pictures that have a near-duplicate, each group together
  /// (`is:duplicate`).
  bool duplicates;

  static const Set<String> _duplicateWords = {'duplicate', 'duplicates', 'dupe', 'dupes', 'near-duplicate', 'near-duplicates'};

  /// The search fields that mean the kind of file (`type:video`).
  static const Set<String> _typeFields = {'type', 'kind', 'media', 'is'};

  static final Set<String> _managed = {for (final f in _facets) f.$2, 'rating', 'flag', ..._typeFields};

  /// The same search with every filter taken off and typed words kept.
  FilterSet cleared() => FilterSet(free: free, chosen: {});

  /// Read the panel's choices back out of a search.
  factory FilterSet.parse(String query) {
    final free = <String>[];
    final chosen = <String, Set<String>>{};
    var minRating = 0;
    var unrated = false;
    final flags = <Flag>{};
    var media = MediaShown.both;
    var duplicates = false;
    for (final raw in splitTerms(query)) {
      final t = parseTerm(raw);
      if (t.negate || !_managed.contains(t.field)) {
        free.add(raw);
        continue;
      }
      if (_typeFields.contains(t.field) && _duplicateWords.contains(t.value.toLowerCase().trim())) {
        duplicates = true;
        continue;
      }
      if (_typeFields.contains(t.field)) {
        final kinds = t.value.toLowerCase().split('|').map((k) => k.trim()).toSet();
        final images = kinds.any((k) => k.startsWith('image') || k.startsWith('picture') || k == 'photo' || k == 'still');
        final videos = kinds.any((k) => k.startsWith('video') || k == 'movie' || k == 'clip');
        if (images == videos) {
          if (!images) free.add(raw);
        } else {
          media = images ? MediaShown.images : MediaShown.videos;
        }
        continue;
      }
      if (t.field == 'rating') {
        final m = RegExp(r'^>=(\d)$').firstMatch(t.value);
        if (m != null) {
          minRating = int.parse(m.group(1)!);
        } else if (t.value == 'none') {
          unrated = true;
        } else {
          free.add(raw);
        }
        continue;
      }
      if (t.field == 'flag') {
        flags.addAll(t.value.split('|').map((f) => f == 'none' ? Flag.none : Flag.parse(f)));
        continue;
      }
      if (!t.exact) {
        free.add(raw);
        continue;
      }
      final values = _allOf.contains(t.field) || t.field == 'fullprompt' ? [t.value] : t.value.split('|');
      chosen.putIfAbsent(t.field, () => {}).addAll(values.where((v) => v.isNotEmpty));
    }
    return FilterSet(free: free, chosen: chosen, minRating: minRating, unrated: unrated, flags: flags, media: media, duplicates: duplicates);
  }

  bool get isEmpty =>
      chosen.values.every((s) => s.isEmpty) && minRating == 0 && !unrated && flags.isEmpty && media == MediaShown.both && !duplicates;

  int get count =>
      chosen.values.fold(0, (n, s) => n + s.length) +
      (minRating > 0 ? 1 : 0) +
      (unrated ? 1 : 0) +
      flags.length +
      (media == MediaShown.both ? 0 : 1) +
      (duplicates ? 1 : 0);

  bool has(String field, String value) => chosen[field]?.any((v) => v.toLowerCase() == value.toLowerCase()) ?? false;

  void toggle(String field, String value) {
    final set = chosen.putIfAbsent(field, () => {});
    final existing = set.where((v) => v.toLowerCase() == value.toLowerCase()).toList();
    if (existing.isEmpty) {
      set.add(value);
    } else {
      set.removeAll(existing);
    }
  }

  /// The free part of the search alone, for counting what is on offer.
  String get freeText => free.join(' ');

  /// The whole search.
  String toQuery() {
    final parts = [...free];
    for (final (_, field, _) in _facets) {
      final values = chosen[field];
      if (values == null || values.isEmpty) continue;
      if (_allOf.contains(field) || field == 'fullprompt') {
        // Words all have to be there; whole prompts are one or the other,
        // but a prompt can hold `|`, so each is a term of its own and only
        // one may be chosen at a time.
        for (final v in values) {
          parts.add(exactTerm(field, v));
        }
      } else {
        parts.add(anyOfTerm(field, values));
      }
    }
    if (minRating > 0) parts.add('rating:>=$minRating');
    if (unrated) parts.add('rating:none');
    if (flags.isNotEmpty) parts.add('flag:${flags.map((f) => f.word).join('|')}');
    if (media == MediaShown.images) parts.add('type:image');
    if (media == MediaShown.videos) parts.add('type:video');
    if (duplicates) parts.add('is:duplicate');
    return parts.join(' ');
  }
}

/// Take every filter off the search, keeping what was typed.
void clearFilters(AppState state) {
  state.applySearch(FilterSet.parse(state.query).cleared().toQuery(), content: false);
}

/// Whether [query] has anything the filter panel set.
bool hasFilters(String query) => !FilterSet.parse(query).isEmpty;

/// Open the filter panel: what the folder's pictures were made with, rated
/// and collected as, each a chip to narrow the grid by. Chips in one group
/// widen it (this model or that one); groups narrow it (this model and
/// this sampler). Prompt words all have to be there.
Future<void> openFilters(BuildContext context, AppState state) {
  return showPanel<void>(
    context,
    title: 'Filters',
    icon: Icons.tune,
    width: 720,
    builder: (context) => FilterPanel(state: state),
  );
}

class FilterPanel extends StatefulWidget {
  const FilterPanel({super.key, required this.state});
  final AppState state;

  @override
  State<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<FilterPanel> {
  late FilterSet _filters = FilterSet.parse(widget.state.query);
  late String _seenQuery = widget.state.query;
  UsageStats? _stats;
  String? _countedFor;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    _count();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    // The search changed from outside (typed, a chip taken off over the
    // grid, a collection opened): show what it now chooses.
    final query = widget.state.query;
    if (query != _seenQuery) {
      _seenQuery = query;
      _filters = FilterSet.parse(query);
    }
    _count();
    setState(() {});
  }

  Future<void> _count() async {
    final state = widget.state;
    final text = _filters.freeText;
    // Counted again for another folder too, or with sub-folders in or out.
    final key = '${state.folder}|${state.recursive}|$text';
    if (_countedFor == key && _stats != null) return;
    _countedFor = key;
    try {
      final stats = await state.usage(text: text);
      if (mounted && _countedFor == key) setState(() => _stats = stats);
    } catch (_) {}
  }

  void _apply() {
    final query = _filters.toQuery();
    _seenQuery = query;
    widget.state.applySearch(query, content: false);
    setState(() {});
  }

  void _toggle(String field, String value) {
    _filters.toggle(field, value);
    _apply();
  }

  void _clear() {
    _filters = _filters.cleared();
    _apply();
  }

  UsageGroup? _group(String kind) {
    for (final g in _stats?.groups ?? const <UsageGroup>[]) {
      if (g.kind == kind) return g;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final matches = widget.state.items.length;
    final query = widget.state.query.trim();
    final saved = widget.state.showingSmart;
    final list = stats == null
        ? const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        : ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                  children: [
                    if (_filters.free.isNotEmpty)
                      Text(
                        'Within: ${_filters.freeText}',
                        style: const TextStyle(fontSize: 12, color: Palette.faint),
                      ),
                    const PanelHeading('Show'),
                    _mediaRow(),
                    const SizedBox(height: 8),
                    const PanelHeading('Rating and flag'),
                    _ratingRow(),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final flag in Flag.values)
                          ChoiceChipButton(
                            key: ValueKey<String>('filter-flag-${flag.word}'),
                            label: flag.label,
                            icon: switch (flag) {
                              Flag.keep => Icons.check_circle_outline,
                              Flag.reject => Icons.cancel_outlined,
                              Flag.none => Icons.radio_button_unchecked,
                            },
                            selected: _filters.flags.contains(flag),
                            onTap: () {
                              if (!_filters.flags.remove(flag)) _filters.flags.add(flag);
                              _apply();
                            },
                          ),
                      ],
                    ),
                    for (final (kind, field, title) in _facets) ..._section(kind, field, title),
                  ],
                );
    // A search that is already a smart collection is edited there; any
    // other can be kept as one.
    final save = TextButton.icon(
      key: const ValueKey<String>('filters-save-smart'),
      onPressed: query.isEmpty || widget.state.contentSearch
          ? null
          : () => saved != null
                ? openSmartEditor(context, widget.state, existing: saved)
                : openSmartEditor(context, widget.state, query: query),
      icon: const Icon(Icons.auto_awesome_motion_outlined, size: 17),
      label: Text(saved != null ? 'Edit smart collection' : 'Save…'),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(child: list),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                key: const ValueKey<String>('filters-clear'),
                onPressed: _filters.isEmpty ? null : _clear,
                child: const Text('Clear filters'),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  save,
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey<String>('filters-done'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(matches == 1 ? 'Show 1 picture' : 'Show $matches pictures'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _mediaRow() {
    Widget choice(MediaShown media, String label, IconData icon) => ChoiceChipButton(
          key: ValueKey<String>('filter-type-${media.name}'),
          label: label,
          icon: icon,
          selected: _filters.media == media,
          onTap: () {
            _filters.media = media;
            _apply();
          },
        );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        choice(MediaShown.both, 'Images and videos', Icons.perm_media_outlined),
        choice(MediaShown.images, 'Images only', Icons.image_outlined),
        choice(MediaShown.videos, 'Videos only', Icons.videocam_outlined),
        ChoiceChipButton(
          key: const ValueKey<String>('filter-duplicates'),
          label: 'Near-duplicates only',
          icon: Icons.filter_none,
          tooltip: 'Pictures that have an all-but-identical twin here (the same seed run again, a small change, a resave), each group side by side',
          selected: _filters.duplicates,
          onTap: () {
            _filters.duplicates = !_filters.duplicates;
            _apply();
          },
        ),
      ],
    );
  }

  Widget _ratingRow() {
    final min = _filters.minRating;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var n = 1; n <= 5; n++)
              Tooltip(
                message: min == n ? 'Any rating' : '$n stars or more',
                child: InkResponse(
                  key: ValueKey<String>('filter-stars-$n'),
                  radius: 20,
                  onTap: () {
                    _filters.minRating = min == n ? 0 : n;
                    if (_filters.minRating > 0) _filters.unrated = false;
                    _apply();
                  },
                  child: SizedBox(
                    width: 38,
                    height: 40,
                    child: Icon(
                      n <= min ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: n <= min ? starColor : Palette.faint,
                      size: 24,
                    ),
                  ),
                ),
              ),
          ],
        ),
        Text(min == 0 ? 'Any rating' : '$min or more', style: const TextStyle(fontSize: 12.5, color: Palette.muted)),
        ChoiceChipButton(
          label: 'Not rated',
          selected: _filters.unrated,
          count: _group('rating')?.items.where((i) => i.value == '0').firstOrNull?.count,
          onTap: () {
            _filters.unrated = !_filters.unrated;
            if (_filters.unrated) _filters.minRating = 0;
            _apply();
          },
        ),
      ],
    );
  }

  List<Widget> _section(String kind, String field, String title) {
    final group = _group(kind);
    final items = group?.items ?? const <UsageItem>[];
    // Chosen values stay on offer even where this search no longer has them.
    final chosen = _filters.chosen[field] ?? const <String>{};
    final listed = items.map((i) => i.value.toLowerCase()).toSet();
    final missing = [
      for (final v in chosen)
        if (!listed.contains(v.toLowerCase())) v,
    ];
    if (items.isEmpty && missing.isEmpty) return const [];
    final all = _expanded.contains(kind);
    final shown = all ? items : items.take(kind == 'prompt' ? 6 : 14).toList();
    return [
      PanelHeading(
        title,
        trailing: items.length > shown.length || all
            ? TextButton(
                onPressed: () => setState(() {
                  if (!_expanded.remove(kind)) _expanded.add(kind);
                }),
                child: Text(all ? 'Fewer' : 'All ${items.length}'),
              )
            : null,
      ),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final v in missing)
            ChoiceChipButton(label: _short(v), selected: true, onTap: () => _toggle(field, v)),
          for (final item in shown)
            ChoiceChipButton(
              key: ValueKey<String>('filter-$kind-${item.value}'),
              label: _short(group!.label(item)),
              tooltip: item.value.length > 60 ? item.value : null,
              count: item.count,
              selected: _filters.has(field, item.value),
              onTap: () {
                if (field == 'fullprompt') {
                  // One whole prompt at a time.
                  final on = _filters.has(field, item.value);
                  _filters.chosen[field] = on ? {} : {item.value};
                  _apply();
                } else {
                  _toggle(field, item.value);
                }
              },
            ),
        ],
      ),
    ];
  }

  static String _short(String s) => s.length > 64 ? '${s.substring(0, 61)}…' : s;
}

/// What a filter on [field] is called where it is shown on its own, as a
/// chip over the grid.
String facetLabel(String field) => switch (field) {
  'model' => 'Model',
  'lora' => 'LoRA',
  'collection' => 'Collection',
  'fullprompt' => 'Prompt',
  'prompt' => 'Word',
  'sampler' => 'Sampler',
  'scheduler' => 'Scheduler',
  'steps' => 'Steps',
  'cfg' => 'CFG',
  'size' => 'Size',
  'source' => 'Made with',
  _ => field,
};
