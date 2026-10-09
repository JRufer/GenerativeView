import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../platform.dart';
import '../theme.dart';
import 'focus_view.dart';
import 'folder_panel.dart';
import 'media_grid.dart';
import 'meta_panel.dart';
import 'top_bar.dart';

/// Below this width the side panels slide over the content instead of
/// sitting beside it.
const double _sideBySideWidth = 820;

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state});
  final AppState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final FocusNode _searchFocus = FocusNode(debugLabel: 'search');
  final TextEditingController _search = TextEditingController();
  // Keeps the grid's state (scroll position, loaded tiles) when the layout
  // flips between side-by-side and overlay panels.
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'content');
  bool _storageOk = true;
  bool _narrow = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Shortcuts are handled for the whole window rather than through the
    // focus tree: clicking a panel or leaving the search box must never
    // leave the keyboard dead.
    HardwareKeyboard.instance.addHandler(_onKey);
    state.addListener(_onState);
    _search.text = state.query;
    _checkStorage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    state.removeListener(_onState);
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      // Coming back from the permission screen, or from generating more
      // images in another app.
      _checkStorage();
      if (state.folder != null) state.rescan();
    }
  }

  Future<void> _checkStorage() async {
    final ok = await hasStorageAccess();
    if (!mounted) return;
    if (ok != _storageOk) {
      setState(() => _storageOk = ok);
      if (ok) {
        await state.loadPlaces();
        final folder = state.folder;
        if (folder != null) await state.openFolder(folder);
      }
    }
  }

  Future<void> _grantStorage() async {
    await requestStorageAccess();
    await _checkStorage();
  }

  // ------------------------------------------------------------ keyboard

  bool get _typing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null && context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _stopTyping() => FocusManager.instance.primaryFocus?.unfocus();

  /// Returns true when the key was ours, which stops it going any further.
  bool _onKey(KeyEvent event) {
    if (!mounted || event is KeyUpEvent) return false;
    // A menu or dialog is open above us: the keys belong to it.
    if (Navigator.of(context).canPop()) return false;
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;

    if (_typing) {
      if (key == LogicalKeyboardKey.escape) {
        if (_search.text.isNotEmpty && _searchFocus.hasFocus) {
          _search.clear();
          state.setQuery('');
        }
        _stopTyping();
        return true;
      }
      // Down from the search box drops into the results.
      if (key == LogicalKeyboardKey.arrowDown && _searchFocus.hasFocus) {
        _stopTyping();
        state.move(state.selectedIndex < 0 ? 1 : 0);
        return true;
      }
      return false;
    }

    if ((ctrl && key == LogicalKeyboardKey.keyF) || key == LogicalKeyboardKey.slash) {
      if (state.mode != ViewMode.grid) return false;
      _searchFocus.requestFocus();
      _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.keyC) {
      _copyPrompt();
      return true;
    }
    if (ctrl && (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.numpadAdd)) {
      state.setTileSize(state.tileSize * 1.15);
      return true;
    }
    if (ctrl && (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract)) {
      state.setTileSize(state.tileSize / 1.15);
      return true;
    }
    if (ctrl || HardwareKeyboard.instance.isAltPressed || HardwareKeyboard.instance.isMetaPressed) return false;

    if (key == LogicalKeyboardKey.keyI || key == LogicalKeyboardKey.bracketRight) {
      state.toggleRight();
      return true;
    }
    if (key == LogicalKeyboardKey.bracketLeft) {
      state.toggleLeft();
      return true;
    }
    if (key == LogicalKeyboardKey.f5) {
      state.rescan();
      return true;
    }

    final focus = state.mode == ViewMode.focus;
    final columns = focus ? 1 : state.gridColumns;
    final page = focus ? 10 : state.gridColumns * state.gridRowsPerPage;

    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyD) {
      state.move(1);
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyA) {
      state.move(-1);
    } else if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.keyS) {
      state.move(columns);
    } else if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.keyW) {
      state.move(-columns);
    } else if (key == LogicalKeyboardKey.pageDown) {
      state.move(page);
    } else if (key == LogicalKeyboardKey.pageUp) {
      state.move(-page);
    } else if (key == LogicalKeyboardKey.home) {
      state.move(-state.items.length);
    } else if (key == LogicalKeyboardKey.end) {
      state.move(state.items.length);
    } else if (key == LogicalKeyboardKey.space && focus) {
      state.move(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
    } else if (key == LogicalKeyboardKey.backspace && focus) {
      state.move(-1);
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.space) {
      if (event is KeyRepeatEvent) return true;
      if (focus) {
        state.closeFocus();
      } else if (state.selectedIndex >= 0) {
        state.openFocus();
      } else {
        return false;
      }
    } else if (key == LogicalKeyboardKey.escape) {
      if (focus) {
        state.closeFocus();
      } else if (_narrow && (state.leftOpen || state.rightOpen)) {
        _closeOverlays();
      } else {
        state.clearSelection();
      }
    } else {
      return false;
    }
    return true;
  }

  Future<void> _copyPrompt() async {
    final item = state.selected;
    if (item == null) return;
    try {
      final info = await state.metadata(item);
      if (!mounted || info.prompt.isEmpty) return;
      copyText(context, info.prompt, 'prompt');
    } catch (_) {}
  }

  void _closeOverlays() {
    if (state.leftOpen) state.toggleLeft();
    if (state.rightOpen) state.toggleRight();
  }

  // ------------------------------------------------------------ layout

  @override
  Widget build(BuildContext context) {
    final focus = state.mode == ViewMode.focus;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _sideBySideWidth;
        _narrow = narrow;
        final overlayOpen = narrow && (state.leftOpen || state.rightOpen);
        return PopScope(
          canPop: !focus && !overlayOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (overlayOpen) {
              _closeOverlays();
            } else {
              state.closeFocus();
            }
          },
          child: Scaffold(
            backgroundColor: Palette.canvas,
            body: SafeArea(
              child: Column(
                children: [
                  TopBar(state: state, searchController: _search, searchFocus: _searchFocus),
                  _ScanBar(state: state),
                  if (!_storageOk) _StorageBanner(onGrant: _grantStorage),
                  Expanded(child: narrow ? _narrowBody(constraints.maxWidth) : _wideBody()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _content() {
    final focus = state.mode == ViewMode.focus;
    return Listener(
      key: _contentKey,
      // Touching the content ends text entry (and puts the soft keyboard away).
      onPointerDown: (_) {
        if (_typing) _stopTyping();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The grid stays alive under the focus view so it keeps its place.
          Offstage(
            offstage: focus,
            child: MediaGrid(state: state),
          ),
          if (focus) FocusView(state: state),
        ],
      ),
    );
  }

  Widget _wideBody() {
    final focus = state.mode == ViewMode.focus;
    return Row(
      children: [
        if (state.leftOpen && !focus) ...[
          SizedBox(
            width: state.leftWidth,
            child: ColoredBox(color: Palette.panel, child: FolderPanel(state: state)),
          ),
          _DragHandle(onDrag: (dx) => state.setLeftWidth(state.leftWidth + dx)),
        ],
        Expanded(child: _content()),
        if (state.rightOpen) ...[
          _DragHandle(onDrag: (dx) => state.setRightWidth(state.rightWidth - dx)),
          SizedBox(
            width: state.rightWidth,
            child: ColoredBox(color: Palette.panel, child: MetaPanel(state: state)),
          ),
        ],
      ],
    );
  }

  Widget _narrowBody(double width) {
    final focus = state.mode == ViewMode.focus;
    final panelWidth = (width * 0.86).clamp(240.0, 380.0).toDouble();
    final showLeft = state.leftOpen && !focus;
    final showRight = state.rightOpen && !showLeft;
    return Stack(
      fit: StackFit.expand,
      children: [
        _content(),
        if (showLeft || showRight)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeOverlays,
            child: const ColoredBox(color: Color(0x99000000)),
          ),
        if (showLeft)
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: panelWidth,
              child: ColoredBox(
                color: Palette.panel,
                child: FolderPanel(state: state, onPicked: state.toggleLeft),
              ),
            ),
          ),
        if (showRight)
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: panelWidth,
              child: ColoredBox(color: Palette.panel, child: MetaPanel(state: state)),
            ),
          ),
      ],
    );
  }
}

