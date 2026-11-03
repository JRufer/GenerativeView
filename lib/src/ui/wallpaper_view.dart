import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/media_image.dart';
import '../core/models.dart';
import '../core/wallpaper.dart';
import '../platform.dart';
import '../theme.dart';
import 'meta_panel.dart' show toast;
import 'sheet.dart';
import 'upscale_dialog.dart';

/// Open the positioning screen for [item], and say how it went afterwards.
Future<void> openWallpaper(BuildContext context, AppState state, MediaItem item) async {
  final device = await wallpaperDevice();
  if (!context.mounted) return;
  if (device == null || item.width <= 0 || item.height <= 0) {
    toast(context, 'Could not set this picture as wallpaper');
    return;
  }
  final done = await Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (context) => WallpaperPage(
        item: item,
        device: device,
        onUpscale: (context) => openUpscale(context, state, item),
      ),
    ),
  );
  if (done != null && context.mounted) toast(context, done);
}

/// Places a picture in a frame the shape of each screen, then sets it. The
/// controls sit beside the picture, never on it.
class WallpaperPage extends StatefulWidget {
  const WallpaperPage({
    super.key,
    required this.item,
    required this.device,
    required this.onUpscale,
    this.write = setWallpaper,
  });

  final MediaItem item;
  final WallpaperDevice device;
  final void Function(BuildContext context) onUpscale;

  /// What each write did, in order. A test passes its own.
  final Future<List<bool>> Function(String path, List<WallpaperWrite> writes) write;

  @override
  State<WallpaperPage> createState() => _WallpaperPageState();
}

class _WallpaperPageState extends State<WallpaperPage> {
  late String _screen = widget.device.current;
  WallpaperUse _use = WallpaperUse.both;
  final Map<String, WallpaperView> _views = {};
  bool _busy = false;
  double _pinchStart = 1;

  List<WallpaperScreen> get _shown =>
      _screen == bothScreens ? widget.device.screens : [widget.device.screen(_screen)];

  WallpaperView _view(String id) => _views[id] ?? const WallpaperView();

  Rect _crop(WallpaperScreen screen) =>
      wallpaperCrop(widget.item.width, widget.item.height, screen, _view(screen.id));

  void _moved(WallpaperScreen screen, ScaleUpdateDetails details, double pixelsPerImagePixel) {
    final old = _view(screen.id);
    final zoom = (_pinchStart * details.scale).clamp(1.0, maxWallpaperZoom);
    final dx = details.focalPointDelta.dx / pixelsPerImagePixel / widget.item.width;
    final dy = details.focalPointDelta.dy / pixelsPerImagePixel / widget.item.height;
    final moved = WallpaperView(cx: old.cx - dx, cy: old.cy - dy, zoom: zoom);
    // Keep the centre where the crop really is, so a drag past the edge
    // does not have to be undone before the picture moves back.
    final crop = wallpaperCrop(widget.item.width, widget.item.height, screen, moved);
    setState(() {
      _views[screen.id] = WallpaperView(
        cx: crop.center.dx / widget.item.width,
        cy: crop.center.dy / widget.item.height,
        zoom: zoom,
      );
    });
  }

