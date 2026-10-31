import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../platform.dart';
import 'breed_dialog.dart';
import 'compare_view.dart';
import 'context_menu.dart';
import 'filter_sheet.dart' show FilterSet;
import 'meta_panel.dart';
import 'move_ui.dart';
import 'notes_widgets.dart';
import 'remix_dialog.dart';
import 'sheet.dart';
import 'upscale_dialog.dart';

/// The collection being looked at, if the grid is narrowed to one: every
/// picture shown is in it, so the menu can take pictures out again.
String? _shownCollection(AppState state) {
  final collections = FilterSet.parse(state.query).chosen['collection'] ?? const <String>{};
  return collections.length == 1 ? collections.first : null;
}

/// The menu a right click or a press-and-hold on an image brings up. On one
/// of several ticked pictures, it is the menu for all of them.
Future<void> showImageMenu(
  BuildContext context,
  AppState state,
  MediaItem item,
  Offset position,
) async {
  final targets = state.targetsFor(item);
  if (targets.length > 1) return _showManyMenu(context, state, targets, position);
  final shownCollection = _shownCollection(state);
  // Remix only when there is something to remake it from: its generation
  // data, or a prompt the picture model can describe from it.
  // (Known at once for a picture with generation data, so the menu opens
  // without waiting.)
  final remakeable = state.canRemakeNow(item) || await state.canRemake(item);
  if (!context.mounted) return;
  final choice = await showContextMenu<String>(context, position, [
    MenuEntry(
      'file',
      item.isVideo ? 'Copy video' : 'Copy image',
      Icons.content_copy,
    ),
    const MenuEntry('prompt', 'Copy prompt', Icons.notes),
    const MenuEntry('path', 'Copy file path', Icons.link),
    if (canShareFiles) MenuEntry('share', item.isVideo ? 'Share video…' : 'Share image…', Icons.share_outlined),
    const MenuEntry('paste', 'Paste into this folder', Icons.content_paste),
    const MenuEntry('similar', 'More like this (L)', Icons.image_search),
    if (remakeable) const MenuEntry('remix', 'Remix… (R)', Icons.auto_fix_high),
    if (!item.isVideo) const MenuEntry('upscale', 'Upscale… (Shift U)', Icons.photo_size_select_large),
    const MenuEntry('collection', 'Add to collection… (B)', Icons.collections_bookmark_outlined),
    const MenuEntry('move', 'Move to… (M)', Icons.drive_file_move_outline),
    if (shownCollection != null)
      MenuEntry('uncollect', 'Remove from "$shownCollection"', Icons.bookmark_remove_outlined),
    MenuEntry('delete', item.isVideo ? 'Delete video…' : 'Delete image…', Icons.delete_outline),
  ]);
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'similar':
      state.findSimilar(item);
    case 'remix':
      await openRemix(context, state, item);
    case 'upscale':
      await openUpscale(context, state, item);
    case 'collection':
      await showCollectionPicker(context, state, [item]);
    case 'move':
      await openMoveTo(context, state, [item]);
    case 'file':
      await copyImage(context, item);
    case 'prompt':
      await copyPrompt(context, state, item);
    case 'path':
      copyText(context, item.path, 'file path');
    case 'share':
      await shareItems(context, [item]);
    case 'paste':
      await pasteInto(context, state, item.dir);
    case 'uncollect':
      await state.changeNotes(targets: [item], remove: [shownCollection!]);
      if (context.mounted) toast(context, 'Removed from "$shownCollection"');
    case 'delete':
      await deleteFile(context, state, item);
  }
}

