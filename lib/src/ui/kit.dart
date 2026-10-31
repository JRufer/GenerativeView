/// Pieces several screens share, so each looks and behaves the same
/// wherever it appears: a section that folds away, a phrase chip and the
/// one menu every phrase opens, a suggestion row, a score bar, the server
/// choice with its send button, a strip of thumbnails, tabs, and a header
/// for a group of grid tiles.
library;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/backends.dart' show backendNames;
import '../core/models.dart';
import '../theme.dart';
import 'context_menu.dart';
import 'meta_panel.dart' show copyText;
import 'remix_dialog.dart' show openBackendSettings, openRemix;
import 'sheet.dart';
import 'thumb_image.dart';

/// Amber, for what needs a look: a count of suggestions.
const Color attention = Color(0xFFF0A35E);

// ------------------------------------------------------------ fold section

/// A section that folds away to one line: a chevron, an upper-case label,
/// a summary, and optionally a count and an action. Closed unless
/// [initiallyOpen].
class FoldSection extends StatefulWidget {
  const FoldSection({
    super.key,
    required this.label,
    required this.child,
    this.summary,
    this.summaryKey,
    this.toggleKey,
    this.highlight = false,
    this.count,
    this.trailing,
    this.extra,
    this.initiallyOpen = false,
  });
  final String label;
  final Widget child;
  final String? summary;
  final Key? summaryKey;
  final Key? toggleKey;

  /// Shows the summary in the accent colour: something was changed.
  final bool highlight;

  /// A number to draw attention to beside the label (suggestions waiting).
  final int? count;

  /// Shown at the end of the line while the section is open.
  final Widget? trailing;

  /// Shown after the summary, open or folded: a warning, say.
  final Widget? extra;
  final bool initiallyOpen;

  @override
  State<FoldSection> createState() => _FoldSectionState();
}

class _FoldSectionState extends State<FoldSection> {
  late bool _open = widget.initiallyOpen;

  @override
  void didUpdateWidget(FoldSection old) {
    super.didUpdateWidget(old);
    if (widget.initiallyOpen && !old.initiallyOpen) _open = true;
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    final body = _open ? widget.child : const SizedBox(width: double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: InkWell(
                key: widget.toggleKey,
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: _open ? 0.25 : 0,
                        duration: still ? Duration.zero : const Duration(milliseconds: 180),
                        child: const Icon(Icons.chevron_right, size: 18, color: Palette.faint),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        widget.label.toUpperCase(),
                        style: const TextStyle(fontSize: 10.5, letterSpacing: 0.9, fontWeight: FontWeight.w600, color: Palette.faint),
                      ),
                      if (widget.count != null && widget.count! > 0) ...[
                        const SizedBox(width: 8),
                        CountBadge(widget.count!),
                      ],
                      if (widget.summary != null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            widget.summary!,
                            key: widget.summaryKey,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: TextStyle(fontSize: 11.5, color: widget.highlight ? Palette.accent : Palette.faint),
                          ),
                        ),
                      ],
                      if (widget.extra != null) ...[const SizedBox(width: 10), Flexible(child: widget.extra!)],
                    ],
                  ),
                ),
              ),
            ),
            if (_open && widget.trailing != null) widget.trailing!,
          ],
        ),
        if (still) body else AnimatedSize(duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic, alignment: Alignment.topCenter, child: body),
      ],
    );
  }
}

/// A small amber number in a pill.
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key});
  final int count;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 20),
    height: 20,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: attention.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
    child: Text('$count', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: attention)),
  );
}

// ------------------------------------------------------------ phrases

/// How a phrase chip shows its phrase.
enum PhraseLook {
  /// Seen in the picture: a tick.
  seen,

  /// Looked for and not seen: a crossed eye, in red.
  missing,

  /// Only asks for quality, so not looked for: a dash, faint.
  unchecked,

  /// Suggested, not in the prompt yet: a plus, dashed blue.
  suggested,

  /// Offered but left out: a plus, faint.
  off,
}

/// One phrase of a prompt, as a chip: the same in prompt check, in a
/// described prompt and in the mask editor's Find row.
class PhraseChip extends StatelessWidget {
  const PhraseChip({super.key, required this.text, required this.look, this.confidence, this.tooltip, this.onTap, this.onPressAt, this.selected = false});
  final String text;
  final PhraseLook look;

  /// 0 to 1: drawn as a small bar after the phrase.
  final double? confidence;
  final String? tooltip;
  final VoidCallback? onTap;

