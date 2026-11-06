/// Wildcards in Remix: the bar under the prompts that says what the
/// choices make and how they are picked, and the word lists' own panel.
library;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/wildcards.dart';
import '../theme.dart';
import 'sheet.dart';

/// The most pictures "Every combination" queues at once.
const int maxEveryCombination = 64;

/// How the choices in a prompt are picked for each picture.
enum WildcardMode {
  /// Each picture picks at random.
  random,

  /// One picture of each combination, in order.
  every,
}

/// Under the prompts when they hold `{a|b}` choices or `__lists__`: how
/// many prompts they make, whether each picture picks at random or one of
/// every combination is made, a few of the prompts they make, and the way
/// to the word lists. Shows nothing when there is nothing to choose.
class WildcardBar extends StatelessWidget {
  const WildcardBar({
    super.key,
    required this.state,
    required this.prompt,
    required this.negative,
    required this.mode,
    required this.onMode,
    this.seed = 0,
  });
  final AppState state;
  final TextEditingController prompt;
  final TextEditingController negative;
  final WildcardMode mode;
  final ValueChanged<WildcardMode> onMode;

  /// What the preview's random picks start from.
  final int seed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([state, prompt, negative]),
      builder: (context, _) {
        final lists = state.wordLists;
        final p = WildcardPrompt.parse(prompt.text, lists);
        final n = WildcardPrompt.parse(negative.text, lists);
        final missing = {...p.missingLists, ...n.missingLists}.toList();
        if (!p.hasChoices && !n.hasChoices && missing.isEmpty) return const SizedBox.shrink();
        final total = wildcardCombinations(p, n);
        final choices = p.choiceCount + n.choiceCount;
        final named = {...p.listNames, ...n.listNames}.length - missing.length;
        final summary = [
          if (choices > 0) choices == 1 ? '1 choice' : '$choices choices',
          if (named > 0) named == 1 ? '1 word list' : '$named word lists',
        ].join(', ');
        final preview = mode == WildcardMode.every ? p.every(limit: 3) : p.expand(3, all: false, seed: seed);
        return Container(
          key: const ValueKey<String>('wildcard-bar'),
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 10),
          decoration: BoxDecoration(color: Palette.raised, borderRadius: BorderRadius.circular(8)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.shuffle, size: 16, color: Palette.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'Wildcards', style: TextStyle(fontWeight: FontWeight.w600)),
                          if (summary.isNotEmpty) TextSpan(text: '  $summary · ', style: const TextStyle(color: Palette.muted)),
                          if (total > 1)
                            TextSpan(
                              text: total >= (1 << 20) ? 'over a million prompts' : '${_thousands(total)} prompts',
                              style: const TextStyle(color: Palette.muted),
                            ),
                        ],
                      ),
                      key: const ValueKey<String>('wildcard-summary'),
                      style: const TextStyle(fontSize: 13),
                      maxLines: 2,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey<String>('wildcard-lists'),
                    onPressed: () => openWordLists(context, state),
                    child: const Text('Word lists…'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<WildcardMode>(
                  key: const ValueKey<String>('wildcard-mode'),
                  showSelectedIcon: false,
                  segments: [
                    const ButtonSegment(
                      value: WildcardMode.random,
                      icon: Icon(Icons.casino_outlined, size: 16),
                      label: Text('Random picks'),
                      tooltip: 'Each picture picks one option of every choice',
                    ),
                    ButtonSegment(
                      value: WildcardMode.every,
                      icon: const Icon(Icons.grid_view, size: 16),
                      label: Text(total > 1 && total <= maxEveryCombination ? 'Every one ($total)' : 'Every one'),
                      tooltip: 'One picture of each combination, in order',
                      enabled: total > 1,
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) => onMode(s.first),
                ),
              ),
              if (mode == WildcardMode.every && total > maxEveryCombination)
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 6),
                  child: Text(
                    'That is ${_thousands(total)} pictures. The first $maxEveryCombination are made; take an option out to make the rest.',
                    key: const ValueKey<String>('wildcard-too-many'),
                    style: const TextStyle(fontSize: 12, color: Color(0xFFF0A35E), height: 1.35),
                  ),
                ),
              for (final name in missing)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'There is no word list called “$name”, so __${name}__ is sent as written.',
                          style: const TextStyle(fontSize: 12, color: Palette.danger, height: 1.35),
                        ),
                      ),
                      TextButton(
                        key: ValueKey<String>('wildcard-make-$name'),
                        onPressed: () => editWordList(context, state, name: name, isNew: true),
                        child: const Text('Make it…'),
                      ),
                    ],
                  ),
                ),
              if (p.hasChoices) ...[
                const SizedBox(height: 8),
                Text(mode == WildcardMode.every ? 'The first prompts it makes' : 'Prompts it might make', style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
                const SizedBox(height: 2),
                for (final line in preview)
                  Padding(
                    padding: const EdgeInsets.only(top: 3, right: 6),
                    child: Text(
                      line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Palette.muted, height: 1.35),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// How many pictures "Every combination" of [prompt] and [negative] makes.
int wildcardCombinations(WildcardPrompt prompt, WildcardPrompt negative) {
  final a = prompt.combinations();
  final b = negative.combinations();
  final both = a * b;
  return both > (1 << 20) ? 1 << 20 : both;
}

String _thousands(int n) {
  final s = '$n';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

// ------------------------------------------------------------ word lists

/// The word lists: each with its words, to add to, change or delete.
Future<void> openWordLists(BuildContext context, AppState state) => showPanel<void>(
  context,
  title: 'Word lists',
  icon: Icons.format_list_bulleted,
  width: 560,
  builder: (context) => WordListsPanel(state: state),
);

class WordListsPanel extends StatelessWidget {
  const WordListsPanel({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final names = state.wordLists.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                children: [
                  const Text(
                    'Write __name__ in a prompt and each picture gets one line of that list.',
                    style: TextStyle(fontSize: 12.5, color: Palette.muted, height: 1.35),
                  ),
                  const SizedBox(height: 10),
                  if (names.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text('No word lists yet.', style: TextStyle(color: Palette.faint)),
                    ),
                  for (final name in names)
                    _ListRow(
                      key: ValueKey<String>('word-list-$name'),
                      name: name,
                      words: state.wordLists[name]!,
                      onTap: () => editWordList(context, state, name: name),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: EdgeInsets.fromLTRB(18, 10, 18, 12 + MediaQuery.paddingOf(context).bottom),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Kept with your presets, not in a picture folder.', style: TextStyle(fontSize: 11.5, color: Palette.faint)),
                  ),
                  FilledButton.icon(
                    key: const ValueKey<String>('word-list-new'),
                    onPressed: () => editWordList(context, state, name: '', isNew: true),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New list'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({super.key, required this.name, required this.words, required this.onTap});
  final String name;
  final List<String> words;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('__${name}__', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Palette.accent)),
                  const SizedBox(height: 2),
                  Text(
                    words.take(6).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Palette.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(words.length == 1 ? '1 line' : '${words.length} lines', style: const TextStyle(fontSize: 12, color: Palette.faint, fontFeatures: [FontFeature.tabularFigures()])),
            const Icon(Icons.chevron_right, size: 18, color: Palette.faint),
          ],
        ),
      ),
    );
  }
}

/// Make the word list [name] or change it: its name, and one line per
/// option (lines pasted from a wildcard .txt file work as they are).
Future<void> editWordList(BuildContext context, AppState state, {required String name, bool isNew = false}) => showPanel<void>(
  context,
  title: isNew ? 'New word list' : 'Word list',
  icon: Icons.format_list_bulleted,
  width: 520,
  builder: (context) => _WordListEditor(state: state, name: name, isNew: isNew),
);

class _WordListEditor extends StatefulWidget {
  const _WordListEditor({required this.state, required this.name, required this.isNew});
  final AppState state;
  final String name;
  final bool isNew;

  @override
  State<_WordListEditor> createState() => _WordListEditorState();
}

class _WordListEditorState extends State<_WordListEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late final TextEditingController _words = TextEditingController(text: (widget.state.wordLists[widget.name] ?? const []).join('\n'));

  @override
  void dispose() {
    _name.dispose();
    _words.dispose();
    super.dispose();
  }

  String get _cleanName => _name.text.trim().replaceAll(RegExp(r'\s+'), '_');

  String? get _problem {
    final n = _cleanName;
    if (n.isEmpty) return 'Give it a name';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_\-/]*$').hasMatch(n)) return 'Use letters, numbers, - and _';
    final taken = widget.state.wordLists.keys.any((k) => k.toLowerCase() == n.toLowerCase() && k != widget.name);
    if (taken) return 'There is already a list called $n';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final lines = wordListFromText(_words.text).length;
    final problem = _problem;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey<String>('word-list-name'),
                  controller: _name,
                  autofocus: widget.name.isEmpty,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Name',
                    helperText: problem ?? 'Used in a prompt as __${_cleanName}__',
                    helperStyle: TextStyle(color: problem == null ? Palette.faint : Palette.danger),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey<String>('word-list-words'),
                  controller: _words,
                  minLines: 8,
                  maxLines: 16,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'One option per line',
                    alignLabelWithHint: true,
                    helperText: '$lines ${lines == 1 ? 'line' : 'lines'}. Blank lines and lines starting with # are left out.',
                    helperStyle: const TextStyle(color: Palette.faint),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: EdgeInsets.fromLTRB(18, 10, 18, 12 + MediaQuery.paddingOf(context).bottom),
          child: Row(
            children: [
              if (!widget.isNew)
                TextButton(
                  key: const ValueKey<String>('word-list-delete'),
                  style: TextButton.styleFrom(foregroundColor: Palette.danger),
                  onPressed: () {
                    widget.state.deleteWordList(widget.name);
                    Navigator.of(context).pop();
                  },
                  child: const Text('Delete'),
                ),
              const Spacer(),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey<String>('word-list-save'),
                onPressed: problem != null || lines == 0
                    ? null
                    : () {
                        widget.state.saveWordList(_cleanName, wordListFromText(_words.text), was: widget.isNew ? null : widget.name);
                        Navigator.of(context).pop();
                      },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
