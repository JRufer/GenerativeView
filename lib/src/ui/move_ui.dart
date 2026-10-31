import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'sheet.dart';

/// "Move to…": pick a folder, then move [targets] there, with Undo.
Future<void> openMoveTo(BuildContext context, AppState state, List<MediaItem> targets) async {
  if (targets.isEmpty) return;
  final from = normalizePath(targets.first.dir);
  final dir = await showPanel<String>(
    context,
    title: targets.length == 1 ? 'Move ${targets.single.name} to…' : 'Move ${targets.length} files to…',
    icon: Icons.drive_file_move_outline,
    width: 460,
    builder: (context) => MovePicker(state: state, start: from),
  );
  if (dir == null || !context.mounted) return;
  await moveWithUndo(context, state, () => state.moveFiles(targets, dir));
}

/// Run a move and say how it went, with an Undo that puts the files back.
Future<void> moveWithUndo(BuildContext context, AppState state, Future<MoveOutcome> Function() run) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await run();
  if (messenger == null) return;
  final n = outcome.moved.length;
  final where = folderName(outcome.dir);
  final String message;
  if (n == 0 && outcome.failed.isEmpty) {
    message = 'Already in $where';
  } else if (n == 0) {
    message = outcome.failed.length == 1 ? 'Could not move: ${outcome.failed.single}' : 'Could not move ${outcome.failed.length} files: ${outcome.failed.first}';
  } else if (outcome.failed.isNotEmpty) {
    message = 'Moved $n to $where; ${outcome.failed.length} could not be moved: ${outcome.failed.first}';
  } else {
    message = n == 1 ? 'Moved ${fileName(outcome.moved.single.$2)} to $where' : 'Moved $n files to $where';
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 5),
        width: 360,
        action: n == 0
            ? null
            : SnackBarAction(
                key: const ValueKey<String>('undo-move'),
                label: 'Undo',
                onPressed: () async {
                  final back = await state.undoMove(outcome);
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(
                        content: Text(back.failed.isEmpty ? 'Moved back' : 'Could not move ${back.failed.length} back: ${back.failed.first}'),
                        duration: const Duration(milliseconds: 1600),
                        width: 260,
                      ),
                    );
                },
              ),
      ),
    );
}

/// The last part of a path.
String fileName(String path) => path.split(RegExp(r'[/\\]')).last;

/// A folder's own name, for messages ("/" and "C:/" are their own name).
String folderName(String dir) {
  final clean = dir.length > 1 && (dir.endsWith('/') || dir.endsWith(r'\')) ? dir.substring(0, dir.length - 1) : dir;
  final name = fileName(clean);
  return name.isEmpty ? dir : name;
}

/// Where to move to: folders moved to lately and pinned ones first, then a
/// browser that starts at the pictures' own folder, with a way to make a
/// new folder there. Pops with the chosen folder.
class MovePicker extends StatefulWidget {
  const MovePicker({super.key, required this.state, required this.start});
  final AppState state;

  /// The folder the pictures are in now.
  final String start;

  @override
  State<MovePicker> createState() => _MovePickerState();
}

class _MovePickerState extends State<MovePicker> {
  late String _at = widget.start;
  List<DirNode>? _folders;
  final TextEditingController _newName = TextEditingController();
  bool _naming = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open(_at);
  }

  @override
  void dispose() {
    _newName.dispose();
    super.dispose();
  }

  Future<void> _open(String dir) async {
    setState(() {
      _at = normalizePath(dir);
      _folders = null;
      _naming = false;
      _error = null;
    });
    final list = await widget.state.listFolders(dir);
    if (!mounted || normalizePath(dir) != _at) return;
    setState(() => _folders = list);
  }

  Future<void> _create() async {
    final name = _newName.text.trim();
    if (name.isEmpty || name.contains(RegExp(r'[/\\]')) || name == '.' || name == '..') {
      setState(() => _error = 'Not a folder name');
      return;
    }
    final path = _at.endsWith('/') ? '$_at$name' : '$_at/$name';
    try {
      await Directory(path).create();
    } catch (e) {
      setState(() => _error = 'Could not make $name: $e');
      return;
    }
    if (mounted) Navigator.of(context).pop(normalizePath(path));
  }

  void _pick(String dir) => Navigator.of(context).pop(normalizePath(dir));

  Widget _shortcut(String dir, IconData icon, {required Key key}) {
    final here = normalizePath(dir) == normalizePath(widget.start);
    return ListTile(
      key: key,
      dense: true,
      enabled: !here,
      leading: Icon(icon, size: 18, color: Palette.accent),
      title: Text(folderName(dir), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(
        here ? 'Already here' : parentDir(dir),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5, color: Palette.faint),
      ),
      onTap: here ? null : () => _pick(dir),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final recent = state.moveTargets.where((d) => Directory(d).existsSync()).take(4).toList();
    final pinned = [
      for (final d in state.pinnedFolders)
        if (!recent.contains(d)) d,
    ];
    final up = parentDir(_at);
    final atStart = normalizePath(_at) == normalizePath(widget.start);
    final folders = _folders;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (recent.isNotEmpty) ...[
                  const _Heading('RECENT'),
                  for (final d in recent) _shortcut(d, Icons.history, key: ValueKey<String>('move-recent-$d')),
                ],
                if (pinned.isNotEmpty) ...[
                  const _Heading('PINNED'),
                  for (final d in pinned) _shortcut(d, Icons.folder, key: ValueKey<String>('move-pinned-$d')),
                ],
                const _Heading('BROWSE'),
                ListTile(
                  dense: true,
                  leading: IconButton(
                    key: const ValueKey<String>('move-up'),
                    tooltip: 'Up a folder',
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: up.isEmpty || up == _at ? null : () => _open(up),
                  ),
                  title: Text(_at, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Palette.muted)),
                ),
                if (folders == null)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
                  )
                else if (folders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text('No folders in here', style: TextStyle(fontSize: 12.5, color: Palette.faint)),
                  )
                else
                  for (final f in folders)
                    ListTile(
                      key: ValueKey<String>('move-browse-${f.name}'),
                      dense: true,
                      leading: const Icon(Icons.folder_outlined, size: 18, color: Palette.muted),
                      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                      trailing: f.hasChildren ? const Icon(Icons.chevron_right, size: 18, color: Palette.faint) : null,
                      onTap: () => _open(f.path),
                    ),
                if (_naming)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                    child: TextField(
                      key: const ValueKey<String>('move-new-name'),
                      controller: _newName,
                      autofocus: true,
                      onSubmitted: (_) => _create(),
                      decoration: InputDecoration(
                        hintText: 'New folder name',
                        errorText: _error,
                        isDense: true,
                        filled: true,
                        fillColor: Palette.raised,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                        suffixIcon: IconButton(tooltip: 'Make it and move there', icon: const Icon(Icons.check), onPressed: _create),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton.icon(
                key: const ValueKey<String>('move-new-folder'),
                onPressed: _naming ? null : () => setState(() => _naming = true),
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('New folder'),
              ),
              const Spacer(),
              FilledButton(
                key: const ValueKey<String>('move-here'),
                onPressed: atStart ? null : () => _pick(_at),
                child: Text(atStart ? 'Already here' : 'Move to ${folderName(_at)}', maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text(text, style: const TextStyle(fontSize: 10.5, letterSpacing: 0.9, fontWeight: FontWeight.w600, color: Palette.faint)),
    );
  }
}
