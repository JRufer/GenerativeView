import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../core/prompt_weights.dart';
import '../core/spelling.dart';
import '../theme.dart';

/// The text of a prompt, drawn with what the editor knows about it: words
/// the spelling check questions get a wavy red underline, and weighted
/// groups a tint that is warmer the heavier they are.
class PromptController extends TextEditingController {
  PromptController({super.text});

  Spelling? _spelling;
  final Set<String> _ignored = {};

  Spelling? get spelling => _spelling;
  set spelling(Spelling? value) {
    _spelling = value;
    notifyListeners();
  }

  /// Leave [word] alone for the rest of this edit.
  void ignore(String word) {
    _ignored.add(word.toLowerCase());
    notifyListeners();
  }

  bool misspelled(String word) =>
      !_ignored.contains(word.toLowerCase()) && (_spelling?.isMisspelled(word) ?? false);

  /// The questioned word the caret is in, if any: (start, word).
  (int, String)? misspelledAt(int offset) {
    for (final (start, word) in promptWords(text)) {
      if (offset >= start && offset <= start + word.length && misspelled(word)) return (start, word);
    }
    return null;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    // While a keyboard is composing a word, it draws its own underline.
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final t = text;
    // A style for each character: the weight tint, then the underline.
    final tints = List<Color?>.filled(t.length, null);
    for (final g in weightGroups(t)) {
      final heavier = g.weight >= plainWeight;
      final strength = ((g.weight - plainWeight).abs() / (maxWeight - plainWeight)).clamp(0.15, 1.0);
      final color = (heavier ? const Color(0xFFF0A35E) : Palette.accent).withValues(alpha: 0.10 + 0.25 * strength);
      for (var i = g.open; i < g.end && i < t.length; i++) {
        tints[i] = color;
      }
    }
    final wrong = List<bool>.filled(t.length, false);
    if (_spelling != null) {
      for (final (start, word) in promptWords(t)) {
        if (misspelled(word)) {
          for (var i = start; i < start + word.length; i++) {
            wrong[i] = true;
          }
        }
      }
    }
    final spans = <TextSpan>[];
    var from = 0;
    for (var i = 1; i <= t.length; i++) {
      if (i < t.length && tints[i] == tints[from] && wrong[i] == wrong[from]) continue;
      spans.add(
        TextSpan(
          text: t.substring(from, i),
          style: TextStyle(
            backgroundColor: tints[from],
            decoration: wrong[from] ? TextDecoration.underline : null,
            decorationStyle: wrong[from] ? TextDecorationStyle.wavy : null,
            decorationColor: wrong[from] ? Palette.danger : null,
          ),
        ),
      );
      from = i;
    }
    return TextSpan(style: style, children: spans);
  }
}

/// A prompt editor: spelling is checked as you type, and selecting words
/// brings up a slider under them that sets their weight, `(words:1.2)`,
/// from 0.1 to 2.0. With the caret in a questioned word, the corrections
/// are offered there instead.
///
/// Keyboard: Ctrl+Up / Ctrl+Down nudge the weight of the selection, as in
/// ComfyUI.
class PromptEditor extends StatefulWidget {
  const PromptEditor({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.minLines = 3,
    this.maxLines = 10,
    this.onAddWord,
    this.autofocus = false,
    this.focusNode,
  });
  final PromptController controller;

  /// Its focus, when the panel around it needs to move the caret into it.
  final FocusNode? focusNode;
  final String? label;
  final String? hint;
  final int minLines;
  final int maxLines;
  final bool autofocus;

  /// Add a word to the user's own dictionary.
  final ValueChanged<String>? onAddWord;

  @override
  State<PromptEditor> createState() => _PromptEditorState();
}

/// How wide the weight slider is: wide enough to set a weight to the
/// nearest step with a thumb.
const double _sliderWidth = 280;

class _PromptEditorState extends State<PromptEditor> {
  final GlobalKey _fieldKey = GlobalKey();
  final OverlayPortalController _popup = OverlayPortalController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode(debugLabel: 'prompt');

