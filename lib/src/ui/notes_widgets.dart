import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'sheet.dart';

const Color keepColor = Color(0xFF7BC88F);
const Color starColor = Color(0xFFF0C25E);

/// Five stars to tap: a star sets that many, the same star again clears.
/// Each star is a full finger's width.
class StarRating extends StatelessWidget {
  const StarRating({super.key, required this.value, required this.onChanged, this.size = 22});
  final int value;
  final ValueChanged<int> onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Rating: $value of 5',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var n = 1; n <= 5; n++)
            Tooltip(
              message: value == n ? 'Clear the rating ($n)' : 'Rate $n ($n)',
              child: InkResponse(
                key: ValueKey<String>('star-$n'),
                radius: size,
                onTap: () => onChanged(value == n ? 0 : n),
                child: SizedBox(
                  width: size + 14,
                  height: size + 18,
                  child: Icon(
                    n <= value ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: size,
                    color: n <= value ? starColor : Palette.faint,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Keep and reject, as two toggles.
class FlagButtons extends StatelessWidget {
  const FlagButtons({super.key, required this.flag, required this.onChanged});
  final Flag flag;
  final ValueChanged<Flag> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget button(Flag mine, IconData on, IconData off, Color color, String tip) {
      final active = flag == mine;
      return Tooltip(
        message: active ? 'Clear the flag ($tip)' : '${mine.label} ($tip)',
        child: InkResponse(
          key: ValueKey<String>('flag-${mine.word}'),
          radius: 20,
          onTap: () => onChanged(active ? Flag.none : mine),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(active ? on : off, size: 22, color: active ? color : Palette.faint),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(Flag.keep, Icons.check_circle, Icons.check_circle_outline, keepColor, 'P'),
        button(Flag.reject, Icons.cancel, Icons.cancel_outlined, Palette.danger, 'X'),
      ],
    );
  }
}

/// Stars, flag and collections for one picture, as the metadata panel shows
/// them. Changes are saved beside the picture at once.
class NotesBar extends StatefulWidget {
  const NotesBar({super.key, required this.state, required this.item});
  final AppState state;
  final MediaItem item;

  @override
  State<NotesBar> createState() => _NotesBarState();
}

class _NotesBarState extends State<NotesBar> {
  Note _note = Note.empty;
  String? _loadedFor;

  @override
  void initState() {
    super.initState();
    widget.state.notesTick.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(NotesBar old) {
    super.didUpdateWidget(old);
    if (old.item.path != widget.item.path) _load();
  }

  @override
  void dispose() {
    widget.state.notesTick.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final path = widget.item.path;
    try {
      final note = await widget.state.notes(widget.item);
      if (!mounted || widget.item.path != path) return;
      setState(() {
        _note = note;
        _loadedFor = path;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    // Until the file has been read, the grid's copy of the stars and flag.
    final note = _loadedFor == widget.item.path
        ? _note
        : Note(rating: widget.item.rating, flag: widget.item.flag);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            StarRating(
              value: note.rating,
              onChanged: (n) => state.changeNotes(targets: [widget.item], rating: n),
            ),
            FlagButtons(
              flag: note.flag,
              onChanged: (f) => state.changeNotes(targets: [widget.item], flag: f),
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final name in note.collections)
              InputChip(
                label: Text(name, style: const TextStyle(fontSize: 12)),
                avatar: const Icon(Icons.collections_bookmark_outlined, size: 15),
                tooltip: 'Show the pictures in $name',
                visualDensity: VisualDensity.compact,
                backgroundColor: Palette.raised,
                side: const BorderSide(color: Palette.line),
                onPressed: () => state.applyFilter(exactTerm('collection', name)),
                deleteButtonTooltipMessage: 'Take it out of $name',
                onDeleted: () => state.changeNotes(targets: [widget.item], remove: [name]),
              ),
            ActionChip(
              key: const ValueKey<String>('add-to-collection'),
              avatar: const Icon(Icons.add, size: 16),
              label: Text(note.collections.isEmpty ? 'Add to collection' : 'Add', style: const TextStyle(fontSize: 12)),
              tooltip: 'Add to a collection (B)',
              visualDensity: VisualDensity.compact,
              backgroundColor: Palette.raised,
              side: const BorderSide(color: Palette.line),
              onPressed: () => showCollectionPicker(context, state, [widget.item]),
            ),
          ],
        ),
      ],
    );
  }
}

/// Choose the collections [items] are in: tick existing ones, or type a
/// new name.
Future<void> showCollectionPicker(BuildContext context, AppState state, List<MediaItem> items) async {
  if (items.isEmpty) return;
  final note = items.length == 1 ? await state.notes(items.first) : Note.empty;
  final known = await state.collections();
  if (!context.mounted) return;
  await showPanel<void>(
    context,
    title: items.length == 1 ? 'Collections' : 'Collections for ${items.length} pictures',
    icon: Icons.collections_bookmark_outlined,
    width: 420,
    builder: (context) => _CollectionPicker(state: state, items: items, initial: note.collections, known: known),
  );
}

class _CollectionPicker extends StatefulWidget {
  const _CollectionPicker({required this.state, required this.items, required this.initial, required this.known});
  final AppState state;
  final List<MediaItem> items;
  final List<String> initial;
  final List<(String, int)> known;

  @override
  State<_CollectionPicker> createState() => _CollectionPickerState();
}

class _CollectionPickerState extends State<_CollectionPicker> {
  final TextEditingController _name = TextEditingController();
  late final Set<String> _in = {for (final c in widget.initial) c.toLowerCase()};
  late final List<String> _names = [
    for (final (name, _) in widget.known) name,
    for (final c in widget.initial)
      if (!widget.known.any((k) => k.$1.toLowerCase() == c.toLowerCase())) c,
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _toggle(String name) async {
    final on = !_in.contains(name.toLowerCase());
    setState(() {
      if (on) {
        _in.add(name.toLowerCase());
      } else {
        _in.remove(name.toLowerCase());
      }
    });
    await widget.state.changeNotes(targets: widget.items, add: on ? [name] : const [], remove: on ? const [] : [name]);
  }

  Future<void> _create() async {
    final name = _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty) return;
    _name.clear();
    if (!_names.any((n) => n.toLowerCase() == name.toLowerCase())) {
      setState(() => _names.insert(0, name));
    }
    if (!_in.contains(name.toLowerCase())) await _toggle(name);
  }

  @override
  Widget build(BuildContext context) {
    final count = {for (final (n, c) in widget.known) n.toLowerCase(): c};
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey<String>('new-collection'),
            controller: _name,
            autofocus: true,
            onSubmitted: (_) => _create(),
            decoration: InputDecoration(
              hintText: 'New collection',
              isDense: true,
              filled: true,
              fillColor: Palette.raised,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
              suffixIcon: IconButton(tooltip: 'Add', icon: const Icon(Icons.add), onPressed: _create),
            ),
          ),
          const SizedBox(height: 10),
          if (_names.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Collections group pictures across prompts and folders. They are '
                'saved in a small .generativeview.json file in each picture\'s '
                'folder, so they travel with the folder.',
                style: TextStyle(fontSize: 12.5, color: Palette.muted, height: 1.4),
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final name in _names)
                  CheckboxListTile(
                    dense: true,
                    value: _in.contains(name.toLowerCase()),
                    onChanged: (_) => _toggle(name),
                    title: Text(name, style: const TextStyle(fontSize: 13.5)),
                    secondary: Text('${count[name.toLowerCase()] ?? 0}', style: const TextStyle(fontSize: 12, color: Palette.faint)),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The marks on a grid tile: stars along the bottom, the flag in a corner.
class TileMarks extends StatelessWidget {
  const TileMarks({super.key, required this.rating, required this.flag, required this.compact});
  final int rating;
  final Flag flag;

  /// Small tiles get a number instead of a row of stars.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (rating > 0)
          Align(
            alignment: Alignment.bottomLeft,
            child: Container(
              margin: const EdgeInsets.all(5),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(4)),
              child: compact
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.star_rounded, size: 12, color: starColor),
                        Text('$rating', style: const TextStyle(color: Colors.white, fontSize: 11, height: 1.2)),
                      ],
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [for (var i = 0; i < rating; i++) const Icon(Icons.star_rounded, size: 12, color: starColor)],
                    ),
            ),
          ),
        if (flag != Flag.none)
          Align(
            alignment: Alignment.topRight,
            child: Container(
              margin: const EdgeInsets.all(5),
              decoration: const BoxDecoration(color: Color(0xB3000000), shape: BoxShape.circle),
              padding: const EdgeInsets.all(2),
              child: Icon(
                flag == Flag.keep ? Icons.check_circle : Icons.cancel,
                size: 16,
                color: flag == Flag.keep ? keepColor : Palette.danger,
              ),
            ),
          ),
      ],
    );
  }
}
