import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'notes_widgets.dart' show starColor;
import 'thumb_image.dart';

/// Open the usage page over the grid.
///
/// The page covers the window but the route is not opaque, so the grid under
/// it stays laid out: it is back the instant the page goes, already showing
/// whatever was tapped here.
void openStats(BuildContext context, AppState state) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 140),
      reverseTransitionDuration: const Duration(milliseconds: 100),
      pageBuilder: (_, _, _) => StatsPage(state: state),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// How many values a card lists before "Show all".
const int _shortList = 10;

const TextStyle _heading = TextStyle(
  fontSize: 10.5,
  letterSpacing: 0.9,
  fontWeight: FontWeight.w600,
  color: Palette.faint,
);

String _count(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// What the current folder's images were made with: the models, LoRAs,
/// settings and prompt words used most, and when the images were made.
/// Tapping anything goes back to the grid showing only the images behind
/// that number.
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.state});
  final AppState state;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  UsageStats? _stats;
  Object? _error;

  /// Most used, or best rated first.
  bool _rated = false;

  @override
  void initState() {
    super.initState();
    widget.state.usage().then(
      (stats) {
        if (mounted) setState(() => _stats = stats);
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e);
      },
    );
  }

  void _close() => Navigator.of(context).maybePop();

  /// Back to the grid, showing only what [query] finds.
  void _show(String query) {
    Navigator.of(context).pop();
    widget.state.applyFilter(query);
  }

  @override
  Widget build(BuildContext context) {
    final folder = widget.state.folder ?? '';
    final name = folder == '/' ? '/' : folder.split('/').last;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Palette.canvas,
          body: SafeArea(
            child: Column(
              children: [
                Container(
                  height: 48,
                  decoration: const BoxDecoration(
                    color: Palette.panel,
                    border: Border(bottom: BorderSide(color: Palette.line)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      Tooltip(
                        message: 'Back to the grid (Esc)',
                        child: InkWell(
                          onTap: _close,
                          borderRadius: BorderRadius.circular(6),
                          hoverColor: Palette.hover,
                          child: const SizedBox(
                            width: 36,
                            height: 36,
                            child: Icon(
                              Icons.arrow_back,
                              size: 19,
                              color: Palette.muted,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'Usage',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Palette.text,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Palette.muted,
                          ),
                        ),
                      ),
                      SegmentedButton<bool>(
                        key: const ValueKey<String>('usage-mode'),
                        showSelectedIcon: false,
                        style: const ButtonStyle(visualDensity: VisualDensity.compact),
                        segments: const [
                          ButtonSegment(value: false, label: Text('Most used'), icon: Icon(Icons.bar_chart, size: 16)),
                          ButtonSegment(value: true, label: Text('Best rated'), icon: Icon(Icons.star_outline_rounded, size: 16)),
                        ],
                        selected: {_rated},
                        onSelectionChanged: (s) => setState(() => _rated = s.first),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
                Expanded(child: _body()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return _Message('Could not count this folder.\n$_error');
    }
    final stats = _stats;
    if (stats == null) return const SizedBox.expand();
    if (stats.total == 0) {
      return const _Message('There are no images in this folder to count.');
    }
    if (_rated) return _Leaderboard(state: widget.state, stats: stats, onShow: _show);
    final groups = [
      for (final group in stats.groups)
        if (group.items.isNotEmpty) group,
    ];
    final spread = stats.timeline.length > 1;
    final scope = widget.state.recursive
        ? 'sub-folders included'
        : 'sub-folders not included';
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 1180
            ? 3
            : box.maxWidth >= 720
            ? 2
            : 1;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Text(
              [
                _count(stats.total, 'image', 'images'),
                '${stats.generated} with generation data',
                scope,
              ].join('  ·  '),
              style: const TextStyle(fontSize: 13, color: Palette.muted),
            ),
            const SizedBox(height: 4),
            const Text(
              'Tap anything to see only the images behind it.',
              style: TextStyle(fontSize: 12, color: Palette.faint),
            ),
            if (stats.timeline.isNotEmpty) ...[
              const SizedBox(height: 18),
              _Timeline(stats: stats, onShow: _show),
            ],
            const SizedBox(height: 18),
            _Columns(
              count: columns,
              cards: [
                for (final group in groups)
                  _GroupCard(group: group, showTrend: spread, onShow: _show),
              ],
              weights: [
                for (final group in groups)
                  2 + math.min(group.items.length, _shortList),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Palette.muted,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

/// Cards in [count] columns, each card going to whichever column is
/// shortest so far ([weights] say roughly how tall each card is).
class _Columns extends StatelessWidget {
  const _Columns({
    required this.count,
    required this.cards,
    required this.weights,
  });
  final int count;
  final List<Widget> cards;
  final List<int> weights;

  @override
  Widget build(BuildContext context) {
    final columns = List.generate(count, (_) => <Widget>[]);
    final heights = List.filled(count, 0);
    for (final (index, card) in cards.indexed) {
      var shortest = 0;
      for (var c = 1; c < count; c++) {
        if (heights[c] < heights[shortest]) shortest = c;
      }
      if (columns[shortest].isNotEmpty) {
        columns[shortest].add(const SizedBox(height: 14));
      }
      columns[shortest].add(card);
      heights[shortest] += weights[index];
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, column) in columns.indexed) ...[
          if (index > 0) const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: column,
            ),
          ),
        ],
      ],
    );
  }
}

/// When the images were made: a bar per day, week, month or year.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.stats, required this.onShow});
  final UsageStats stats;
  final ValueChanged<String> onShow;

  String _describe(TimeBucket bucket) {
    final when = stats.unit == 'week' ? 'Week of ${bucket.label}' : bucket.label;
    return '$when  ·  ${_count(bucket.count, 'image', 'images')}';
  }

  @override
  Widget build(BuildContext context) {
    final bars = stats.timeline;
    final peak = bars.fold<int>(1, (most, b) => math.max(most, b.count));
    final gap = bars.length > 40 ? 0.5 : 1.5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('IMAGES PER ${stats.unit.toUpperCase()}', style: _heading),
        const SizedBox(height: 8),
        SizedBox(
          height: 96,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final bar in bars)
                Expanded(
                  child: Tooltip(
                    message: _describe(bar),
                    waitDuration: const Duration(milliseconds: 150),
                    child: InkWell(
                      onTap: bar.count == 0 ? null : () => onShow(bar.query),
                      hoverColor: Palette.hover,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          widthFactor: 1,
                          // Even one image shows as a sliver.
                          heightFactor: bar.count == 0
                              ? 0
                              : math.max(bar.count / peak, 0.03),
                          child: Container(
                            margin: EdgeInsets.symmetric(horizontal: gap),
                            decoration: BoxDecoration(
                              color: Palette.accent.withValues(alpha: 0.75),
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              bars.first.label,
              style: const TextStyle(fontSize: 11, color: Palette.faint),
            ),
            const Spacer(),
            if (bars.length > 1)
              Text(
                bars.last.label,
                style: const TextStyle(fontSize: 11, color: Palette.faint),
              ),
          ],
        ),
      ],
    );
  }
}

/// The values of one kind, most used first.
class _GroupCard extends StatefulWidget {
  const _GroupCard({
    required this.group,
    required this.showTrend,
    required this.onShow,
  });
  final UsageGroup group;

  /// Whether the folder spans enough time for a trend to mean anything.
  final bool showTrend;
  final ValueChanged<String> onShow;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final items = _all ? group.items : group.items.take(_shortList).toList();
    final peak = group.items.isEmpty ? 1 : group.items.first.count;
    final unlisted = group.distinct - group.items.length;
    return Container(
      decoration: BoxDecoration(
        color: Palette.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.line),
      ),
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(group.title.toUpperCase(), style: _heading),
                ),
                Text(
                  '${group.distinct}',
                  style: const TextStyle(fontSize: 11.5, color: Palette.faint),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          for (final item in items)
            _UsageRow(
              label: group.label(item),
              detail: item.role.isEmpty ? '' : GenInfo.kindLabel(item.role),
              count: item.count,
              share: item.count / math.max(peak, 1),
              trend: widget.showTrend ? item.trend : const [],
              onTap: () => widget.onShow(group.queryFor(item)),
            ),
          if (group.items.length > _shortList)
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => setState(() => _all = !_all),
                borderRadius: BorderRadius.circular(5),
                hoverColor: Palette.hover,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: Text(
                    _all ? 'Show fewer' : 'Show all ${group.items.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Palette.accent,
                    ),
                  ),
                ),
              ),
            ),
          if (_all && unlisted > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
              child: Text(
                'and $unlisted more, each used less',
                style: const TextStyle(fontSize: 12, color: Palette.faint),
              ),
            ),
        ],
      ),
    );
  }
}

