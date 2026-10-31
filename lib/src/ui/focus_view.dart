import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/media_image.dart';
import '../core/models.dart';
import '../theme.dart';
import 'image_menu.dart';
import 'thumb_image.dart';
import 'video_page.dart';

/// One image at a time. Swipe (or use the keyboard) to move through the
/// folder; zoom with a pinch, the wheel or the up and down keys, and drag
/// to look around while zoomed in. Tap to switch to full screen and back
/// (F11 does the same); in full screen, pinching out past the fitted size
/// drops back to the focus view. Double tap to go back to the grid,
/// right-click or press and hold for the image's menu.
class FocusView extends StatefulWidget {
  const FocusView({super.key, required this.state});
  final AppState state;

  @override
  State<FocusView> createState() => _FocusViewState();
}

/// How far a finger has to travel sideways, as a share of the view's width,
/// before the pager takes it for a swipe. Until then the touch is left to the
/// image, so a pinch has room to get going without turning the page.
const double _swipeDeadZone = 0.18;

/// The dead zone never shrinks below this, nor grows past the larger one, in
/// logical pixels, so it stays usable on small phones and big unfolded ones.
const double _swipeDeadZoneMin = 64;
const double _swipeDeadZoneMax = 200;

/// The swipe dead zone for a view of this size, in logical pixels.
double _swipeSlop(MediaQueryData media) => (media.size.width * _swipeDeadZone)
    .clamp(_swipeDeadZoneMin, _swipeDeadZoneMax)
    .toDouble();

/// [media] with the touch slop set to the swipe dead zone.
MediaQueryData _withSwipeSlop(MediaQueryData media) => media.copyWith(
  gestureSettings: DeviceGestureSettings(touchSlop: _swipeSlop(media)),
);

class _FocusViewState extends State<FocusView> {
  late final PageController _pages;
  bool _zoomed = false;

  /// Fingers on the screen. With two or more down it is a pinch, and the
  /// pager is held still.
  int _touches = 0;

  /// The picture [_zoomed] is about.
  int _shownIndex = -1;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _pages = PageController(
      initialPage: state.selectedIndex < 0 ? 0 : state.selectedIndex,
    );
    _shownIndex = state.selectedIndex;
    state.addListener(_onState);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _precacheAround(state.selectedIndex);
    });
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    _pages.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    // A new picture starts fitted: the one left behind resets itself, but
    // it is no longer the active page by then, so its word that it is no
    // longer zoomed never reaches us. Without this the pager would stay
    // held after zooming in and stepping on with the keys.
    if (state.selectedIndex != _shownIndex) {
      _shownIndex = state.selectedIndex;
      _zoomed = false;
    }
    setState(() {});
    // Keyboard navigation, or the list shifting under us as files arrive:
    // either way make the pager show the selected item again.
    final target = state.selectedIndex;
    if (target < 0 || !_pages.hasClients) return;
    final current = _pages.page?.round();
    if (current != target) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _pages.hasClients &&
            _pages.page?.round() != state.selectedIndex &&
            state.selectedIndex >= 0) {
          _pages.jumpToPage(state.selectedIndex);
        }
      });
    }
  }

  void _precacheAround(int index) {
    final items = state.items;
    for (final i in [index + 1, index - 1, index + 2]) {
      if (i < 0 || i >= items.length) continue;
      final item = items[i];
      if (item.isVideo) continue;
      precacheImage(mediaImage(item), context, onError: (_, _) {});
    }
  }

  void _touchDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touches++;
    if (_touches == 2) setState(() {});
  }

  void _touchGone(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch || _touches == 0) return;
    _touches--;
    if (_touches == 1) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = state.items;
    if (items.isEmpty) return const SizedBox.expand();
    final media = MediaQuery.of(context);
    final held = _zoomed || _touches >= 2;
    return ColoredBox(
      color: Palette.canvas,
      child: Listener(
        onPointerDown: _touchDown,
        onPointerUp: _touchGone,
        onPointerCancel: _touchGone,
        // The pager reads its drag threshold from here; the pages put the
        // usual one back, so pinching and panning the image start at once.
        child: MediaQuery(
          data: _withSwipeSlop(media),
          child: _pager(items, media, held),
        ),
      ),
    );
  }

  Widget _pager(ItemList items, MediaQueryData media, bool held) {
    return PageView.builder(
      controller: _pages,
      allowImplicitScrolling: true,
      physics: held
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: items.length,
      onPageChanged: (index) {
        if (index != state.selectedIndex) state.select(index);
        _precacheAround(index);
      },
      itemBuilder: (context, index) {
        if (index >= items.length) return const SizedBox.shrink();
        final item = items[index];
        final active = index == state.selectedIndex;
        return MediaQuery(
          data: media,
          child: _FocusPage(
            key: ValueKey<int>(item.id),
            state: state,
            item: item,
            active: active,
            onZoomChanged: (zoomed) {
              if (active && zoomed != _zoomed) {
                setState(() => _zoomed = zoomed);
              }
            },
          ),
        );
      },
    );
  }
}

