import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'sheet.dart';
import 'thumb_image.dart';

/// What a rule can be about, the search field it writes, and the ways it
/// can match.
enum SmartField {
  model('Model', 'model', [SmartOp.isOne, SmartOp.contains, SmartOp.isNot]),
  lora('LoRA', 'lora', [SmartOp.isOne, SmartOp.contains, SmartOp.isNot]),
  collection('Collection', 'collection', [SmartOp.isOne, SmartOp.isNot]),
  word('Prompt word', 'prompt', [SmartOp.has, SmartOp.lacks]),
  prompt('Whole prompt', 'fullprompt', [SmartOp.isOne, SmartOp.isNot]),
  rating('Rating', 'rating', [SmartOp.atLeast, SmartOp.exactly, SmartOp.atMost, SmartOp.unrated]),
  flag('Flag', 'flag', [SmartOp.isOne, SmartOp.isNot]),
  sampler('Sampler', 'sampler', [SmartOp.isOne, SmartOp.contains, SmartOp.isNot]),
  scheduler('Scheduler', 'scheduler', [SmartOp.isOne, SmartOp.contains, SmartOp.isNot]),
  steps('Steps', 'steps', [SmartOp.isOne, SmartOp.isNot]),
  cfg('CFG', 'cfg', [SmartOp.isOne, SmartOp.isNot]),
  size('Size', 'size', [SmartOp.isOne, SmartOp.isNot]),
  source('Made with', 'source', [SmartOp.isOne, SmartOp.isNot]),
  date('Date', 'date', [SmartOp.isOne, SmartOp.isNot]),
  text('Search text', '', [SmartOp.matches]);

  const SmartField(this.label, this.term, this.ops);
  final String label;

  /// The search field it writes (`model`), or empty for text as typed.
  final String term;
  final List<SmartOp> ops;

  static SmartField? byTerm(String term) {
    for (final f in values) {
      if (f.term.isNotEmpty && f.term == term) return f;
    }
    return null;
  }
}

enum SmartOp {
  isOne('is'),
  isNot('is not'),
  contains('contains'),
  has('has'),
  lacks('doesn’t have'),
  atLeast('at least'),
  exactly('exactly'),
  atMost('at most'),
  unrated('not rated'),
  matches('matches');

  const SmartOp(this.label);
  final String label;
}

/// One line of a smart collection: a field, how it matches, and a value.
class SmartRule {
  SmartRule(this.field, this.op, [this.value = '']);
  SmartField field;
  SmartOp op;
  String value;

  /// Whether the value is one of a few, chosen rather than typed.
  List<(String, String)>? get choices => switch (field) {
    SmartField.rating => [for (var n = 1; n <= 5; n++) ('$n', n == 1 ? '1 star' : '$n stars')],
    SmartField.flag => const [('keep', 'Keep'), ('reject', 'Reject'), ('none', 'Not flagged')],
    _ => null,
  };

  bool get needsValue => op != SmartOp.unrated;

  /// The search term this rule writes; empty while it has no value.
  String toTerm() {
    final v = value.trim();
    if (op == SmartOp.unrated) return 'rating:none';
    if (v.isEmpty) return '';
    final f = field.term;
    String quoted(String s) => s.contains(RegExp(r'\s')) ? '"${s.replaceAll('"', '')}"' : s.replaceAll('"', '');
    // These match a value whole already, written the way the search box
    // and the filter panel write them.
    final whole = _plain.contains(field) ? '$f:${quoted(v)}' : exactTerm(f, v);
    return switch (op) {
      SmartOp.isOne => whole,
      SmartOp.isNot => '-$whole',
      SmartOp.contains || SmartOp.has => '$f:${quoted(v)}',
      SmartOp.lacks => '-$f:${quoted(v)}',
      SmartOp.atLeast => 'rating:>=$v',
      SmartOp.exactly => 'rating:$v',
      SmartOp.atMost => 'rating:<${(int.tryParse(v) ?? 5) + 1}',
      SmartOp.unrated => 'rating:none',
      SmartOp.matches => v,
    };
  }

  static const Set<SmartField> _plain = {
    SmartField.flag,
    SmartField.steps,
    SmartField.cfg,
    SmartField.size,
    SmartField.source,
    SmartField.date,
  };