/// A hairline that shows indexing progress and is otherwise invisible.
class _ScanBar extends StatelessWidget {
  const _ScanBar({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ScanStatus>(
      valueListenable: state.scan,
      builder: (context, scan, _) {
        if (!scan.running) return const SizedBox(height: 2);
        return SizedBox(
          height: 2,
          child: LinearProgressIndicator(
            value: scan.total > 0 ? scan.done / scan.total : null,
            minHeight: 2,
            backgroundColor: Palette.line,
            color: Palette.accent,
          ),
        );
      },
    );
  }
}

class _StorageBanner extends StatelessWidget {
  const _StorageBanner({required this.onGrant});
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Palette.raised,
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18, color: Palette.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              Platform.isAndroid
                  ? 'GenerativeView needs “All files access” to browse your image folders.'
                  : 'GenerativeView cannot read your folders.',
              style: const TextStyle(fontSize: 13, color: Palette.text),
            ),
          ),
          TextButton(onPressed: onGrant, child: const Text('Allow access')),
        ],
      ),
    );
  }
}

/// A thin strip between panels that resizes them when dragged.
class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onDrag});
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: const SizedBox(
          width: 7,
          child: Center(child: VerticalDivider(width: 1, thickness: 1, color: Palette.line)),
        ),
      ),
    );
  }
}