/// The chip that says how far in the image is zoomed, as a percentage of its
/// real size. It is coloured, and stays, at exactly 100 %.
class ZoomChip extends StatelessWidget {
  const ZoomChip({super.key, required this.label, required this.highlighted});
  final String label;

  /// One image pixel per screen pixel.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted ? Palette.accent : const Color(0xD9151518),
        borderRadius: BorderRadius.circular(12),
        border: highlighted ? null : Border.all(color: Palette.line),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: highlighted ? const Color(0xFF0B1020) : Palette.text,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _FocusPage extends StatefulWidget {
  const _FocusPage({
    super.key,
    required this.state,
    required this.item,
    required this.active,
    required this.onZoomChanged,
  });

  final AppState state;
  final MediaItem item;
  final bool active;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_FocusPage> createState() => _FocusPageState();
}

/// Zoom stops are this many percentage points of the image's real size apart.
const double _zoomStep = 10;

/// Slack when comparing percentages, so 229.9999 counts as 230.
const double _zoomSlack = 0.05;

/// The furthest in the image can be zoomed, as a percentage of its real
/// size. An image so small that it is fitted to the view above this is
/// zoomed no further than fitted.
const double maxZoomPercent = 400;

/// In full screen a pinch may shrink the picture to this share of the
/// smallest it otherwise goes...
const double _fullScreenMinScale = 0.5;

/// ...and letting go below this share leaves full screen.
const double _popOutScale = 0.85;

/// Zoom works in percentages of the image's real size: 100 % is one image
/// pixel per screen pixel. The wheel moves from one multiple of ten to the
/// next; a pinch is free while the fingers are down and settles on the
/// nearest multiple when they lift. The size at which the image just fits
/// the view is a stop too, whatever percentage that happens to be.
///
/// The viewer underneath never scales below 1, so at scale 1 the image is
/// drawn at the smallest size it can be zoomed out to: fitted to the view,
/// or at 100 % where fitting it means enlarging it.
class _FocusPageState extends State<_FocusPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  final ValueNotifier<bool> _chipShown = ValueNotifier<bool>(false);
  late final AnimationController _glide;
  late final StreamSubscription<int> _keys;

  Size _view = Size.zero;
  double _pixelRatio = 1;

  /// True while this state is moving the transform itself.
  bool _busy = false;
  bool _wasZoomed = false;
  double _lastScale = 1;
  int _pointers = 0;
  double _glideFrom = 1;
  double _glideTo = 1;

  /// The glide under way is to the fitted size, wherever that ends up while
  /// the view around the picture is still growing or shrinking.
  bool _glideFit = false;
  Timer? _settle;
  Timer? _chipTimer;

  MediaItem get item => widget.item;

