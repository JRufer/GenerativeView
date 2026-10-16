import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
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

/// The strip between a side panel and the content: wide enough to take
/// hold of with a finger, with the grip in the middle.
const double _sideHandleWidth = 14;

/// How long a panel takes to open or close.
const Duration _panelMotion = Duration(milliseconds: 220);
const Curve _panelCurve = Curves.easeOutCubic;

/// How long the move between the focus view and full screen takes: the top
/// bar, panels and safe-area margins fold away (or back) while the picture
/// grows to fill the room, all in one quick movement.
const Duration _fullScreenMotion = Duration(milliseconds: 180);
const Curve _fullScreenCurve = Curves.easeOutCubic;

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

  /// Whether the system's bars / window frame were last put away.
  bool _systemFullScreen = false;

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
    if (_systemFullScreen) setSystemFullScreen(false);
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    final full = state.fullScreen;
    if (full != _systemFullScreen) {
      _systemFullScreen = full;
      setSystemFullScreen(full);
    }
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
    final full = state.fullScreen;
    return LayoutBuilder(
      builder: (context, constraints) {
        state.narrowLayout = constraints.maxWidth < _sideBySideWidth;
        // The whole window, so the soft keyboard coming up changes nothing.
        state.portraitLayout = constraints.maxWidth < constraints.maxHeight;
        final overlayOpen = state.leftFloats || state.rightFloats;
        final time = motion(context, _fullScreenMotion);
        // Built once, not once per frame of the full-screen movement.
        final chrome = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TopBar(state: state),
            _ScanBar(state: state),
            if (!_storageOk) _StorageBanner(onGrant: _grantStorage),
            if ((state.contentSearch || state.lookingAlike) && !focus)
              _ContentBanner(state: state),
          ],
        );
        final content = Stack(
          fit: StackFit.expand,
          children: [
            _body(constraints.maxWidth),
            Positioned(
              right: 12,
              bottom: 12,
              child: _FadeAway(
                gone: full,
                time: time,
                child: UpscaleJobs(state: state),
              ),
            ),
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
        );
        return PopScope(
          canPop: !focus && !overlayOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (overlayOpen) {
              _closeOverlays();
            } else if (!state.exitFullScreen()) {
              state.closeFocus();
            }
          },
          child: Scaffold(
            backgroundColor: Palette.canvas,
            // The system's insets (as the scaffold hands them to its body)
            // are kept clear of, except in full screen, where the picture
            // runs to the very edges. Easing to and from them keeps the bars
            // coming and going on Android from making the layout jump.
            body: Builder(
              builder: (context) => AnimatedPadding(
                duration: time,
                curve: _fullScreenCurve,
                padding: full ? EdgeInsets.zero : MediaQuery.paddingOf(context),
                child: MediaQuery.removePadding(
                  context: context,
                  removeLeft: true,
                  removeTop: true,
                  removeRight: true,
                  removeBottom: true,
                  child: Column(
                    children: [
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(end: full ? 0 : 1),
                        duration: time,
                        curve: _fullScreenCurve,
                        child: chrome,
                        builder: (context, shown, bar) => _Reveal(
                          amount: shown,
                          axis: Axis.vertical,
                          alignment: Alignment.bottomCenter,
                          child: IgnorePointer(
                            ignoring: full,
                            child: Opacity(
                              opacity: shown.clamp(0.0, 1.0).toDouble(),
                              child: bar,
                            ),
                          ),
                        ),
                      ),
                      Expanded(child: content),
                    ],
                  ),
                ),
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
    final full = state.fullScreen;
    final showRight =
        state.rightOpen && !full && !(floating && showLeft);
    // Going to or from full screen the panel moves with everything else.
    final time = motion(
      context,
      full || state.mode == ViewMode.focus ? _fullScreenMotion : _panelMotion,
    );
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
                    key: const ValueKey<String>('resize-left'),
                    size: state.leftWidth,
                    min: minLeftWidth,
                    grows: 1,
                    onResize: state.setLeftWidth,
                    onClose: state.toggleLeft,
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
                    key: const ValueKey<String>('resize-right'),
                    size: state.rightWidth,
                    min: minRightWidth,
                    grows: -1,
                    onResize: state.setRightWidth,
                    onClose: state.toggleRight,
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
                      key: const ValueKey<String>('resize-bottom'),
                      axis: Axis.vertical,
                      // From the height on screen, which may be less than
                      // the saved share asks for.
                      size: height,
                      min: math.max(room * minBottomShare, _minFooterHeight),
                      grows: -1,
                      onResize: (px) => state.setBottomShare(px / room),
                      onClose: state.toggleRight,
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

/// Fades [child] out, and stops it taking taps, while [gone].
class _FadeAway extends StatelessWidget {
  const _FadeAway({required this.gone, required this.time, required this.child});
  final bool gone;
  final Duration time;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: gone,
      child: AnimatedOpacity(
        opacity: gone ? 0 : 1,
        duration: time,
        curve: _fullScreenCurve,
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

/// A strip between a panel and the content that resizes the panel when
/// dragged, with a grip in the middle that is easy to find and hold with a
/// thumb.
///
/// Dragged past the panel's smallest size it sticks there; dragged on past
/// half of that, the panel snaps shut, as if its button had been pressed,
/// and opens again at the size it had before.
class _DragHandle extends StatefulWidget {
  const _DragHandle({
    super.key,
    required this.size,
    required this.min,
    required this.grows,
    required this.onResize,
    required this.onClose,
    this.axis = Axis.horizontal,
  });

  /// The panel's size along [axis] now, in pixels.
  final double size;

  /// The smallest it may be.
  final double min;

  /// +1 if dragging right (or down) makes the panel bigger, -1 if smaller.
  final double grows;

  /// Called with the size, in pixels, the panel should be.
  final ValueChanged<double> onResize;

  /// Shut the panel.
  final VoidCallback onClose;

  /// The way the handle moves: sideways between columns, or up and down on
  /// top of the footer.
  final Axis axis;

  @override
  State<_DragHandle> createState() => _DragHandleState();
}

class _DragHandleState extends State<_DragHandle> {
  /// The size the drag started from, and the size it now asks for, which
  /// may be below the smallest allowed.
  double? _start;
  double _wanted = 0;
  bool _hover = false;

  bool get _dragging => _start != null;

  /// Held at its smallest, and about to snap shut if dragged further.
  bool get _stuck => _dragging && _wanted < widget.min;

  void _begin() => setState(() {
        _start = widget.size;
        _wanted = widget.size;
      });

  void _update(double delta) {
    final start = _start;
    if (start == null) return;
    _wanted += delta * widget.grows;
    if (_wanted < widget.min / 2) {
      // Far enough: shut it, and leave its size as it was for next time.
      _start = null;
      widget.onResize(start);
      widget.onClose();
      setState(() {});
      return;
    }
    widget.onResize(math.max(_wanted, widget.min));
    setState(() {});
  }

  void _end() => setState(() => _start = null);

  @override
  Widget build(BuildContext context) {
    final vertical = widget.axis == Axis.vertical;
    final lit = _dragging || _hover;
    final gripColor = _stuck ? Palette.danger : (lit ? Palette.accent : Palette.muted);
    final grip = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: vertical ? 36 : 10,
      height: vertical ? 10 : 36,
      decoration: BoxDecoration(
        color: Palette.panel,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: gripColor, width: 1.5),
      ),
    );
    final Widget strip = vertical
        ? Container(
            height: _footerHandleHeight,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Palette.panel,
              border: Border(top: BorderSide(color: Palette.line)),
            ),
            child: grip,
          )
        : SizedBox(
            width: _sideHandleWidth,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Positioned.fill(
                  child: Center(child: VerticalDivider(width: 1, thickness: 1, color: Palette.line)),
                ),
                grip,
              ],
            ),
          );
    return MouseRegion(
      cursor: vertical ? SystemMouseCursors.resizeRow : SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Follows the finger from where it went down, slop and all.
        dragStartBehavior: DragStartBehavior.down,
        onVerticalDragStart: vertical ? (_) => _begin() : null,
        onVerticalDragUpdate: vertical ? (d) => _update(d.delta.dy) : null,
        onVerticalDragEnd: vertical ? (_) => _end() : null,
        onVerticalDragCancel: vertical ? _end : null,
        onHorizontalDragStart: vertical ? null : (_) => _begin(),
        onHorizontalDragUpdate: vertical ? null : (d) => _update(d.delta.dx),
        onHorizontalDragEnd: vertical ? null : (_) => _end(),
        onHorizontalDragCancel: vertical ? null : _end,
        child: strip,
      ),
    );
  }
}