/// One value: its name over a bar as long as its share of the most used,
/// how its use is spread over time, and how many images use it.
class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.label,
    required this.detail,
    required this.count,
    required this.share,
    required this.trend,
    required this.onTap,
  });
  final String label;
  final String detail;
  final int count;
  final double share;
  final List<int> trend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        hoverColor: Palette.hover,
        child: Stack(
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: share.clamp(0.0, 1.0).toDouble(),
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Palette.accent.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.3,
                              color: Palette.text,
                            ),
                          ),
                        ),
                        if (detail.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          Text(
                            detail,
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Palette.faint,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trend.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    CustomPaint(
                      size: const Size(48, 14),
                      painter: _TrendPainter(trend),
                    ),
                  ],
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 30),
                    child: Text(
                      '$count',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Palette.muted,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A row's use over the folder's time span, oldest on the left.
class _TrendPainter extends CustomPainter {
  const _TrendPainter(this.values);
  final List<int> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final peak = values.fold<int>(1, math.max);
    final slot = size.width / values.length;
    final floor = Paint()..color = Palette.line;
    final bar = Paint()..color = Palette.muted;
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - 1, size.width, 1),
      floor,
    );
    for (final (index, value) in values.indexed) {
      if (value <= 0) continue;
      final height = math.max(2.0, value / peak * size.height);
      canvas.drawRect(
        Rect.fromLTWH(
          index * slot,
          size.height - height,
          math.max(slot - 0.5, 1.0),
          height,
        ),
        bar,
      );
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.values != values;
}

