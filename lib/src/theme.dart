import 'package:flutter/material.dart';

/// Neutral, dark, and quiet: the images are the only colour on screen.
abstract final class Palette {
  static const Color canvas = Color(0xFF0E0E10);
  static const Color panel = Color(0xFF151518);
  static const Color raised = Color(0xFF1D1D21);
  static const Color hover = Color(0xFF25252A);
  static const Color line = Color(0xFF2A2A30);
  static const Color text = Color(0xFFE8E8EC);
  static const Color muted = Color(0xFF9494A0);
  static const Color faint = Color(0xFF63636E);
  static const Color accent = Color(0xFF7AA2F7);
  static const Color danger = Color(0xFFE5737B);
  static const Color tile = Color(0xFF1A1A1E);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Palette.accent,
    onPrimary: Color(0xFF0B1020),
    secondary: Palette.accent,
    surface: Palette.panel,
    onSurface: Palette.text,
    error: Palette.danger,
    outline: Palette.line,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.canvas,
    canvasColor: Palette.panel,
    dividerColor: Palette.line,
    visualDensity: VisualDensity.compact,
    splashFactory: InkRipple.splashFactory,
  );
  // Derive from the theme's own text style so these keep its font family.
  final small = (base.textTheme.bodyMedium ?? const TextStyle()).copyWith(color: Palette.text, fontSize: 13);
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Palette.text, displayColor: Palette.text),
    iconTheme: const IconThemeData(color: Palette.muted, size: 20),
    dividerTheme: const DividerThemeData(color: Palette.line, thickness: 1, space: 1),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: Palette.raised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Palette.line),
      ),
      textStyle: small.copyWith(fontSize: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Palette.raised,
      contentTextStyle: small,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Palette.line),
      ),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 2,
      activeTrackColor: Palette.muted,
      inactiveTrackColor: Palette.line,
      thumbColor: Palette.text,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Palette.raised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Palette.line),
      ),
      textStyle: small,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(8),
      radius: const Radius.circular(4),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.dragged) || states.contains(WidgetState.hovered)
            ? Palette.muted
            : Palette.faint.withValues(alpha: 0.7),
      ),
    ),
  );
}
