import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../platform.dart';
import 'context_menu.dart';
import 'filter_sheet.dart' show FilterSet;
import 'meta_panel.dart';
import 'notes_widgets.dart';
import 'remix_dialog.dart';
import 'sheet.dart';
import 'upscale_dialog.dart';

/// The menu a right click or a press-and-hold on an image brings up.
Future<void> showImageMenu(
  BuildContext context,
  AppState state,
  MediaItem item,
  Offset position,
) async {
  // The collection being looked at, if the grid is narrowed to one: every
  // picture shown is in it, so the menu can take this one out again.
  final collections = FilterSet.parse(state.query).chosen['collection'] ?? const <String>{};
  final shownCollection = collections.length == 1 ? collections.first : null;
  final choice = await showContextMenu<String>(context, position, [
    MenuEntry(
      'file',
      item.isVideo ? 'Copy video' : 'Copy image',
      Icons.content_copy,
    ),
    const MenuEntry('prompt', 'Copy prompt', Icons.notes),
    const MenuEntry('path', 'Copy file path', Icons.link),
    const MenuEntry('paste', 'Paste into this folder', Icons.content_paste),
    const MenuEntry('similar', 'More like this (L)', Icons.image_search),
    const MenuEntry('remix', 'Remix… (R)', Icons.auto_fix_high),
    if (!item.isVideo) const MenuEntry('upscale', 'Upscale… (Shift U)', Icons.photo_size_select_large),
    const MenuEntry('collection', 'Add to collection… (B)', Icons.collections_bookmark_outlined),
    MenuEntry(
      'keep',
      item.flag == Flag.keep ? 'Clear the keep flag (P)' : 'Keep (P)',
      Icons.check_circle_outline,
    ),
    MenuEntry(
      'reject',
      item.flag == Flag.reject ? 'Clear the reject flag (X)' : 'Reject (X)',
      Icons.cancel_outlined,
    ),
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
    case 'keep':
      await state.changeNotes(targets: [item], flag: item.flag == Flag.keep ? Flag.none : Flag.keep);
    case 'reject':
      await state.changeNotes(targets: [item], flag: item.flag == Flag.reject ? Flag.none : Flag.reject);
    case 'file':
      await copyImage(context, item);
    case 'prompt':
      await copyPrompt(context, state, item);
    case 'path':
      copyText(context, item.path, 'file path');
    case 'paste':
      await pasteInto(context, state, item.dir);
    case 'uncollect':
      await state.changeNotes(targets: [item], remove: [shownCollection!]);
      if (context.mounted) toast(context, 'Removed from "$shownCollection"');
    case 'delete':
      await deleteFile(context, state, item);
  }
}

/// Paste what is on the clipboard (a copied file, or a picture copied from
/// a browser or an editor) into [dir].
Future<void> pasteInto(BuildContext context, AppState state, String dir) async {
  final source = await readPasteSource();
  if (!context.mounted) return;
  if (source == null) {
    toast(context, 'Nothing to paste: copy an image or a video first');
    return;
  }
  try {
    final saved = await state.pasteInto(dir, source);
    if (context.mounted) toast(context, 'Pasted ${saved.split(Platform.pathSeparator).last}');
  } catch (e) {
    if (context.mounted) toast(context, 'Could not paste here: $e');
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
