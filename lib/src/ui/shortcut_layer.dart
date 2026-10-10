import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'meta_panel.dart';

/// Counts routes above the home page, so shortcuts can stand down while a
/// menu or dialog is open.
class RouteCounter extends NavigatorObserver {
  int depth = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => depth++;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => depth--;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      depth--;
}

/// Keyboard shortcuts for the whole window.
///
/// This sits above the navigator, so whatever holds keyboard focus — a text
/// field, or nothing in particular — is below it and its unhandled keys
/// arrive here. Everything except the text fields is wrapped in
/// [ExcludeFocus] elsewhere, so a clicked button never keeps focus and
/// swallows Enter or Space.
class ShortcutLayer extends StatelessWidget {
  const ShortcutLayer({
    super.key,
    required this.state,
    required this.routes,
    required this.child,
  });

  final AppState state;
  final RouteCounter routes;
  final Widget child;

  bool get _typing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _stopTyping() => FocusManager.instance.primaryFocus?.unfocus();

  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // The home page is route one; anything above it owns the keyboard.
    if (routes.depth > 1) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed;
    final search = state.searchText;

    if (_typing) {
      if (key == LogicalKeyboardKey.escape) {
        if (search.text.isNotEmpty && state.searchFocus.hasFocus) {
          search.clear();
          state.setQuery('');
        }
        _stopTyping();
        return KeyEventResult.handled;
      }
      // Down from the search box drops into the results.
      if (key == LogicalKeyboardKey.arrowDown && state.searchFocus.hasFocus) {
        _stopTyping();
        state.move(state.selectedIndex < 0 ? 1 : 0);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if ((ctrl && key == LogicalKeyboardKey.keyF) ||
        key == LogicalKeyboardKey.slash) {
      if (state.mode != ViewMode.grid) return KeyEventResult.ignored;
      state.searchFocus.requestFocus();
      search.selection = TextSelection(
        baseOffset: 0,
        extentOffset: search.text.length,
      );
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyC) {
      _copyPrompt(context);
      return KeyEventResult.handled;
    }
    if (ctrl &&
        (key == LogicalKeyboardKey.equal ||
            key == LogicalKeyboardKey.add ||
            key == LogicalKeyboardKey.numpadAdd)) {
      state.setTileSize(state.tileSize * 1.15);
      return KeyEventResult.handled;
    }
    if (ctrl &&
        (key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.numpadSubtract)) {
      state.setTileSize(state.tileSize / 1.15);
      return KeyEventResult.handled;
    }
    if (ctrl || keyboard.isAltPressed || keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.keyI ||
        key == LogicalKeyboardKey.bracketRight) {
      state.toggleRight();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.bracketLeft) {
      state.toggleLeft();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC && state.mode == ViewMode.grid) {
      state.toggleCrop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f5) {
      state.rescan();
      return KeyEventResult.handled;
    }

    final focus = state.mode == ViewMode.focus;
    final columns = focus ? 1 : state.gridColumns;
    final page = focus ? 10 : state.gridColumns * state.gridRowsPerPage;

    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyD) {
      state.move(1);
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.keyA) {
      state.move(-1);
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.keyS) {
      state.move(columns);
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.keyW) {
      state.move(-columns);
    } else if (key == LogicalKeyboardKey.pageDown) {
      state.move(page);
    } else if (key == LogicalKeyboardKey.pageUp) {
      state.move(-page);
    } else if (key == LogicalKeyboardKey.home) {
      state.move(-state.items.length);
    } else if (key == LogicalKeyboardKey.end) {
      state.move(state.items.length);
    } else if (key == LogicalKeyboardKey.backspace && focus) {
      state.move(-1);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      // Enter and Space both flip between the grid and the focus view.
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (focus) {
        state.closeFocus();
      } else {
        state.openFocus();
      }
    } else if (key == LogicalKeyboardKey.escape) {
      if (focus) {
        state.closeFocus();
      } else if (state.leftFloats || state.rightFloats) {
        state.closeOverlays();
      } else {
        state.clearSelection();
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _copyPrompt(BuildContext context) async {
    final item = state.selected;
    if (item == null) return;
    try {
      final info = await state.metadata(item);
      if (!context.mounted || info.prompt.isEmpty) return;
      copyText(context, info.prompt, 'prompt');
    } catch (_) {
      // Nothing to copy from a file we cannot read.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) => _onKey(context, event),
      child: child,
    );
  }
}
