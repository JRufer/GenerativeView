import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../platform.dart';
import 'context_menu.dart';
import 'meta_panel.dart';
import 'notes_widgets.dart';
import 'remix_dialog.dart';
import 'upscale_dialog.dart';

/// The menu a right click or a press-and-hold on an image brings up.
Future<void> showImageMenu(
  BuildContext context,
  AppState state,
  MediaItem item,
  Offset position,
) async {
  final choice = await showContextMenu<String>(context, position, [
    MenuEntry(
      'file',
      item.isVideo ? 'Copy video' : 'Copy image',
      Icons.content_copy,
    ),
    const MenuEntry('prompt', 'Copy prompt', Icons.notes),
    const MenuEntry('path', 'Copy file path', Icons.link),
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
