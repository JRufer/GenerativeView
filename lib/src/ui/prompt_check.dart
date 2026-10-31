import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../theme.dart';
import 'kit.dart';

/// Under the prompt in the metadata panel: which of its phrases content
/// search's model sees in the picture. Shown at once for a picture content
/// search has already looked at; for one it has not, a button to look.
/// Nothing at all until the model is installed.
class PromptCheckView extends StatefulWidget {
  const PromptCheckView({super.key, required this.state, required this.item, required this.prompt});
  final AppState state;
  final MediaItem item;
  final String prompt;

  @override
  State<PromptCheckView> createState() => _PromptCheckViewState();
}

class _PromptCheckViewState extends State<PromptCheckView> {
  PromptCheck? _check;

  /// The picture and prompt [_check] is for.
  String? _for;
  bool _looking = false;
  String? _error;

  /// Whether the model was installed when last looked, so installing it
  /// brings the check in.
  bool _installed = false;

  String get _key => '${widget.item.path}\n${widget.prompt}';

  @override
  void initState() {
    super.initState();
    _installed = widget.state.content.value.installed;
    widget.state.content.addListener(_contentChanged);
    _load();
  }

  @override
  void didUpdateWidget(PromptCheckView old) {
    super.didUpdateWidget(old);
    if (old.item.path != widget.item.path || old.prompt != widget.prompt) _load();
  }

  @override
  void dispose() {
    widget.state.content.removeListener(_contentChanged);
    super.dispose();
  }

  void _contentChanged() {
    final installed = widget.state.content.value.installed;
    // The pass over the folder may have just looked at this picture.
    if (installed != _installed || (_check == null && !_looking)) {
      _installed = installed;
      _load();
    }
  }

  Future<void> _load({bool look = false}) async {
    final key = _key;
    if (!widget.state.content.value.installed || widget.prompt.trim().isEmpty) {
      if (_check != null || _for != null) {
        setState(() {
          _check = null;
          _for = null;
        });
      }
      return;
    }
    if (look) setState(() => _looking = true);
    try {
      final check = await widget.state.checkPrompt(widget.item, widget.prompt, look: look);
      if (!mounted || key != _key) return;
      setState(() {
        _check = check;
        _for = key;
        _error = null;
      });
    } catch (e) {
      if (!mounted || key != _key) return;
      setState(() {
        _for = key;
        _error = look ? '$e' : null;
      });
    } finally {
      if (mounted && look) setState(() => _looking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.state.content.value.installed || widget.prompt.trim().isEmpty || _for != _key) {
      return const SizedBox.shrink();
    }
    final check = _check;
    if (check == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                key: const ValueKey<String>('prompt-check-look'),
                onPressed: _looking ? null : () => _load(look: true),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 30),
                  foregroundColor: Palette.muted,
                ),
                icon: _looking
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.fact_check_outlined, size: 16),
                label: const Text('Check the prompt against the picture', style: TextStyle(fontSize: 12)),
              ),
              if (_error != null)
                Text(_error!, style: const TextStyle(fontSize: 11.5, color: Palette.danger)),
            ],
          ),
        ),
      );
    }
    if (check.checked == 0) return const SizedBox.shrink();
    final all = check.seen == check.checked;
    return Padding(
      key: const ValueKey<String>('prompt-check'),
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tooltip(
            message: 'What content search\'s model sees in the picture, phrase by phrase. It is good at what a '
                'picture is of and weak at small details, counting and text, so a phrase not seen may still be '
                'there; quality words ("masterpiece", "8k") are not looked for.',
            child: Row(
              children: [
                Icon(all ? Icons.task_alt : Icons.fact_check_outlined, size: 14, color: all ? Palette.accent : Palette.faint),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Seen in the picture: ${check.seen} of ${check.checked} phrases · tap one for more',
                    key: const ValueKey<String>('prompt-check-summary'),
                    style: const TextStyle(fontSize: 12, color: Palette.muted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final p in check.phrases)
                PhraseChip(
                  key: ValueKey<String>('prompt-phrase-${p.text}'),
                  text: p.text,
                  look: !p.checked ? PhraseLook.unchecked : (p.seen ? PhraseLook.seen : PhraseLook.missing),
                  tooltip: !p.checked
                      ? 'Asks for quality, which the model cannot see: not looked for'
                      : (p.seen ? 'Seen in the picture' : 'Not seen in the picture'),
                  onPressAt: (at) => showPhraseMenu(context, at: at, state: widget.state, item: widget.item, phrase: p.text, seen: p.seen),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