  /// For a menu: where it was tapped, in global coordinates.
  final ValueChanged<Offset>? onPressAt;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (look) {
      PhraseLook.seen => (Icons.check, Palette.accent),
      PhraseLook.missing => (Icons.visibility_off_outlined, Palette.danger),
      PhraseLook.unchecked => (Icons.remove, Palette.faint),
      PhraseLook.suggested => (Icons.add, Palette.accent),
      PhraseLook.off => (Icons.add, Palette.faint),
    };
    final faint = look == PhraseLook.unchecked || look == PhraseLook.off;
    final border = selected
        ? Palette.accent
        : switch (look) {
            PhraseLook.missing => Palette.danger.withValues(alpha: 0.45),
            PhraseLook.suggested => Palette.accent.withValues(alpha: 0.6),
            _ => Palette.line,
          };
    final tappable = onTap != null || onPressAt != null;
    Widget chip = Material(
      color: selected ? Palette.accent.withValues(alpha: 0.18) : (look == PhraseLook.off ? Colors.transparent : Palette.raised),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5), side: BorderSide(color: border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: !tappable ? null : (onTap ?? () {}),
        onTapUp: onPressAt == null ? null : (d) => onPressAt!(d.globalPosition),
        hoverColor: Palette.hover,
        child: ConstrainedBox(
          // A finger's worth of height when it does something.
          constraints: BoxConstraints(minHeight: tappable ? 30 : 24),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: faint ? Palette.faint : (look == PhraseLook.suggested ? Palette.accent : Palette.text)),
                  ),
                ),
                if (confidence != null) ...[
                  const SizedBox(width: 6),
                  SizedBox(width: 22, child: ScoreBar(confidence!, height: 3)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) chip = Tooltip(message: tooltip!, child: chip);
    return chip;
  }
}

/// The one menu any phrase of a picture's prompt opens: fix where it
/// should be, weight it up, see the pictures that ask for it, copy it.
Future<void> showPhraseMenu(
  BuildContext context, {
  required Offset at,
  required AppState state,
  required MediaItem item,
  required String phrase,
  bool seen = true,
}) async {
  final choice = await showContextMenu<String>(context, at, [
    if (!item.isVideo) const MenuEntry('fix', 'Fix this spot…', Icons.center_focus_strong_outlined),
    const MenuEntry('weight', 'Weight up in Remix', Icons.north_east),
    const MenuEntry('filter', 'Show pictures with this phrase', Icons.filter_alt_outlined),
    const MenuEntry('copy', 'Copy phrase', Icons.copy),
  ]);
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'fix':
      await openRemix(context, state, item, fixPhrase: phrase);
    case 'weight':
      await openRemix(context, state, item, weightUp: phrase);
    case 'filter':
      state.applyFilter('prompt:"${phrase.replaceAll('"', '')}"');
    case 'copy':
      copyText(context, phrase, 'phrase');
  }
}

// ------------------------------------------------------------ suggestions

/// One suggested change: what it is about, why, and a button that makes
/// it, which then says it is done.
class SuggestionRow extends StatelessWidget {
  const SuggestionRow({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.why,
    required this.action,
    required this.onAction,
    this.done = false,
    this.onTitleTap,
  });
  final IconData icon;
  final Color color;
  final InlineSpan title;
  final String why;
  final String action;
  final VoidCallback onAction;
  final bool done;

  /// Tapping the words (selects the phrase in the prompt, say).
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: onTitleTap,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(title, style: const TextStyle(fontSize: 13, color: Palette.text, height: 1.3)),
                    const SizedBox(height: 2),
                    Text(why, style: const TextStyle(fontSize: 11.5, color: Palette.faint, height: 1.3)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          done
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check, size: 16, color: keepGreen),
                      SizedBox(width: 4),
                      Text('Applied', style: TextStyle(fontSize: 13, color: keepGreen)),
                    ],
                  ),
                )
              : TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );
  }
}

/// The colour of keeping: a kept flag, a done suggestion, a liked share.
const Color keepGreen = Color(0xFF7BC88F);

// ------------------------------------------------------------ bars

/// A thin bar for a value from 0 to 1.
class ScoreBar extends StatelessWidget {
  const ScoreBar(this.value, {super.key, this.color = Palette.accent, this.height = 6});
  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Palette.line),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value.clamp(0.0, 1.0).toDouble(),
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// How often something turns up among liked pictures (green, top) and
/// disliked ones (red, below).
class LiftBars extends StatelessWidget {
  const LiftBars({super.key, required this.keep, required this.reject});
  final double keep;
  final double reject;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ScoreBar(keep, color: keepGreen.withValues(alpha: 0.9), height: 5),
      const SizedBox(height: 3),
      ScoreBar(reject, color: Palette.danger.withValues(alpha: 0.8), height: 5),
    ],
  );
}

// ------------------------------------------------------------ server + send

/// Which server to send to and the button that sends: the same in Remix,
/// Breed and Upscale's hires fix. Kept at the bottom of a panel. On a
/// narrow panel the servers sit on a row of their own above the button.
class ServerSendBar extends StatelessWidget {
  const ServerSendBar({
    super.key,
    required this.state,
    required this.backend,
    required this.onBackend,
    required this.action,
    required this.onSend,
    this.servers,
    this.support = const {},
    this.icon = Icons.send,
    this.actionKey,
    this.chipKey,
    this.leading,
    this.sending = false,
    this.error,
    this.showServers = true,
    this.onServersChanged,
  });
  final AppState state;
  final String? backend;
  final ValueChanged<String> onBackend;

  /// The servers offered; all of them when null.
  final List<String>? servers;

  /// Why a server cannot take this, by kind; null where it can.
  final Map<String, String?> support;
  final String action;
  final IconData icon;