  /// Where the popup goes (global), and what it offers.
  Offset? _anchor;
  _Offer _offer = _Offer.none;

  /// The weight while the slider is being dragged.
  double? _dragging;

  PromptController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
    _focus.addListener(_onChange);
  }

  @override
  void didUpdateWidget(PromptEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    _focus.removeListener(_onChange);
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  RenderEditable? _editable() {
    RenderEditable? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderEditable) {
        found = o;
        return;
      }
      o.visitChildren(visit);
    }

    final root = _fieldKey.currentContext?.findRenderObject();
    if (root != null) visit(root);
    return found;
  }

  void _onChange() {
    // Laid out first, so the selection's place on screen is known.
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
  }

  void _place() {
    if (!mounted) return;
    final sel = _c.selection;
    var offer = _Offer.none;
    TextSelection? around;
    if (_focus.hasFocus && sel.isValid) {
      if (!sel.isCollapsed && trimmedRange(_c.text, sel).isValid && !trimmedRange(_c.text, sel).isCollapsed) {
        offer = _Offer.weight;
        around = sel;
      } else if (sel.isCollapsed) {
        final group = groupAt(_c.text, sel);
        final wrong = _c.misspelledAt(sel.baseOffset);
        if (wrong != null) {
          offer = _Offer.spelling;
          around = TextSelection(baseOffset: wrong.$1, extentOffset: wrong.$1 + wrong.$2.length);
        } else if (group != null) {
          offer = _Offer.weight;
          around = TextSelection(baseOffset: group.textStart, extentOffset: group.textEnd);
        }
      }
    }
    if (_dragging != null) offer = _Offer.weight;
    Offset? anchor;
    final editable = _editable();
    if (offer != _Offer.none && editable != null && around != null) {
      final boxes = editable.getBoxesForSelection(around);
      if (boxes.isNotEmpty) {
        // Under the last line of the selection, from where it starts on it.
        final last = boxes.last;
        final lineBoxes = boxes.where((b) => (b.bottom - last.bottom).abs() < 1);
        final left = lineBoxes.map((b) => b.left).reduce((a, b) => a < b ? a : b);
        anchor = editable.localToGlobal(Offset(left, last.bottom + 4));
      }
    }
    if (anchor == null) offer = _Offer.none;
    if (offer == _Offer.none) {
      if (_popup.isShowing) _popup.hide();
      if (_offer != _Offer.none) setState(() => _offer = _Offer.none);
      return;
    }
    setState(() {
      _offer = offer;
      _anchor = anchor;
    });
    if (!_popup.isShowing) _popup.show();
  }

  void _setWeight(double w) {
    _c.value = applyWeight(_c.value, w);
  }

  void _nudge(double by) {
    if (_c.selection.isCollapsed && groupAt(_c.text, _c.selection) == null) return;
    _setWeight(weightAt(_c.value) + by);
  }

  void _replaceWord(String word) {
    final wrong = _c.misspelledAt(_c.selection.baseOffset);
    if (wrong == null) return;
    final (start, old) = wrong;
    _c.value = TextEditingValue(
      text: _c.text.replaceRange(start, start + old.length, word),
      selection: TextSelection.collapsed(offset: start + word.length),
    );
  }

  Widget _buildPopup(BuildContext context) {
    final anchor = _anchor;
    if (anchor == null || _offer == _Offer.none) return const SizedBox.shrink();
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? MediaQuery.sizeOf(context);
    final local = overlay?.globalToLocal(anchor) ?? anchor;
    const popupWidth = _sliderWidth + 70;
    final left = local.dx.clamp(8.0, (size.width - popupWidth - 8).clamp(8.0, double.infinity));
    final top = local.dy.clamp(8.0, size.height - 64);
    return Positioned(
      left: left,
      top: top,
      // Part of the text field as far as "tapped outside" goes, so using it
      // keeps the selection.
      child: TextFieldTapRegion(
        child: ExcludeFocus(
          child: Material(
            color: Palette.raised,
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: Palette.line),
            ),
            child: _offer == _Offer.weight ? _weightPopup() : _spellingPopup(),
          ),
        ),
      ),
    );
  }

  Widget _weightPopup() {
    final group = groupAt(_c.text, _c.selection);
    final weight = _dragging ?? group?.weight ?? plainWeight;
    return Padding(
      key: const ValueKey<String>('weight-popup'),
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 42,
            child: Text(
              formatWeight(weight),
              key: const ValueKey<String>('weight-value'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: weight == plainWeight ? Palette.text : (weight > plainWeight ? const Color(0xFFF0A35E) : Palette.accent),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(
            width: _sliderWidth,
            height: 48,
            child: SliderTheme(
              // Bigger than the app's hairline sliders: this one is dragged
              // by a thumb.
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: Palette.accent,
                inactiveTrackColor: Palette.line,
                thumbColor: Palette.text,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
                tickMarkShape: SliderTickMarkShape.noTickMark,
              ),
              child: Slider(
                key: const ValueKey<String>('weight-slider'),
                value: weight.clamp(minWeight, maxWeight),
                min: minWeight,
                max: maxWeight,
                divisions: ((maxWeight - minWeight) / weightStep).round(),
                onChangeStart: (v) => setState(() => _dragging = v),
                onChanged: (v) {
                  setState(() => _dragging = snapWeight(v));
                  _setWeight(v);
                },
                onChangeEnd: (v) {
                  _setWeight(v);
                  setState(() => _dragging = null);
                },
              ),
            ),
          ),
          IconButton(
            tooltip: 'Remove the weight',
            iconSize: 18,
            onPressed: group == null
                ? null
                : () {
                    _c.value = removeWeight(_c.value);
                  },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _spellingPopup() {
    final wrong = _c.misspelledAt(_c.selection.baseOffset);
    if (wrong == null) return const SizedBox.shrink();
    final word = wrong.$2;
    final suggestions = _c.spelling?.suggest(word) ?? const <String>[];
    return ConstrainedBox(
      key: const ValueKey<String>('spelling-popup'),
      constraints: const BoxConstraints(maxWidth: _sliderWidth + 70),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (suggestions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Text('No suggestions', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
              ),
            for (final s in suggestions)
              ActionChip(
                label: Text(s, style: const TextStyle(fontSize: 13)),
                backgroundColor: Palette.panel,
                side: const BorderSide(color: Palette.line),
                onPressed: () => _replaceWord(s),
              ),
            TextButton(
              onPressed: () => _c.ignore(word),
              child: const Text('Ignore'),
            ),
            if (widget.onAddWord != null)
              TextButton(
                onPressed: () {
                  widget.onAddWord!(word);
                  _c.ignore(word);
                },
                child: const Text('Add to dictionary'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _contextMenu(BuildContext context, EditableTextState editable) {
    final items = [...editable.contextMenuButtonItems];
    final wrong = _c.misspelledAt(_c.selection.baseOffset);
    if (wrong != null) {
      final fixes = _c.spelling?.suggest(wrong.$2, count: 3) ?? const [];
      items.insertAll(0, [
        for (final s in fixes)
          ContextMenuButtonItem(
            label: s,
            onPressed: () {
              ContextMenuController.removeAny();
              _replaceWord(s);
            },
          ),
      ]);
    }
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: editable.contextMenuAnchors, buttonItems: items);
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _popup,
      overlayChildBuilder: _buildPopup,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp, control: true): () => _nudge(weightStep),
          const SingleActivator(LogicalKeyboardKey.arrowDown, control: true): () => _nudge(-weightStep),
        },
        child: TextField(
          key: _fieldKey,
          controller: _c,
          focusNode: _focus,
          autofocus: widget.autofocus,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          keyboardType: TextInputType.multiline,
          // Our own check, the same on every platform.
          spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
          autocorrect: false,
          contextMenuBuilder: _contextMenu,
          style: const TextStyle(fontSize: 14, height: 1.5, color: Palette.text),
          cursorColor: Palette.accent,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            alignLabelWithHint: true,
            filled: true,
            fillColor: Palette.raised,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Palette.accent),
            ),
          ),
        ),
      ),
    );
  }
}

enum _Offer { none, weight, spelling }