  @override
  void initState() {
    super.initState();
    _glide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
    )..addListener(_onGlide);
    _transform.addListener(_onTransform);
    _keys = widget.state.zoomSteps.listen(_onZoomKey);
  }

  @override
  void didUpdateWidget(_FocusPage old) {
    super.didUpdateWidget(old);
    // Leaving a page puts it back to fit-to-screen.
    if (old.active && !widget.active) _reset();
  }

  @override
  void dispose() {
    _settle?.cancel();
    _chipTimer?.cancel();
    _keys.cancel();
    _glide.dispose();
    _transform.dispose();
    _chipShown.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- geometry

  double get _scale => _transform.value.getMaxScaleOnAxis();

  /// Screen pixels per image pixel when the image just fits the view, or
  /// null when that cannot be known (a video, a file of unknown size).
  double? get _fit {
    if (item.isVideo || item.width <= 0 || item.height <= 0 || _view.isEmpty) {
      return null;
    }
    return math.min(_view.width / item.width, _view.height / item.height) *
        _pixelRatio;
  }

  /// The share of the view the image is laid out in at scale 1: all of it,
  /// or less when fitting the view would enlarge the image past 100 %.
  double get _base {
    final fit = _fit;
    return fit == null || fit <= 1 ? 1 : 1 / fit;
  }

  /// The scale at which the image just fits the view.
  double get _fitScale => 1 / _base;

  /// Zoom percentage per unit of scale.
  double get _unit => (_fit ?? 1) * _base * 100;

  /// The furthest in the image goes: [maxZoomPercent], or the fitted size
  /// when that is further still.
  double get _maxScale =>
      math.max(maxZoomPercent / _unit, _fitScale);

  bool get _zoomed => _scale > _fitScale * 1.01;

  /// In full screen a pinch may take the picture below fitted, to leave.
  bool get _canPopOut => widget.state.fullScreen && _fit != null;

  /// The zoom as a percentage of the image's real size, when that is known.
  double? get _percent => _fit == null ? null : _scale * _unit;

  /// The size the image is drawn at when the scale is 1.
  Size get _imageAtBase {
    final fit = _fit;
    if (fit == null) return _view;
    final each = fit / _pixelRatio * _base;
    return Size(item.width * each, item.height * each);
  }

  Matrix4 _matrix(double scale, double dx, double dy) => Matrix4.identity()
    ..setEntry(0, 0, scale)
    ..setEntry(1, 1, scale)
    ..setEntry(0, 3, dx)
    ..setEntry(1, 3, dy);

  /// [scale], with the image in the middle of the view.
  Matrix4 _centred(double scale) => _matrix(
    scale,
    _view.width * (1 - scale) / 2,
    _view.height * (1 - scale) / 2,
  );

  void _set(Matrix4 matrix) {
    _busy = true;
    _transform.value = matrix;
    _busy = false;
    _lastScale = _scale;
  }

  void _reset() {
    _settle?.cancel();
    _glide.stop();
    _glideFit = false;
    _set(_centred(_fitScale));
    _chipShown.value = false;
    _noteZoomed();
  }

  /// Tell the pager (and our own viewer) when the image goes from fitted to
  /// zoomed in or back: one pans the image, the other swipes between images.
  void _noteZoomed() {
    if (_zoomed == _wasZoomed) return;
    _wasZoomed = _zoomed;
    // Whoever moved the transform may be in the middle of a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
      widget.onZoomChanged(_zoomed);
    });
  }

  /// Called while laying out, with the room there is for the image.
  void _layout(Size view, double pixelRatio) {
    if (view == _view && pixelRatio == _pixelRatio) return;
    if (_glideFit && _glide.isAnimating) {
      // Already on its way to fitted; the glide aims at the new size.
      _view = view;
      _pixelRatio = pixelRatio;
      return;
    }
    final fitted = _view.isEmpty || (_scale - _fitScale).abs() < 1e-3;
    final percent = _scale * _unit;
    _view = view;
    _pixelRatio = pixelRatio;
    // Fitted stays fitted; anything else keeps its percentage.
    final scale = fitted
        ? _fitScale
        : (percent / _unit).clamp(1.0, _maxScale).toDouble();
    _set(_centred(scale));
    _noteZoomed();
  }

  // ---------------------------------------------------------------- zooming

  /// Keeps the image where it belongs whatever moved it: in the middle of
  /// the view along an axis it does not fill, edge to edge along one it does.
  void _onTransform() {
    if (_busy) return;
    final matrix = _transform.value;
    final scale = matrix.getMaxScaleOnAxis();
    final image = _imageAtBase;
    double settle(double offset, double view, double base) {
      if (base * scale <= view + 0.5) return view * (1 - scale) / 2;
      final low = view - scale * (view + base) / 2;
      final high = -scale * (view - base) / 2;
      return offset.clamp(low, high).toDouble();
    }

    if (!_view.isEmpty) {
      final dx = settle(matrix.entry(0, 3), _view.width, image.width);
      final dy = settle(matrix.entry(1, 3), _view.height, image.height);
      if ((dx - matrix.entry(0, 3)).abs() > 0.01 ||
          (dy - matrix.entry(1, 3)).abs() > 0.01) {
        _busy = true;
        _transform.value = matrix.clone()
          ..setEntry(0, 3, dx)
          ..setEntry(1, 3, dy);
        _busy = false;
      }
    }
    if ((scale - _lastScale).abs() > 1e-5) {
      _lastScale = scale;
      _showChip();
      _settleSoon();
    }
    _noteZoomed();
  }

  void _showChip() {
    _chipShown.value = true;
    _chipTimer?.cancel();
    _chipTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) _chipShown.value = false;
    });
  }

  /// The scale one notch of the wheel away from [scale]: the next stop.
  double _nextStop(double scale, {required bool zoomIn}) {
    final unit = _unit;
    final percent = scale * unit;
    final fitted = _fitScale * unit;
    double next;
    if (zoomIn) {
      next = (((percent + _zoomSlack) / _zoomStep).floor() + 1) * _zoomStep;
      if (percent < fitted - _zoomSlack && next > fitted + _zoomSlack) {
        next = fitted;
      }
    } else {
      next = (((percent - _zoomSlack) / _zoomStep).ceil() - 1) * _zoomStep;
      if (percent > fitted + _zoomSlack && next < fitted - _zoomSlack) {
        next = fitted;
      }
    }
    return (next / unit).clamp(1.0, _maxScale).toDouble();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || item.isVideo) return;
    if (event.scrollDelta.dy == 0) return;
    // Worked out now, before the viewer around us applies its own smooth
    // wheel zoom, and put in place once everything has seen the event: ours
    // is the zoom that stands. The point under the pointer stays put.
    final scene = event.localPosition;
    final focal = MatrixUtils.transformPoint(_transform.value, scene);
    final scale = _nextStop(_scale, zoomIn: event.scrollDelta.dy < 0);
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (!mounted) return;
      _glide.stop();
      _glideFit = false;
      _transform.value = _matrix(
        scale,
        focal.dx - scale * scene.dx,
        focal.dy - scale * scene.dy,
      );
    });
  }

  /// After a pinch (and whatever glide follows it) has come to rest, move to
  /// the nearest stop.
  void _settleSoon() {
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 160), _settleNow);
  }

  void _settleNow() {
    _settle = null;
    if (!mounted || _pointers > 0 || _glide.isAnimating || item.isVideo) return;
    if (widget.state.fullScreen && _scale < _popOutScale) return;
    final unit = _unit;
    final percent = _scale * unit;
    final fitted = _fitScale * unit;
    var nearest = (percent / _zoomStep).round() * _zoomStep;
    if ((percent - fitted).abs() < (percent - nearest).abs()) nearest = fitted;
    final scale = (nearest / unit).clamp(1.0, _maxScale).toDouble();
    if ((scale - _scale).abs() < 1e-4) return;
    _glideFrom = _scale;
    _glideTo = scale;
    _glide.forward(from: 0);
  }

  void _onGlide() {
    final t = Curves.easeOut.transform(_glide.value);
    final to = _glideFit ? _fitScale : _glideTo;
    _zoomAboutMiddle(_glideFrom + (to - _glideFrom) * t);
    if (_glide.isCompleted) _glideFit = false;
  }

  /// A pinch let go of. In full screen, shrunk past the smallest the
  /// picture normally goes: back to the focus view, the picture gliding to
  /// fit it as the bars and panels come back.
  void _onInteractionEnd(ScaleEndDetails _) {
    if (widget.state.fullScreen &&
        !item.isVideo &&
        _scale < _popOutScale) {
      _settle?.cancel();
      _glideFit = true;
      _glideFrom = _scale;
      _glide.forward(from: 0);
      widget.state.exitFullScreen();
    }
    widget.onZoomChanged(_zoomed);
  }

  /// Sets the zoom to [scale], keeping what is in the middle of the view
  /// there.
  void _zoomAboutMiddle(double scale) {
    final focal = _view.center(Offset.zero);
    final scene = _transform.toScene(focal);
    _transform.value = _matrix(
      scale,
      focal.dx - scale * scene.dx,
      focal.dy - scale * scene.dy,
    );
  }

  /// Glides to [scale] about the middle of the view.
  void _glideToScale(double scale) {
    scale = scale.clamp(1.0, _maxScale).toDouble();
    _settle?.cancel();
    _glideFit = false;
    _glideFrom = _scale;
    _glideTo = scale;
    if ((_glideTo - _glideFrom).abs() < 1e-4) {
      _glide.stop();
      return;
    }
    _glide.forward(from: 0);
  }

  /// [steps] stops in, or out when negative: the up and down keys. Held keys carry on from where the
  /// last nudge was heading, not from wherever the glide has got to.
  void _zoomBy(int steps) {
    if (item.isVideo || _fit == null) return;
    var target = _glide.isAnimating ? _glideTo : _scale;
    for (var i = 0; i < steps.abs(); i++) {
      target = _nextStop(target, zoomIn: steps > 0);
    }
    _glideToScale(target);
  }

  void _onZoomKey(int steps) {
    if (!mounted || !widget.active) return;
    _zoomBy(steps);
  }

  void _pointerGone(PointerEvent _) {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers == 0) _settleSoon();
  }

  // ---------------------------------------------------------------- build

  /// How far in the image is, shown while zooming and whenever it is at
  /// exactly 100 %. Small, and out of the way of the pointer.
  Widget _chip() {
    return ValueListenableBuilder<bool>(
      valueListenable: _chipShown,
      builder: (context, shown, _) => ValueListenableBuilder<Matrix4>(
        valueListenable: _transform,
        builder: (context, _, _) {
          final percent = _percent;
          if (percent == null) return const SizedBox.shrink();
          final exact = (percent - 100).abs() < 0.5;
          return AnimatedOpacity(
            opacity: exact || shown ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: ZoomChip(label: '${percent.round()}%', highlighted: exact),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        _layout(box.biggest, pixelRatio);
        final Widget content;
        if (item.isVideo) {
          content = VideoPage(
            item: item,
            cache: widget.state.thumbs,
            active: widget.active,
            playbackAvailable: widget.state.videoPlayback,
          );
        } else {
          content = Center(
            child: FractionallySizedBox(
              widthFactor: _base,
              heightFactor: _base,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The thumbnail is already in memory: show it at once, and
                  // let the full image replace it when it has decoded.
                  ThumbImage(
                    cache: widget.state.thumbs,
                    item: item,
                    tier: 1,
                    fit: BoxFit.contain,
                    showPlaceholderIcon: false,
                  ),
                  Image(
                    image: mediaImage(item),
                    key: ValueKey<String>(item.version),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (context, error, stack) => const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Palette.faint,
                        size: 40,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              onPointerDown: (_) => _pointers++,
              onPointerUp: _pointerGone,
              onPointerCancel: _pointerGone,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.state.toggleFullScreen,
                onDoubleTap: widget.state.closeFocus,
                onSecondaryTapUp: (details) => showImageMenu(
                  context,
                  widget.state,
                  item,
                  details.globalPosition,
                ),
                onLongPressStart: (details) => showImageMenu(
                  context,
                  widget.state,
                  item,
                  details.globalPosition,
                ),
                // The viewer's one-finger pan has to go further than the
                // pager's dead zone before it claims the touch, or it would
                // take every swipe; a pinch (fingers spreading or closing)
                // still starts at the usual few pixels. Inside, the usual
                // settings again.
                child: MediaQuery(
                  data: _withSwipeSlop(media),
                  child: InteractiveViewer(
                    transformationController: _transform,
                    minScale: _canPopOut ? _fullScreenMinScale : 1,
                    // The viewer will not shrink its child smaller than the
                    // view inside a tight boundary; where it may, the bounds
                    // are lifted and [_onTransform] keeps the picture centred.
                    boundaryMargin: _canPopOut
                        ? const EdgeInsets.all(double.infinity)
                        : EdgeInsets.zero,
                    maxScale: _maxScale,
                    panEnabled: _zoomed,
                    scaleEnabled: !item.isVideo,
                    onInteractionEnd: _onInteractionEnd,
                    child: MediaQuery(
                      data: media,
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerSignal: _onPointerSignal,
                        child: SizedBox.expand(child: content),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (!item.isVideo)
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: IgnorePointer(child: Center(child: _chip())),
              ),
          ],
        );
      },
    );
  }
}