/// The menu for several ticked pictures: only what can be done to all of
/// them at once.
Future<void> _showManyMenu(BuildContext context, AppState state, List<MediaItem> targets, Offset position) async {
  final n = targets.length;
  final shownCollection = _shownCollection(state);
  final images = targets.where((t) => !t.isVideo).length;
  final things = targets.every((t) => t.isVideo) ? 'videos' : (images == n ? 'images' : 'files');
  final canCompare = images >= compareMin && images <= compareMax;
  final canBreed = state.canBreedNow(targets) || await state.canBreed(targets);
  if (!context.mounted) return;
  final choice = await showContextMenu<String>(context, position, [
    if (canCompare) MenuEntry('compare', 'Compare $images side by side (V)', Icons.compare),
    if (canBreed) MenuEntry('breed', 'Breed new pictures from $images… (G)', Icons.hub_outlined),
    if (images >= 2) const MenuEntry('best', 'Tick all but the best', Icons.workspace_premium_outlined),
    MenuEntry('copy', 'Copy $n $things', Icons.content_copy),
    if (canShareFiles) MenuEntry('share', 'Share $n $things…', Icons.share_outlined),
    const MenuEntry('rate', 'Rate…', Icons.star_outline_rounded),
    const MenuEntry('collection', 'Add to collection… (B)', Icons.collections_bookmark_outlined),
    MenuEntry('move', 'Move $n $things to… (M)', Icons.drive_file_move_outline),
    if (shownCollection != null)
      MenuEntry('uncollect', 'Remove from "$shownCollection"', Icons.bookmark_remove_outlined),
    if (images > 0)
      MenuEntry('upscale', images == n ? 'Upscale $n images… (Shift U)' : 'Upscale the $images images… (Shift U)', Icons.photo_size_select_large),
    MenuEntry('delete', 'Delete $n $things…', Icons.delete_outline),
    const MenuEntry('clear', 'Clear the selection (Esc)', Icons.deselect),
  ]);
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'compare':
      await openCompare(context, state, targets);
    case 'breed':
      await openBreed(context, state, targets);
    case 'best':
      final ticked = state.showingDuplicates && state.duplicateGroups.isNotEmpty
          ? state.tickAllButBest()
          : await state.keepBestOfTicked();
      if (context.mounted) toast(context, ticked == 0 ? 'Could not tell which to keep' : '$ticked ticked; the best of them is left unticked');
    case 'copy':
      await copyItems(context, targets);
    case 'share':
      await shareItems(context, targets);
    case 'rate':
      final stars = await showContextMenu<int>(context, position, [
        for (var i = 5; i >= 1; i--) MenuEntry(i, '${'★' * i}${'☆' * (5 - i)}  ($i)', Icons.star_rounded),
        const MenuEntry(0, 'No stars (0)', Icons.star_outline_rounded),
      ]);
      if (stars != null) await state.rate(targets, stars);
    case 'collection':
      await showCollectionPicker(context, state, targets);
    case 'move':
      await openMoveTo(context, state, targets);
    case 'uncollect':
      await state.changeNotes(targets: targets, remove: [shownCollection!]);
      if (context.mounted) toast(context, 'Removed $n from "$shownCollection"');
    case 'upscale':
      await openUpscaleMany(context, state, targets);
    case 'delete':
      await deleteFiles(context, state, targets);
    case 'clear':
      state.clearChecked();
  }
}

/// Copy [items] as files, so they paste as themselves, generation data
/// and all.
Future<void> copyItems(BuildContext context, List<MediaItem> items) async {
  if (items.length == 1) return copyImage(context, items.single);
  final copied = await copyFilesToClipboard([for (final i in items) i.path]);
  if (!context.mounted) return;
  toast(context, copied ? 'Copied ${items.length} files' : 'Could not copy these files');
}

/// Hand [items] to another app through the system's share sheet.
Future<void> shareItems(BuildContext context, List<MediaItem> items) async {
  final shared = await shareFiles([for (final i in items) i.path]);
  if (!shared && context.mounted) toast(context, 'Could not share ${items.length == 1 ? 'this file' : 'these files'}');
}

/// Delete several files at once, after asking once: to the trash where
/// there is one, for good (after asking again) where there isn't.
Future<void> deleteFiles(BuildContext context, AppState state, List<MediaItem> items) async {
  if (items.length == 1) return deleteFile(context, state, items.single);
  final n = items.length;
  if (!trashAsksFirst) {
    final yes = await confirmAction(
      context,
      title: 'Delete $n files?',
      message: 'They are moved to the trash, along with their stars, flags and collections. You can restore them from the trash.',
      action: 'Move $n to trash',
    );
    if (!yes || !context.mounted) return;
  }
  final trashed = <MediaItem>[];
  final noTrash = <MediaItem>[];
  final failed = <String>[];
  if (trashAsksFirst) {
    // One prompt from the system for all of them, where it can.
    final (outcome, why) = await trashFiles([for (final i in items) i.path]);
    switch (outcome) {
      case TrashOutcome.trashed:
        trashed.addAll(items);
      case TrashOutcome.cancelled:
        return;
      case TrashOutcome.failed:
        failed.add(why ?? 'unknown error');
      case TrashOutcome.unsupported:
        noTrash.addAll(items);
    }
  } else {
    for (final item in items) {
      final (outcome, why) = await trashFile(item.path);
      switch (outcome) {
        case TrashOutcome.trashed:
          trashed.add(item);
        case TrashOutcome.cancelled:
          break;
        case TrashOutcome.failed:
          failed.add('${item.name}: ${why ?? 'unknown error'}');
        case TrashOutcome.unsupported:
          noTrash.add(item);
      }
    }
  }
  if (noTrash.isNotEmpty && context.mounted) {
    final m = noTrash.length;
    final yes = await confirmAction(
      context,
      title: m == 1 ? 'Delete ${noTrash.single.name} permanently?' : 'Delete $m files permanently?',
      message: 'There is no trash for ${m == 1 ? 'this file' : 'these files'} here, so ${m == 1 ? 'it' : 'they'} would be deleted for good. This can\'t be undone.',
      action: 'Delete permanently',
    );
    if (yes) {
      for (final item in noTrash) {
        try {
          await File(item.path).delete();
          trashed.add(item);
        } catch (e) {
          failed.add('${item.name}: $e');
        }
      }
    }
  }
  await state.forgetFiles(trashed);
  if (!context.mounted) return;
  if (failed.isNotEmpty) {
    toast(context, 'Could not delete ${failed.length == 1 ? failed.single : '${failed.length} files'}');
  } else if (trashed.isNotEmpty) {
    toast(context, trashed.length == 1 ? 'Deleted ${trashed.single.name}' : 'Deleted ${trashed.length} files');
  }
}