  /// The rules a search is made of, one per term. A term no rule can say
  /// stays as search text, exactly as typed.
  static List<SmartRule> parse(String query) {
    final rules = <SmartRule>[];
    for (final raw in splitTerms(query)) {
      rules.add(_fromTerm(raw));
    }
    return rules;
  }

  static SmartRule _fromTerm(String raw) {
    final t = parseTerm(raw);
    final field = SmartField.byTerm(t.field);
    final asText = SmartRule(SmartField.text, SmartOp.matches, raw);
    if (field == null) return asText;
    if (field == SmartField.rating) {
      if (t.negate) return asText;
      final v = t.value.trim();
      if (v == 'none') return SmartRule(field, SmartOp.unrated);
      final at = RegExp(r'^(?:>=([1-5])|([1-5])\+)$').firstMatch(v);
      if (at != null) return SmartRule(field, SmartOp.atLeast, at.group(1) ?? at.group(2)!);
      final below = RegExp(r'^<([2-6])$').firstMatch(v);
      if (below != null) return SmartRule(field, SmartOp.atMost, '${int.parse(below.group(1)!) - 1}');
      if (RegExp(r'^[1-5]$').hasMatch(v)) return SmartRule(field, SmartOp.exactly, v);
      return asText;
    }
    if (field == SmartField.flag) {
      final v = t.value.trim().toLowerCase();
      if (!const {'keep', 'reject', 'none'}.contains(v)) return asText;
      return SmartRule(field, t.negate ? SmartOp.isNot : SmartOp.isOne, v);
    }
    if (field == SmartField.word) {
      return SmartRule(field, t.negate ? SmartOp.lacks : SmartOp.has, t.value);
    }
    final exact = t.exact || _plain.contains(field);
    if (!exact && !field.ops.contains(SmartOp.contains)) return asText;
    if (t.negate) return exact ? SmartRule(field, SmartOp.isNot, t.value) : asText;
    return SmartRule(field, exact ? SmartOp.isOne : SmartOp.contains, t.value);
  }

  /// The search the rules make together: every one has to match.
  static String query(List<SmartRule> rules) => [
    for (final r in rules) r.toTerm(),
  ].where((t) => t.isNotEmpty).join(' ');
}

/// Make a smart collection from [query] (the search showing, say), or
/// change [existing]. It is saved in the notes file of the open folder (an
/// existing one stays where it is), so it travels with the folder.
Future<void> openSmartEditor(
  BuildContext context,
  AppState state, {
  SmartCollection? existing,
  String query = '',
}) {
  return showPanel<void>(
    context,
    title: existing == null ? 'New smart collection' : 'Edit smart collection',
    icon: Icons.auto_awesome_motion_outlined,
    width: 680,
    builder: (context) => SmartEditor(state: state, existing: existing, query: query),
  );
}

class SmartEditor extends StatefulWidget {
  const SmartEditor({super.key, required this.state, this.existing, this.query = ''});
  final AppState state;
  final SmartCollection? existing;
  final String query;

  @override
  State<SmartEditor> createState() => _SmartEditorState();
}