/// Which models and LoRAs make the pictures rated best: by their average
/// stars, with how many are rated and kept, and their best few pictures.
class _Leaderboard extends StatelessWidget {
  const _Leaderboard({required this.state, required this.stats, required this.onShow});
  final AppState state;
  final UsageStats stats;
  final ValueChanged<String> onShow;

  @override
  Widget build(BuildContext context) {
    final groups = [
      for (final g in stats.groups)
        if (const {'model', 'lora', 'aux'}.contains(g.kind)) g,
    ];
    final ranked = [
      for (final g in groups)
        (
          g,
          [
            for (final i in g.items)
              if (i.rated > 0) i,
          ]..sort((a, b) {
              final byAverage = b.averageRating.compareTo(a.averageRating);
              return byAverage != 0 ? byAverage : b.rated.compareTo(a.rated);
            }),
        ),
    ].where((e) => e.$2.isNotEmpty).toList();
    if (ranked.isEmpty) {
      return const _Message(
        'Nothing here is rated yet.\nRate pictures with 1 to 5 (or the stars in the metadata panel) '
        'to see which models and LoRAs make your best ones.',
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 1100 ? 2 : 1;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            const Text(
              'Ranked by the average rating of their rated pictures. Tap one to see its pictures.',
              style: TextStyle(fontSize: 12, color: Palette.faint),
            ),
            const SizedBox(height: 14),
            _Columns(
              count: columns,
              weights: [for (final (_, items) in ranked) 2 + math.min(items.length, _shortList) * 2],
              cards: [
                for (final (group, items) in ranked)
                  Container(
                    decoration: BoxDecoration(
                      color: Palette.panel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Palette.line),
                    ),
                    padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(group.title.toUpperCase(), style: _heading),
                        ),
                        const SizedBox(height: 6),
                        for (final (rank, item) in items.take(_shortList).indexed)
                          _RankedRow(
                            state: state,
                            rank: rank + 1,
                            label: group.label(item),
                            item: item,
                            onTap: () => onShow(group.queryFor(item)),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _RankedRow extends StatelessWidget {
  const _RankedRow({required this.state, required this.rank, required this.label, required this.item, required this.onTap});
  final AppState state;
  final int rank;
  final String label;
  final UsageItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final detail = [
      '${item.rated} of ${item.count} rated',
      if (item.keeps > 0) '${item.keeps} kept',
      if (item.rejects > 0) '${item.rejects} rejected',
    ].join('  ·  ');
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        hoverColor: Palette.hover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: Text('$rank', style: const TextStyle(fontSize: 12.5, color: Palette.faint)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Palette.text)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded, size: 14, color: starColor),
                        const SizedBox(width: 2),
                        Text(
                          item.averageRating.toStringAsFixed(1),
                          style: const TextStyle(fontSize: 12.5, color: Palette.text, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              for (final sample in item.samples)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 46,
                      height: 46,
                      child: ColoredBox(
                        color: Palette.tile,
                        child: ThumbImage(cache: state.thumbs, item: sample.item, tier: 0, fit: BoxFit.cover),
                      ),
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
