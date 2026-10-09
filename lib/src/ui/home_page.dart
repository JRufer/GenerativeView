import 'dart:io';

import 'package:flutter/material.dart';

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
  // Keeps the grid's state (scroll position, loaded tiles) when the layout
  // flips between side-by-side and overlay panels.
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'content');
  bool _storageOk = true;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.addListener(_onState);
    state.searchText.text = state.query;
    _checkStorage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    state.removeListener(_onState);
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

  bool get _typing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null && context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _closeOverlays() => state.closePanels();

  // ------------------------------------------------------------ layout

  @override
  Widget build(BuildContext context) {
    final focus = state.mode == ViewMode.focus;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _sideBySideWidth;
        state.narrowLayout = narrow;
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
                  TopBar(state: state),
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
        if (_typing) FocusManager.instance.primaryFocus?.unfocus();
      },
      // Nothing in the content area takes keyboard focus; see ShortcutLayer.
      child: ExcludeFocus(
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
          ExcludeFocus(child: TextButton(onPressed: onGrant, child: const Text('Allow access'))),
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