  Future<void> _apply() async {
    setState(() => _busy = true);
    final writes = [
      for (final screen in _shown)
        WallpaperWrite(
          screenId: screen.id,
          which: wallpaperWhich(_use, screen.id),
          crop: _crop(screen),
          active: screen.id == widget.device.current,
        ),
    ];
    final results = await widget.write(widget.item.path, writes);
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = [for (var i = 0; i < writes.length; i++) if (i < results.length && results[i]) writes[i].screenId];
    if (ok.length == writes.length) {
      Navigator.of(context).pop('Wallpaper set on ${wallpaperPlace(_screen, _use)}');
    } else if (ok.isEmpty) {
      toast(context, 'Could not set the wallpaper');
    } else {
      Navigator.of(context).pop('Wallpaper set on ${wallpaperPlace(ok.single, _use)}; the other screen did not change');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final sideways = size.width > size.height;
    final preview = LayoutBuilder(builder: (context, box) => ClipRect(child: _preview(box.biggest)));
    final controls = _controls(sideways);
    return Scaffold(
      backgroundColor: Palette.canvas,
      appBar: AppBar(
        backgroundColor: Palette.panel,
        toolbarHeight: 48,
        titleSpacing: 0,
        scrolledUnderElevation: 0,
        title: const Text('Set as wallpaper', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: sideways
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: preview),
                  Container(
                    width: 320,
                    color: Palette.panel,
                    child: SingleChildScrollView(child: controls),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: preview),
                  Container(color: Palette.panel, child: controls),
                ],
              ),
      ),
    );
  }

  Widget _preview(Size area) {
    final shown = _shown;
    if (shown.length == 1) {
      final screen = shown.single;
      final height = (area.height - 28).clamp(1.0, double.infinity);
      var frame = Size(height * screen.aspect, height);
      final widest = (area.width - 32).clamp(1.0, double.infinity);
      if (frame.width > widest) frame = Size(widest, widest / screen.aspect);
      final scale = frame.width / _crop(screen).width;
      // Drags start anywhere, the dimmed part of the picture too.
      return _gestures(
        screen,
        scale,
        ColoredBox(color: Colors.transparent, child: Center(child: _frame(screen, frame, dimmed: true))),
      );
    }
    const gap = 20.0, labelled = 24.0;
    final shapes = shown.fold<double>(0, (sum, s) => sum + s.aspect);
    final byWidth = (area.width - 28 - gap) / shapes;
    final height = (area.height - 28 - labelled).clamp(1.0, byWidth);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(width: gap),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _gestures(
                shown[i],
                height * shown[i].aspect / _crop(shown[i]).width,
                _frame(shown[i], Size(height * shown[i].aspect, height), dimmed: false),
              ),
              const SizedBox(height: 6),
              Text('${shown[i].label} screen', style: const TextStyle(fontSize: 12, color: Palette.muted)),
            ],
          ),
        ],
      ],
    );
  }

  Widget _gestures(WallpaperScreen screen, double scale, Widget child) => GestureDetector(
    onScaleStart: (_) => _pinchStart = _view(screen.id).zoom,
    onScaleUpdate: (details) => _moved(screen, details, scale),
    child: child,
  );

  Widget _frame(WallpaperScreen screen, Size frame, {required bool dimmed}) {
    final crop = _crop(screen);
    final scale = frame.width / crop.width;
    Widget picture() => Positioned(
      left: -crop.left * scale,
      top: -crop.top * scale,
      width: widget.item.width * scale,
      height: widget.item.height * scale,
      child: Image(image: mediaImage(widget.item), fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.medium),
    );
    return SizedBox.fromSize(
      size: frame,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (dimmed) Opacity(opacity: 0.32, child: Stack(clipBehavior: Clip.none, children: [SizedBox.fromSize(size: frame), picture()])),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                picture(),
                IgnorePointer(child: _ScreenHints(lock: _use == WallpaperUse.lock)),
              ],
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Palette.text),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(bool sideways) {
    final device = widget.device;
    final lines = <String>[];
    var small = false;
    for (final screen in _shown) {
      final crop = _crop(screen);
      final used = '${crop.width.round()} × ${crop.height.round()}';
      final whole = '${screen.width} × ${screen.height}';
      lines.add(device.hasCover ? '${screen.label}: uses $used of $whole' : 'Uses $used of this picture. This screen is $whole.');
      if (crop.width < screen.width - 1 || crop.height < screen.height - 1) small = true;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (device.hasCover)
            _Choices<String>(
              label: 'Screen',
              value: _screen,
              options: const {mainScreen: 'Main', coverScreen: 'Cover', bothScreens: 'Both'},
              onPick: _busy ? null : (v) => setState(() => _screen = v),
            ),
          _Choices<WallpaperUse>(
            label: 'Use on',
            value: _use,
            options: const {WallpaperUse.home: 'Home', WallpaperUse.lock: 'Lock', WallpaperUse.both: 'Both'},
            onPick: _busy ? null : (v) => setState(() => _use = v),
          ),
          Row(
            children: [
              Expanded(
                child: Text(lines.join('\n'), style: const TextStyle(fontSize: 12, height: 1.3, color: Palette.muted)),
              ),
              if (small) TextButton(onPressed: _busy ? null : () => widget.onUpscale(context), child: const Text('Upscale…')),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _apply,
            child: Text(_busy ? 'Setting…' : 'Set wallpaper'),
          ),
        ],
      ),
    );
  }
}

class _Choices<T> extends StatelessWidget {
  const _Choices({required this.label, required this.value, required this.options, required this.onPick});
  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T>? onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 52, child: Text(label, style: const TextStyle(fontSize: 12, color: Palette.muted))),
          Expanded(
            child: Wrap(
              spacing: 8,
              children: [
                for (final option in options.entries)
                  ChoiceChipButton(
                    label: option.value,
                    selected: option.key == value,
                    onTap: onPick == null ? null : () => onPick!(option.key),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A hint of what will sit over the wallpaper: the clock on a lock screen,
/// a row of icons on a home screen.
class _ScreenHints extends StatelessWidget {
  const _ScreenHints({required this.lock});
  final bool lock;

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  Widget build(BuildContext context) {
    if (lock) {
      final now = DateTime.now();
      final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
      return Align(
        alignment: const Alignment(0, -0.65),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${_days[now.weekday - 1]}, ${_months[now.month - 1]} ${now.day}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Colors.white),
            ),
            Text(
              '$hour:${now.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 38, color: Colors.white),
            ),
          ],
        ),
      );
    }
    return Align(
      alignment: const Alignment(0, 0.9),
      child: FractionallySizedBox(
        widthFactor: 0.76,
        child: Row(
          children: [
            // Each takes its share, up to a set size, so they fit a narrow
            // frame and do not balloon in a wide one.
            for (var i = 0; i < 4; i++)
              Expanded(
                child: Center(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 26),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: Palette.text, borderRadius: BorderRadius.circular(7)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
