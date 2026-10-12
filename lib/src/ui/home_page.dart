import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../platform.dart';
import '../theme.dart';
import 'focus_view.dart';
import 'folder_panel.dart';
import 'media_grid.dart';
import 'meta_panel.dart';
import 'remix_status.dart';
import 'top_bar.dart';
import 'upscale_dialog.dart';

/// Below this width the side panels slide over the content instead of
/// sitting beside it.
const double _sideBySideWidth = 820;

/// The metadata footer never squeezes the content below this height, and
/// steps aside altogether when it would get no useful height of its own
/// (a small window, or the soft keyboard up on a phone).
const double _minContentHeight = 160;
const double _minFooterHeight = 96;
const double _footerHandleHeight = 18;

/// How long a panel takes to open or close.
const Duration _panelMotion = Duration(milliseconds: 220);
const Curve _panelCurve = Curves.easeOutCubic;

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
  late final StreamSubscription<String> _notices;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.addListener(_onState);
    _notices = state.notices.listen((message) {
      if (mounted) toast(context, message);
    });
    state.searchText.text = state.query;
    _checkStorage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    state.removeListener(_onState);
    _notices.cancel();
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
                  if ((state.contentSearch || state.lookingAlike) && !focus)
                    _ContentBanner(state: state),
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _body(constraints.maxWidth),
                        Positioned(right: 12, bottom: 12, child: UpscaleJobs(state: state)),
                        // Over the grid, top and centre where it is seen. In
                        // the focus view it sits in the top bar instead, so
                        // nothing covers the picture.
                        if (!focus)
                          Positioned(
                            top: 12,
                            left: 0,
                            right: 0,
                            child: Center(child: RemixStatus(state: state)),
                          ),
                      ],
                    ),
                  ),
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
  ///
  /// Either panel opens and closes over a moment rather than at once.
  Widget _body(double width) {
    final focus = state.mode == ViewMode.focus;
    final showLeft = state.leftOpen && !focus;
    // Lying over the content, the panels take turns: folders first.
    final floating = state.narrowLayout && !state.portraitLayout;
    final showRight = state.rightOpen && !(floating && showLeft);
    final time = motion(context, _panelMotion);
    // Built once, not once per frame of the panels' movement.
    final content = _content();
    final folders = ColoredBox(
      color: Palette.panel,
      child: FolderPanel(
        state: state,
        onPicked: state.narrowLayout ? state.toggleLeft : null,
      ),
    );
    final meta = _metaPanel();
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: showLeft ? 1 : 0),
      duration: time,
      curve: _panelCurve,
      builder: (context, left, _) => TweenAnimationBuilder<double>(
        tween: Tween<double>(end: showRight ? 1 : 0),
        duration: time,
        curve: _panelCurve,
        builder: (context, right, _) => _layout(
          width: width,
          content: content,
          folders: folders,
          meta: meta,
          left: left,
          right: right,
        ),
      ),
    );
  }

  /// The body with the folder panel [left] of the way open and the metadata
  /// panel [right] of the way open (0 = shut and not there, 1 = open).
  Widget _layout({
    required double width,
    required Widget content,
    required Widget folders,
    required Widget meta,
    required double left,
    required double right,
  }) {
    final narrow = state.narrowLayout;
    final portrait = state.portraitLayout;

    Widget body = content;
    if (!narrow) {
      body = Row(
        children: [
          if (left > 0)
            // Slides out from the window's edge, pushing the content over.
            _Reveal(
              amount: left,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: state.leftWidth, child: folders),
                  _DragHandle(
                    onDrag: (dx) => state.setLeftWidth(state.leftWidth + dx),
                  ),
                ],
              ),
            ),
          Expanded(child: body),
          if (right > 0 && !portrait)
            _Reveal(
              amount: right,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DragHandle(
                    onDrag: (dx) => state.setRightWidth(state.rightWidth - dx),
                  ),
                  SizedBox(width: state.rightWidth, child: meta),
                ],
              ),
            ),
        ],
      );
    }
    if (portrait) body = _withFooter(body, meta, right);
    if (!narrow) return body;

    final panelWidth = (width * 0.86).clamp(240.0, 380.0).toDouble();
    final overRight = portrait ? 0.0 : right;
    final shade = math.max(left, overRight);
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        if (shade > 0)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeOverlays,
            child: ColoredBox(
              color: Color.fromRGBO(0, 0, 0, 0.6 * shade),
            ),
          ),
        if (left > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: FractionalTranslation(
              translation: Offset(left - 1, 0),
              child: SizedBox(width: panelWidth, child: folders),
            ),
          ),
        if (overRight > 0)
          Align(
            alignment: Alignment.centerRight,
            child: FractionalTranslation(
              translation: Offset(1 - overRight, 0),
              child: SizedBox(width: panelWidth, child: meta),
            ),
          ),
      ],
    );
  }

  /// [above], with the metadata panel [open] of the way up from under it.
  Widget _withFooter(Widget above, Widget meta, double open) {
    return LayoutBuilder(
      builder: (context, box) {
        final room = box.maxHeight - _footerHandleHeight;
        final height = math.min(
          room * state.bottomShare,
          room - _minContentHeight,
        );
        final show = open > 0 && height >= _minFooterHeight;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: above),
            if (show)
              _Reveal(
                amount: open,
                axis: Axis.vertical,
                alignment: Alignment.topCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DragHandle(
                      axis: Axis.vertical,
                      // From the height on screen, which may be less than
                      // the saved share asks for.
                      onDrag: (dy) => state.setBottomShare(
                        math.min(state.bottomShare, height / room) - dy / room,
                      ),
                    ),
                    SizedBox(height: height, child: meta),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Shows [amount] of [child] (0 = none of it, 1 = all), taking only that
/// much room along [axis]. The child keeps its full size throughout and is
/// pinned at [alignment], so a panel pinned by the edge it shares with the
/// content appears to slide out from under the window's edge.
class _Reveal extends StatelessWidget {
  const _Reveal({
    required this.amount,
    required this.alignment,
    required this.child,
    this.axis = Axis.horizontal,
  });
  final double amount;
  final Alignment alignment;
  final Axis axis;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The same wrapping whether moving or at rest, so that what is inside
    // keeps its state when the movement ends.
    return ClipRect(
      child: Align(
        alignment: alignment,
        widthFactor: axis == Axis.horizontal ? amount : null,
        heightFactor: axis == Axis.vertical ? amount : null,
        child: child,
      ),
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

/// What content search needs, or is busy with, when it is switched on:
/// its model fetched, the model being fetched, pictures being looked at.
/// Nothing at all once it is simply ready.
class _ContentBanner extends StatelessWidget {
  const _ContentBanner({required this.state});
  final AppState state;

  static String _megabytes(int bytes) => (bytes / 1000000).toStringAsFixed(0);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ContentStatus>(
      valueListenable: state.content,
      builder: (context, status, _) => ValueListenableBuilder<DownloadProgress?>(
        valueListenable: state.download,
        builder: (context, progress, _) {
          const text = TextStyle(fontSize: 13, color: Palette.text, height: 1.35);
          const note = TextStyle(fontSize: 12.5, color: Palette.muted);
          if (progress != null) {
            return _strip(
              icon: Icons.download,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Downloading the content search model: '
                    '${_megabytes(progress.received)} of ${_megabytes(progress.total)} MB',
                    style: text,
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: progress.total > 0
                        ? progress.received / progress.total
                        : null,
                    minHeight: 3,
                    backgroundColor: Palette.line,
                    color: Palette.accent,
                  ),
                ],
              ),
              action: 'Cancel',
              onAction: state.cancelDownload,
            );
          }
          if (!status.known) return const SizedBox.shrink();
          if (!status.installed) {
            return _strip(
              icon: Icons.image_search,
              body: Text(
                [
                  'Content search finds pictures by what they show. It needs '
                      'a model: a one-time download of '
                      '${_megabytes(status.downloadBytes)} MB from '
                      'huggingface.co. After that it runs on this device and '
                      'nothing leaves it.',
                  ?status.error,
                ].join('\n'),
                style: text,
              ),
              action: status.error == null ? 'Download' : 'Try again',
              onAction: state.downloadModel,
            );
          }
          if (status.error != null) {
            return _strip(
              icon: Icons.error_outline,
              body: Text(status.error!, style: text),
            );
          }
          if (status.indexing && status.todo > 0) {
            return _strip(
              icon: Icons.image_search,
              slim: true,
              body: Row(
                children: [
                  Text(
                    'Looking at pictures: ${status.done} of ${status.todo}',
                    style: note,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: status.done / status.todo,
                      minHeight: 2,
                      backgroundColor: Palette.line,
                      color: Palette.muted,
                    ),
                  ),
                ],
              ),
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }

  Widget _strip({
    required IconData icon,
    required Widget body,
    String? action,
    VoidCallback? onAction,
    bool slim = false,
  }) {
    return Container(
      key: const ValueKey<String>('content-banner'),
      width: double.infinity,
      color: Palette.raised,
      padding: EdgeInsets.fromLTRB(16, slim ? 6 : 10, 10, slim ? 6 : 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Palette.muted),
          const SizedBox(width: 12),
          Expanded(child: body),
          if (action != null)
            ExcludeFocus(
              child: TextButton(onPressed: onAction, child: Text(action)),
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
