import 'dart:ui' show Rect;

/// Which of a screen's wallpapers to change.
enum WallpaperUse { home, lock, both }

/// A screen that can be given a wallpaper, in physical pixels and held the
/// way it is mostly used.
class WallpaperScreen {
  const WallpaperScreen(this.id, this.label, this.width, this.height);

  /// [mainScreen], [coverScreen], or [onlyScreen].
  final String id;
  final String label;
  final int width;
  final int height;

  double get aspect => width / height;
}

const String mainScreen = 'main';
const String coverScreen = 'cover';
const String onlyScreen = 'screen';

/// The choice that means every screen, on a device with two.
const String bothScreens = 'both';

/// The device's screens, and which one is lit now.
class WallpaperDevice {
  const WallpaperDevice(this.screens, this.current);

  final List<WallpaperScreen> screens;
  final String current;

  bool get hasCover => screens.length > 1;

  WallpaperScreen screen(String id) => screens.firstWhere((s) => s.id == id);

  /// From what the Android side reports; null if it makes no sense.
  static WallpaperDevice? fromMap(Map<Object?, Object?> map) {
    final current = map['current'];
    int? side(String key) => (map[key] as num?)?.toInt();
    if (current == onlyScreen) {
      final width = side('width'), height = side('height');
      if (width == null || height == null || width <= 0 || height <= 0) return null;
      return WallpaperDevice([WallpaperScreen(onlyScreen, 'Screen', width, height)], onlyScreen);
    }
    final mainW = side('mainWidth'), mainH = side('mainHeight');
    final coverW = side('coverWidth'), coverH = side('coverHeight');
    if (current is! String || mainW == null || mainH == null || coverW == null || coverH == null) return null;
    if (mainW <= 0 || mainH <= 0 || coverW <= 0 || coverH <= 0) return null;
    return WallpaperDevice([
      WallpaperScreen(mainScreen, 'Main', mainW, mainH),
      WallpaperScreen(coverScreen, 'Cover', coverW, coverH),
    ], current);
  }
}

/// Where the frame sits on a picture: its centre as a share of the picture's
/// width and height, and how far it is zoomed in (1 is as much as fits).
class WallpaperView {
  const WallpaperView({this.cx = 0.5, this.cy = 0.5, this.zoom = 1});
  final double cx;
  final double cy;
  final double zoom;
}

const double maxWallpaperZoom = 4;

/// The part of a [picWidth] × [picHeight] picture that [view] shows on
/// [screen]: the largest rectangle of the screen's shape, divided by the
/// zoom, kept inside the picture.
Rect wallpaperCrop(int picWidth, int picHeight, WallpaperScreen screen, WallpaperView view) {
  final fitsWidth = picWidth / picHeight <= screen.aspect;
  final zoom = view.zoom.clamp(1.0, maxWallpaperZoom);
  final width = (fitsWidth ? picWidth.toDouble() : picHeight * screen.aspect) / zoom;
  final height = (fitsWidth ? picWidth / screen.aspect : picHeight.toDouble()) / zoom;
  final left = (view.cx * picWidth - width / 2).clamp(0.0, picWidth - width);
  final top = (view.cy * picHeight - height / 2).clamp(0.0, picHeight - height);
  return Rect.fromLTWH(left, top, width, height);
}

/// The value for `WallpaperManager.setBitmap`'s `which`. On One UI, bits
/// past Android's own two name the screen; without them it picks the screen
/// from the hinge. There is no public page for these: they were read from
/// the Fold 8's framework (see the feels-engine project's wallpaper audit).
int wallpaperWhich(WallpaperUse use, String screenId) {
  const system = 1, lock = 2, phone = 4, sub = 16;
  final type = switch (use) {
    WallpaperUse.home => system,
    WallpaperUse.lock => lock,
    WallpaperUse.both => system | lock,
  };
  return switch (screenId) {
    mainScreen => type | phone,
    coverScreen => type | sub,
    _ => type,
  };
}

/// One wallpaper to write: which screen, and the crop for it.
class WallpaperWrite {
  const WallpaperWrite({required this.screenId, required this.which, required this.crop, required this.active});
  final String screenId;
  final int which;
  final Rect crop;

  /// The screen lit now, the one a plain call reaches if the screen bits
  /// are ever refused.
  final bool active;

  Map<String, Object> toMap() => {
    'which': which,
    'left': crop.left.round(),
    'top': crop.top.round(),
    'right': crop.right.round(),
    'bottom': crop.bottom.round(),
    'active': active,
  };
}

/// What to say once the wallpaper is set, as "Wallpaper set on …".
String wallpaperPlace(String screen, WallpaperUse use) {
  if (screen == onlyScreen) {
    return switch (use) {
      WallpaperUse.home => 'the home screen',
      WallpaperUse.lock => 'the lock screen',
      WallpaperUse.both => 'the home and lock screens',
    };
  }
  if (screen == bothScreens) {
    return switch (use) {
      WallpaperUse.home => 'both home screens',
      WallpaperUse.lock => 'both lock screens',
      WallpaperUse.both => 'both screens, home and lock',
    };
  }
  final name = screen == coverScreen ? 'cover' : 'main';
  return switch (use) {
    WallpaperUse.home => 'the $name home screen',
    WallpaperUse.lock => 'the $name lock screen',
    WallpaperUse.both => 'the $name screen, home and lock',
  };
}
