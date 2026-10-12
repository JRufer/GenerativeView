import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/models.dart';
import 'filter_sheet.dart';
import 'image_menu.dart';
import 'notes_widgets.dart';
import 'remix_dialog.dart';
import 'shortcuts_overlay.dart';
import 'upscale_dialog.dart';

/// The app's navigator, so shortcuts (which sit above it) can open panels.
final GlobalKey<NavigatorState> appNavigator = GlobalKey<NavigatorState>(debugLabel: 'app');

/// A context under the navigator, for opening panels from a shortcut.
BuildContext? get _panelContext => appNavigator.currentState?.overlay?.context;

/// The number of stars a digit key gives, or null for any other key.
int? _stars(LogicalKeyboardKey key) {
  const digits = [
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
  ];
  const pad = [
    LogicalKeyboardKey.numpad0,
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
  ];
  final i = digits.indexOf(key);
  if (i >= 0) return i;
  final j = pad.indexOf(key);
  return j >= 0 ? j : null;
}

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

    // `?` (Shift and /) or F1: the list of shortcuts.
    if (key == LogicalKeyboardKey.f1 ||
        key == LogicalKeyboardKey.question ||
        (key == LogicalKeyboardKey.slash && keyboard.isShiftPressed)) {
      final panel = _panelContext;
      if (panel != null) showShortcuts(panel);
      return KeyEventResult.handled;
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
      // Ctrl+C copies the prompt; with Shift, the image itself.
      final item = state.selected;
      if (item != null) {
        if (keyboard.isShiftPressed) {
          copyImage(context, item);
        } else {
          copyPrompt(context, state, item);
        }
      }
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
    if (event is! KeyRepeatEvent) {
      final handled = _pictureKey(key, keyboard.isShiftPressed);
      if (handled) return KeyEventResult.handled;
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

  /// The keys that act on the selected picture, and those that open
  /// panels. True if [key] was one of them.
  bool _pictureKey(LogicalKeyboardKey key, bool shift) {
    final panel = _panelContext;
    final item = state.selected;
    final stars = _stars(key);
    if (stars != null) {
      if (item != null) state.rateSelected(stars, toggle: stars > 0);
      return true;
    }
    if (key == LogicalKeyboardKey.keyF) {
      if (panel != null && state.folder != null) openFilters(panel, state);
      return true;
    }
    if (key == LogicalKeyboardKey.keyN) {
      state.toggleFollowNew();
      return true;
    }
    if (item == null) {
      return [
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyX,
        LogicalKeyboardKey.keyU,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyL,
        LogicalKeyboardKey.keyR,
      ].contains(key);
    }
    if (key == LogicalKeyboardKey.keyP) {
      state.flagSelected(Flag.keep);
    } else if (key == LogicalKeyboardKey.keyX) {
      state.flagSelected(Flag.reject);
    } else if (key == LogicalKeyboardKey.keyU && shift) {
      if (panel != null) openUpscale(panel, state, item);
    } else if (key == LogicalKeyboardKey.keyU) {
      state.changeNotes(flag: Flag.none);
    } else if (key == LogicalKeyboardKey.keyB) {
      if (panel != null) showCollectionPicker(panel, state, [item]);
    } else if (key == LogicalKeyboardKey.keyL) {
      state.findSimilar(item);
    } else if (key == LogicalKeyboardKey.keyR) {
      if (panel != null) openRemix(panel, state, item);
    } else {
      return false;
    }
    return true;
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