  /// Null disables the button.
  final VoidCallback? onSend;
  final Key? actionKey;
  final Key? Function(String kind)? chipKey;

  /// Beside the button, on its left: Copy prompt, or a note.
  final Widget? leading;
  final bool sending;
  final String? error;
  final bool showServers;

  /// After the servers were set up from the Servers… button.
  final VoidCallback? onServersChanged;

  @override
  Widget build(BuildContext context) {
    final urls = state.backendUrls;
    final kinds = servers ?? backendNames.keys.toList();
    final chips = [
      for (final kind in kinds)
        ChoiceChipButton(
          key: chipKey?.call(kind),
          label: backendNames[kind] ?? kind,
          selected: backend == kind,
          icon: (urls[kind] ?? '').isEmpty ? Icons.link_off : Icons.dns_outlined,
          tooltip: support[kind] ?? urls[kind] ?? 'Not set up yet: you will be asked where it is',
          onTap: support[kind] == null && !sending ? () => onBackend(kind) : null,
        ),
    ];
    final setUp = IconButton(
      tooltip: 'Servers…',
      icon: const Icon(Icons.dns_outlined, size: 19),
      onPressed: () async {
        await openBackendSettings(context, state);
        onServersChanged?.call();
      },
    );
    final button = FilledButton.icon(
      key: actionKey,
      onPressed: sending ? null : onSend,
      icon: sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon, size: 18),
      label: Text(action, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    // A sheet runs down to the gesture bar; a dialog sits clear of it.
    final sheet = ModalRoute.of(context) is ModalBottomSheetRoute;
    final bottom = sheet ? MediaQuery.paddingOf(context).bottom : 0.0;
    return DecoratedBox(
      decoration: const BoxDecoration(color: Palette.panel, border: Border(top: BorderSide(color: Palette.line))),
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 10, 18, 12 + bottom),
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 640;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 96),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(error!, style: const TextStyle(fontSize: 12.5, color: Palette.danger, height: 1.35)),
                    ),
                  ),
                if (showServers && !wide) ...[
                  Row(
                    children: [
                      Expanded(child: Wrap(spacing: 6, runSpacing: 6, children: chips)),
                      setUp,
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    if (showServers && wide) ...[
                      Flexible(flex: 3, child: Wrap(spacing: 6, runSpacing: 6, children: chips)),
                      setUp,
                    ],
                    // What is beside the button takes the room left over,
                    // so it wraps only when there truly is none.
                    if (leading != null) ...[
                      const SizedBox(width: 6),
                      Expanded(child: Align(alignment: Alignment.centerLeft, child: leading!)),
                    ] else
                      const Spacer(),
                    const SizedBox(width: 10),
                    button,
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ thumbnails

/// A row of small square thumbnails.
class ThumbStrip extends StatelessWidget {
  const ThumbStrip({super.key, required this.state, required this.items, this.size = 46, this.borders});
  final AppState state;
  final List<MediaItem> items;
  final double size;

  /// A border colour for each, to tie it to something (Breed's parents).
  final List<Color>? borders;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
            child: Container(
              decoration: borders == null ? null : BoxDecoration(border: Border.all(color: borders![i % borders!.length], width: 2), borderRadius: BorderRadius.circular(6)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: size,
                  height: size,
                  child: ColoredBox(color: Palette.tile, child: ThumbImage(cache: state.thumbs, item: items[i], tier: 0, fit: BoxFit.cover)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------ tabs

/// One choice of a [PanelTabs].
class TabChoice<T> {
  const TabChoice(this.value, this.label, this.icon, {this.key});
  final T value;
  final String label;
  final IconData icon;
  final Key? key;
}

/// A row of tabs (a segmented button). [expand] stretches it across the
/// width; [compact] shows only the icon on the tabs not chosen, for a
/// narrow screen.
class PanelTabs<T> extends StatelessWidget {
  const PanelTabs({super.key, required this.choices, required this.selected, required this.onChanged, this.expand = false, this.compact = false});
  final List<TabChoice<T>> choices;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool expand;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final button = SegmentedButton<T>(
      showSelectedIcon: false,
      segments: [
        for (final c in choices)
          ButtonSegment<T>(
            value: c.value,
            icon: Icon(c.icon, size: 16),
            tooltip: compact && c.value != selected ? c.label : null,
            label: compact && c.value != selected ? null : Text(c.label, key: c.key, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      selected: {selected},
      onSelectionChanged: (s) => onChanged(s.first),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

// ------------------------------------------------------------ group header

/// A line across the grid above a group of tiles: what the group is, the
/// one picked from it and why, and an action on the group.
class GroupHeader extends StatelessWidget {
  const GroupHeader({super.key, required this.title, required this.why, required this.action, required this.onAction});
  final String title;
  final String why;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 2, 2),
      child: Row(
        children: [
          Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Palette.text)),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (why.isNotEmpty) ...[
                    const TextSpan(text: 'Best: ', style: TextStyle(color: Palette.muted)),
                    TextSpan(text: why, style: const TextStyle(color: Palette.accent, fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );
  }
}