class _SmartEditorState extends State<SmartEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? _suggestName());
  late final List<SmartRule> _rules = SmartRule.parse(widget.existing?.query ?? widget.query);
  final List<TextEditingController> _values = [];
  int? _count;
  List<MediaItem> _preview = const [];
  Timer? _previewTimer;
  String? _previewFor;
  bool _saving = false;
  String? _error;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    if (_rules.isEmpty) _rules.add(SmartRule(SmartField.rating, SmartOp.atLeast, '4'));
    for (final r in _rules) {
      _values.add(TextEditingController(text: r.value));
    }
    _refresh(now: true);
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _name.dispose();
    for (final c in _values) {
      c.dispose();
    }
    super.dispose();
  }

  /// A name from the first rule or two, to start from.
  String _suggestName() {
    final parts = <String>[];
    for (final r in SmartRule.parse(widget.query)) {
      final v = r.value.trim();
      if (r.op == SmartOp.isNot || r.op == SmartOp.lacks) continue;
      if (r.field == SmartField.rating) {
        parts.add(r.op == SmartOp.unrated ? 'Not rated' : '$v${r.op == SmartOp.atLeast ? '+' : ''} stars');
      } else if (v.isNotEmpty) {
        final short = v.replaceAll(RegExp(r'\.(safetensors|ckpt|pt|pth)$', caseSensitive: false), '');
        parts.add(short.length > 24 ? '${short.substring(0, 23)}…' : short);
      }
      if (parts.length == 2) break;
    }
    return parts.join(' · ');
  }

  String get _query => SmartRule.query(_rules);

  /// Count and preview what the rules match, shortly after the last change.
  void _refresh({bool now = false}) {
    _previewTimer?.cancel();
    _previewTimer = Timer(now ? Duration.zero : const Duration(milliseconds: 250), () async {
      final query = _query;
      if (query == _previewFor) return;
      _previewFor = query;
      if (query.isEmpty) {
        if (mounted) {
          setState(() {
            _count = 0;
            _preview = const [];
          });
        }
        return;
      }
      final count = await state.countMatches(query);
      final preview = await state.previewMatches(query);
      if (!mounted || _previewFor != query) return;
      setState(() {
        _count = count;
        _preview = preview;
      });
    });
  }

  void _changed() {
    setState(() => _error = null);
    _refresh();
  }

  void _setField(int i, SmartField field) {
    final rule = _rules[i];
    if (rule.field == field) return;
    rule.field = field;
    if (!field.ops.contains(rule.op)) rule.op = field.ops.first;
    final choices = rule.choices;
    if (choices != null && !choices.any((c) => c.$1 == rule.value)) {
      rule.value = choices.first.$1;
      _values[i].text = rule.value;
    }
    _changed();
  }

  void _add() {
    _rules.add(SmartRule(SmartField.model, SmartOp.isOne));
    _values.add(TextEditingController());
    _changed();
  }

  void _remove(int i) {
    _rules.removeAt(i);
    _values.removeAt(i).dispose();
    _changed();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final query = _query;
    String? problem;
    if (name.isEmpty) {
      problem = 'Give it a name.';
    } else if (query.isEmpty) {
      problem = 'Add a rule with a value.';
    } else if (state.smart.any(
      (s) => s.name.toLowerCase() == name.toLowerCase() && s.name.toLowerCase() != widget.existing?.name.toLowerCase(),
    )) {
      problem = 'There is already a smart collection called “$name”.';
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() => _saving = true);
    final existing = widget.existing;
    final wasShowing = existing != null && state.query.trim() == existing.query.trim();
    final ok = await state.saveSmartCollection(name: name, query: query, oldName: existing?.name, dir: existing?.dir);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _saving = false;
        _error = 'It could not be saved.';
      });
      return;
    }
    // Show what it matches: a new one at once, an edited one if it was
    // showing.
    if (existing == null || wasShowing) state.applyFilter(query);
    Navigator.of(context).maybePop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final yes = await confirmAction(
      context,
      title: 'Delete “${existing.name}”?',
      message: 'The smart collection goes away. The pictures it shows are not touched.',
      action: 'Delete',
    );
    if (!yes || !mounted) return;
    await state.deleteSmartCollection(existing);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 560;
    final where = _baseName(widget.existing?.dir ?? state.folder ?? '');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
            children: [
              TextField(
                key: const ValueKey<String>('smart-name'),
                controller: _name,
                autofocus: widget.existing == null,
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _save(),
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(labelText: 'Name', isDense: true),
              ),
              const PanelHeading('Pictures that match all of these'),
              for (var i = 0; i < _rules.length; i++) ...[
                _ruleRow(i, narrow),
                const SizedBox(height: 8),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey<String>('smart-add-rule'),
                  onPressed: _add,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add rule'),
                ),
              ),
              const SizedBox(height: 8),
              _previewBox(),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.sync, size: 15, color: Palette.faint),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Saved in $where’s notes file, so it goes wherever the folder is synced. It shows the pictures in view that match, in this folder and below.',
                      style: const TextStyle(fontSize: 12, height: 1.35, color: Palette.muted),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, key: const ValueKey<String>('smart-error'), style: const TextStyle(fontSize: 12.5, color: Palette.danger)),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
          child: Row(
            children: [
              if (widget.existing != null)
                TextButton(
                  key: const ValueKey<String>('smart-delete'),
                  style: TextButton.styleFrom(foregroundColor: Palette.danger),
                  onPressed: _saving ? null : _delete,
                  child: const Text('Delete'),
                ),
              const Spacer(),
              TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey<String>('smart-save'),
                onPressed: _saving ? null : _save,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _ruleRow(int i, bool narrow) {
    final rule = _rules[i];
    final field = _menu<SmartField>(
      key: ValueKey<String>('smart-field-$i'),
      value: rule.field,
      items: [for (final f in SmartField.values) (f, f.label)],
      onChanged: (f) => _setField(i, f),
    );
    final op = _menu<SmartOp>(
      key: ValueKey<String>('smart-op-$i'),
      value: rule.op,
      items: [for (final o in rule.field.ops) (o, o.label)],
      onChanged: (o) {
        rule.op = o;
        _changed();
      },
    );
    final choices = rule.choices;
    final Widget value;
    if (!rule.needsValue) {
      value = const SizedBox.shrink();
    } else if (choices != null) {
      value = _menu<String>(
        key: ValueKey<String>('smart-choice-$i'),
        value: choices.any((c) => c.$1 == rule.value) ? rule.value : choices.first.$1,
        items: choices,
        onChanged: (v) {
          rule.value = v;
          _values[i].text = v;
          _changed();
        },
      );
    } else {
      value = TextField(
        key: ValueKey<String>('smart-value-$i'),
        controller: _values[i],
        onChanged: (v) {
          rule.value = v;
          _changed();
        },
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13, color: Palette.text),
        decoration: InputDecoration(
          isDense: true,
          hintText: rule.field == SmartField.text ? 'as in the search box' : 'value',
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        ),
      );
    }
    final remove = IconButton(
      key: ValueKey<String>('smart-remove-$i'),
      tooltip: 'Remove rule',
      onPressed: _rules.length > 1 ? () => _remove(i) : null,
      icon: const Icon(Icons.remove_circle_outline, size: 20),
    );
    if (narrow) {
      // Field and match on one line, the value under them.
      return Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
        decoration: BoxDecoration(border: Border.all(color: Palette.line), borderRadius: BorderRadius.circular(8)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [Expanded(child: field), const SizedBox(width: 8), Expanded(child: op), remove]),
            if (rule.needsValue) Padding(padding: const EdgeInsets.only(top: 8, right: 8), child: value),
          ],
        ),
      );
    }
    return Row(
      children: [
        Expanded(flex: 4, child: field),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: op),
        const SizedBox(width: 8),
        Expanded(flex: 5, child: value),
        remove,
      ],
    );
  }

  Widget _menu<T>({
    required Key key,
    required T value,
    required List<(T, String)> items,
    required ValueChanged<T> onChanged,
  }) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: Palette.raised, border: Border.all(color: Palette.line), borderRadius: BorderRadius.circular(6)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          key: key,
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: Palette.raised,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13, color: Palette.text),
          iconSize: 18,
          items: [
            for (final (v, label) in items)
              DropdownMenuItem<T>(value: v, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  Widget _previewBox() {
    final count = _count;
    return Container(
      key: const ValueKey<String>('smart-preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Palette.canvas, border: Border.all(color: Palette.line), borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: count == null ? '…' : '$count',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Palette.text),
                ),
                TextSpan(
                  text: count == 1 ? ' picture here matches now' : ' pictures here match now',
                  style: const TextStyle(fontSize: 13, color: Palette.muted),
                ),
              ],
            ),
          ),
          if (_preview.isNotEmpty) ...[
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, box) {
                const gap = 6.0;
                final side = ((box.maxWidth - gap * 7) / 8).clamp(28.0, 72.0).toDouble();
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final item in _preview)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: SizedBox(
                          width: side,
                          height: side,
                          child: ColoredBox(
                            color: Palette.tile,
                            child: ThumbImage(cache: state.thumbs, item: item, tier: 0),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

String _baseName(String path) {
  final clean = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
  final cut = clean.lastIndexOf('/');
  final name = cut >= 0 ? clean.substring(cut + 1) : clean;
  return name.isEmpty ? 'this folder' : name;
}
