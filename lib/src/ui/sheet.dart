import 'package:flutter/material.dart';

import '../theme.dart';

/// Below this width a panel comes up from the bottom edge, where a thumb
/// can reach it; above it, a panel opens in the middle of the window.
const double _sheetBelow = 700;

/// Open [builder]'s content as a panel with a [title]: a sheet from the
/// bottom on a narrow screen, a dialog on a wide one. Same content, same
/// controls, either way; Esc, the close button, or tapping outside closes
/// it.
Future<T?> showPanel<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  double width = 560,
  IconData? icon,
}) {
  final narrow = MediaQuery.sizeOf(context).width < _sheetBelow;
  Widget frame(BuildContext context) => _PanelFrame(title: title, icon: icon, child: builder(context));
  if (narrow) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Palette.panel,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
      builder: (context) => Padding(
        // Keep the panel above the soft keyboard.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: frame(context),
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Palette.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Palette.line),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: frame(context),
      ),
    ),
  );
}

class _PanelFrame extends StatelessWidget {
  const _PanelFrame({required this.title, required this.child, this.icon});
  final String title;
  final IconData? icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
          child: Row(
            children: [
              if (icon != null) ...[Icon(icon, size: 18, color: Palette.muted), const SizedBox(width: 10)],
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Palette.text),
                ),
              ),
              IconButton(
                tooltip: 'Close (Esc)',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Flexible(child: child),
      ],
    );
  }
}

/// A section heading inside a panel, in the style of the metadata panel's.
class PanelHeading extends StatelessWidget {
  const PanelHeading(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: const TextStyle(fontSize: 10.5, letterSpacing: 0.9, fontWeight: FontWeight.w600, color: Palette.faint),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A chip that can be on or off, big enough for a finger: the one way
/// choices are made in the app's panels.
class ChoiceChipButton extends StatelessWidget {
  const ChoiceChipButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.icon,
    this.tooltip,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final int? count;
  final IconData? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Material(
      color: selected ? Palette.accent.withValues(alpha: 0.2) : Palette.raised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? Palette.accent : Palette.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: Palette.hover,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 34),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: selected ? Palette.accent : Palette.muted),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: selected ? Palette.text : const Color(0xFFCFCFD6)),
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 6),
                  Text('$count', style: const TextStyle(fontSize: 11.5, color: Palette.faint)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}
