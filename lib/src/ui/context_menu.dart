import 'package:flutter/material.dart';

import '../theme.dart';

/// One line of a [showContextMenu] menu.
class MenuEntry<T> {
  const MenuEntry(this.value, this.label, this.icon);
  final T value;
  final String label;
  final IconData icon;
}

/// A small menu at [position] (in global coordinates), the kind a right
/// click or a press-and-hold brings up. Completes with the chosen entry's
/// value, or null if the menu was dismissed.
Future<T?> showContextMenu<T>(
  BuildContext context,
  Offset position,
  List<MenuEntry<T>> entries,
) => showGroupedContextMenu<T>(context, position, [entries]);

/// A [showContextMenu] menu with a line between its [groups]. A group with
/// nothing in it leaves no line behind.
Future<T?> showGroupedContextMenu<T>(
  BuildContext context,
  Offset position,
  List<List<MenuEntry<T>>> groups,
) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final shown = groups.where((g) => g.isNotEmpty).toList();
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<T>>[
      for (var i = 0; i < shown.length; i++) ...[
        if (i > 0) const PopupMenuDivider(height: 9),
        for (final entry in shown[i])
          PopupMenuItem<T>(
            value: entry.value,
            height: 38,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(entry.icon, size: 16, color: Palette.muted),
                const SizedBox(width: 10),
                Flexible(child: Text(entry.label)),
              ],
            ),
          ),
      ],
    ],
  );
}
