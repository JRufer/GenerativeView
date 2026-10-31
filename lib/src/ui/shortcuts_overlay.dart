import 'package:flutter/material.dart';

import '../theme.dart';
import 'sheet.dart';

/// Every keyboard shortcut, by where it works. The shortcut layer and this
/// list are kept side by side; the overlay is how they are found.
const List<(String, List<(String, String)>)> keyboardShortcuts = [
  (
    'Anywhere',
    [
      ('?  or  F1', 'Show these shortcuts'),
      ('Ctrl F  or  /', 'Search'),
      ('F', 'Filters'),
      ('I  or  ]', 'Show or hide the generation data'),
      ('[', 'Show or hide the folders'),
      ('F5', 'Rescan the folder'),
      ('N', 'Follow new pictures as they arrive'),
      ('Ctrl V', 'Paste a copied picture into this folder'),
    ],
  ),
  (
    'Moving around',
    [
      ('Arrows  or  W A S D', 'Move the selection; previous / next in the focus view'),
      ('↑  /  ↓', 'Zoom in or out in the focus view (up to 400%)'),
      ('Pinch  or  wheel', 'Zoom in the focus view; drag to look around'),
      ('Tap  or  F11', 'Full screen and back, in the focus view'),
      ('Pinch out', 'In full screen, past fitted: back to the focus view'),
      ('Home  End  PgUp  PgDn', 'Jump'),
      ('Enter  or  Space', 'Open the picture / back to the grid'),
      ('Esc', 'Back (out of full screen first), close a panel, or clear the selection'),
      ('Mouse back', 'Back (out of full screen first); in the grid, show the folders'),
      ('Mouse forward  or  middle', 'Show or hide the generation data'),
      ('Ctrl +  /  Ctrl −', 'Bigger or smaller tiles'),
      ('C', 'Tiles cropped to fill or whole'),
    ],
  ),
  (
    'The selected picture',
    [
      ('1 – 5', 'Rate it (the same number again clears)'),
      ('0', 'Clear the rating'),
      ('P', 'Flag it to keep'),
      ('X', 'Flag it to reject'),
      ('U', 'Clear its flag'),
      ('B', 'Add it to a collection'),
      ('L', 'More like this'),
      ('R', 'Remix: edit the prompt and send it to a server'),
      ('Shift U', 'Upscale'),
      ('Ctrl C', 'Copy its prompt'),
      ('Ctrl Shift C', 'Copy the picture itself'),
      ('Delete', 'Move it to the trash (asks first)'),
    ],
  ),
  (
    'Several pictures at once',
    [
      ('Corner box  or  Ctrl click', 'Tick a picture; once one is ticked, a tap ticks or unticks any'),
      ('Shift click', 'Tick every picture from the last one ticked to this one'),
      ('Ctrl A', 'Tick every picture listed'),
      ('1 – 5   P   X   U   B', 'Rate, flag or collect all the ticked pictures'),
      ('V', 'Compare two to four of them side by side'),
      ('G', 'Breed new pictures from two to four of them'),
      ('Shift U', 'Upscale them, one after another'),
      ('Ctrl Shift C', 'Copy them as files'),
      ('Delete', 'Move them to the trash (asks once)'),
      ('Drag a tile out', 'Drop the files into another program (desktop)'),
      ('Esc', 'Untick them all'),
    ],
  ),
  (
    'Comparing pictures',
    [
      ('Pinch, wheel  or  drag', 'Zoom and move every picture together'),
      ('Double tap', 'Zoom in there, or back out'),
      ('↑  /  ↓   +  /  −', 'Zoom in or out'),
      ('0', 'Fit them again'),
      ('D', 'List only the settings that differ'),
      ('I', 'Show or hide the settings'),
      ('Esc', 'Back'),
    ],
  ),
  (
    'Editing a prompt',
    [
      ('Select words', 'Weight them with the slider underneath'),
      ('Ctrl ↑  /  Ctrl ↓', 'Weight the selection up or down by 0.05'),
      ('Caret in an underlined word', 'Offers corrections'),
    ],
  ),
];

/// The keyboard shortcuts, in a panel.
Future<void> showShortcuts(BuildContext context) {
  return showPanel<void>(
    context,
    title: 'Keyboard shortcuts',
    icon: Icons.keyboard_outlined,
    width: 640,
    builder: (context) => const _ShortcutList(),
  );
}

class _ShortcutList extends StatelessWidget {
  const _ShortcutList();

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey<String>('shortcut-list'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      children: [
        for (final (section, keys) in keyboardShortcuts) ...[
          PanelHeading(section),
          for (final (key, what) in keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 190, child: _Keys(key)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(what, style: const TextStyle(fontSize: 13, color: Palette.text, height: 1.4))),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// Key names drawn as keycaps.
class _Keys extends StatelessWidget {
  const _Keys(this.keys);
  final String keys;

  @override
  Widget build(BuildContext context) {
    // Words between the keys ("or", "/") are plain text.
    final parts = keys.split(RegExp(r'\s{2,}'));
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final part in parts)
          if (part == 'or' || part == '/')
            Text(part, style: const TextStyle(fontSize: 12, color: Palette.faint))
          else if (part.contains(' ') && !part.startsWith('Ctrl') && !part.startsWith('Shift') && part.length > 12)
            Text(part, style: const TextStyle(fontSize: 12.5, color: Palette.muted))
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Palette.raised,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: Palette.line),
              ),
              child: Text(part, style: const TextStyle(fontSize: 12, color: Palette.text, fontFeatures: [FontFeature.tabularFigures()])),
            ),
      ],
    );
  }
}
