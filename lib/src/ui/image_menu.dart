import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../platform.dart';
import 'context_menu.dart';
import 'meta_panel.dart';

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
  ]);
  if (choice == null || !context.mounted) return;
  switch (choice) {
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
