import 'dart:io';
import 'dart:math' as math;

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

/// The metadata footer never squeezes the content below this height, and
/// steps aside altogether when it would get no useful height of its own
/// (a small window, or the soft keyboard up on a phone).
const double _minContentHeight = 160;
const double _minFooterHeight = 96;
const double _footerHandleHeight = 18;

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
  // Likewise the metadata panel, as it moves between the side and the foot
  // of the window when a tablet turns.
  final GlobalKey _metaKey = GlobalKey(debugLabel: 'metadata');
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
    return context != null &&
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _closeOverlays() => state.closeOverlays();

  // ------------------------------------------------------------ layout

  @override
  Widget build(BuildContext context) {
    final focus = state.mode == ViewMode.focus;
    return LayoutBuilder(
      builder: (context, constraints) {
        state.narrowLayout = constraints.maxWidth < _sideBySideWidth;
        // The whole window, so the soft keyboard coming up changes nothing.
        state.portraitLayout = constraints.maxWidth < constraints.maxHeight;
        final overlayOpen = state.leftFloats || state.rightFloats;
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
                  Expanded(child: _body(constraints.maxWidth)),
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

  Widget _metaPanel() {
    return ColoredBox(
      color: Palette.panel,
      child: MetaPanel(key: _metaKey, state: state),
    );
  }

  /// Where everything under the top bar goes.
  ///
  /// The folder panel sits beside the content, or slides over it when the
  /// window is narrow. The metadata panel does the same in a landscape
  /// window; in a portrait one it is a footer across the full width instead,
  /// which leaves the grid or the focused image all the width there is.
  Widget _body(double width) {
    final focus = state.mode == ViewMode.focus;
    final narrow = state.narrowLayout;
    final portrait = state.portraitLayout;
    final showLeft = state.leftOpen && !focus;

    Widget body = _content();
    if (!narrow) {
      body = Row(
        children: [
          if (showLeft) ...[
            SizedBox(
              width: state.leftWidth,
              child: ColoredBox(
                color: Palette.panel,
                child: FolderPanel(state: state),
              ),
            ),
            _DragHandle(
              onDrag: (dx) => state.setLeftWidth(state.leftWidth + dx),
            ),
          ],
          Expanded(child: body),
          if (state.rightOpen && !portrait) ...[
            _DragHandle(
              onDrag: (dx) => state.setRightWidth(state.rightWidth - dx),
            ),
            SizedBox(width: state.rightWidth, child: _metaPanel()),
          ],
        ],
      );
    }
    if (portrait) body = _withFooter(body);
    if (!narrow) return body;

    final panelWidth = (width * 0.86).clamp(240.0, 380.0).toDouble();
    final showRight = state.rightFloats && !showLeft;
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
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
            child: SizedBox(width: panelWidth, child: _metaPanel()),
          ),
      ],
    );
  }

  /// [above], with the metadata panel under it when that is open.
  Widget _withFooter(Widget above) {
    return LayoutBuilder(
      builder: (context, box) {
        final room = box.maxHeight - _footerHandleHeight;
        final height = math.min(
          room * state.bottomShare,
          room - _minContentHeight,
        );
        final show = state.rightOpen && height >= _minFooterHeight;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: above),
            if (show) ...[
              _DragHandle(
                axis: Axis.vertical,
                // From the height on screen, which may be less than the
                // saved share asks for.
                onDrag: (dy) => state.setBottomShare(
                  math.min(state.bottomShare, height / room) - dy / room,
                ),
              ),
              SizedBox(height: height, child: _metaPanel()),
            ],
          ],
        );
      },
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
          ExcludeFocus(
            child: TextButton(
              onPressed: onGrant,
              child: const Text('Allow access'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A thin strip between panels that resizes them when dragged.
class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onDrag, this.axis = Axis.horizontal});

  /// Called with how far the handle has moved along [axis].
  final ValueChanged<double> onDrag;

  /// The way the handle moves: sideways between columns, or up and down on
  /// top of the footer.
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    if (axis == Axis.vertical) {
      // Taller than its sideways twin, with a grip: this one gets dragged by
      // thumb on a tablet held upright.
      return MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
          child: Container(
            height: _footerHandleHeight,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Palette.panel,
              border: Border(top: BorderSide(color: Palette.line)),
            ),
            child: Container(
              width: 36,
              height: 4,
              decoration: const BoxDecoration(
                color: Palette.line,
                borderRadius: BorderRadius.all(Radius.circular(2)),
              ),
            ),
          ),
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: const SizedBox(
          width: 7,
          child: Center(
            child: VerticalDivider(width: 1, thickness: 1, color: Palette.line),
          ),
        ),
      ),
    );
  }
}