/// Paste what is on the clipboard (a copied file, or a picture copied from
/// a browser or an editor) into [dir].
Future<void> pasteInto(BuildContext context, AppState state, String dir) async {
  final sources = await readPasteSources();
  if (!context.mounted) return;
  if (sources.isEmpty) {
    toast(context, 'Nothing to paste: copy an image or a video first');
    return;
  }
  // Every copied item, not just the first.
  final saved = <String>[];
  Object? error;
  for (final source in sources) {
    try {
      saved.add(await state.pasteInto(dir, source));
    } catch (e) {
      error ??= e;
    }
  }
  if (!context.mounted) return;
  if (saved.isEmpty) {
    toast(context, 'Could not paste here: $error');
  } else if (error != null) {
    toast(context, 'Pasted ${saved.length} of ${sources.length}; the rest failed: $error');
  } else if (saved.length == 1) {
    toast(context, 'Pasted ${saved.single.split(Platform.pathSeparator).last}');
  } else {
    toast(context, 'Pasted ${saved.length} files');
  }
}

/// Delete [item]'s file, after asking: to the system trash where there is
/// one, for good (after asking again) where there isn't.
Future<void> deleteFile(BuildContext context, AppState state, MediaItem item) async {
  final what = item.isVideo ? 'video' : 'image';
  // Android's media store shows its own prompt for the trash.
  if (!trashAsksFirst) {
    final yes = await confirmAction(
      context,
      title: 'Delete ${item.name}?',
      message: 'The $what is moved to the trash, along with its stars, flag and collections. You can restore the file from the trash.',
      action: 'Move to trash',
    );
    if (!yes || !context.mounted) return;
  }
  final (outcome, why) = await trashFile(item.path);
  if (!context.mounted) return;
  switch (outcome) {
    case TrashOutcome.trashed:
      await state.forgetFile(item);
      if (context.mounted) toast(context, 'Moved ${item.name} to the trash');
    case TrashOutcome.cancelled:
      return;
    case TrashOutcome.failed:
      toast(context, 'Could not delete ${item.name}: ${why ?? 'unknown error'}');
    case TrashOutcome.unsupported:
      final yes = await confirmAction(
        context,
        title: 'Delete ${item.name} permanently?',
        message: 'There is no trash for this file here, so it would be deleted for good. This can\'t be undone.',
        action: 'Delete permanently',
      );
      if (!yes || !context.mounted) return;
      try {
        await File(item.path).delete();
      } catch (e) {
        if (context.mounted) toast(context, 'Could not delete ${item.name}: $e');
        return;
      }
      await state.forgetFile(item);
      if (context.mounted) toast(context, 'Deleted ${item.name}');
  }
}

/// Copy the file itself, so whatever it is pasted into gets the generation
/// data along with the picture.
Future<void> copyImage(BuildContext context, MediaItem item) async {
  final copied = await copyFileToClipboard(item.path);
  if (!context.mounted) return;
  final what = item.isVideo ? 'video' : 'image';
  toast(context, copied ? 'Copied $what' : 'Could not copy this $what');
}

Future<void> copyPrompt(
  BuildContext context,
  AppState state,
  MediaItem item,
) async {
  final GenInfo info;
  try {
    info = await state.metadata(item);
  } catch (_) {
    // Nothing to copy from a file we cannot read.
    return;
  }
  if (!context.mounted || info.prompt.isEmpty) return;
  copyText(context, info.prompt, 'prompt');
}
