import 'package:flutter/material.dart';

/// A message at the foot of the window that a tap anywhere on it clears.
/// The [action], if any, keeps its own tap.
SnackBar toastBar(
  ScaffoldMessengerState messenger,
  String message, {
  Duration duration = const Duration(seconds: 4),
  double? width,
  SnackBarAction? action,
}) {
  return SnackBar(
    // The padding moves inside the tap, so its edges count as the toast too.
    padding: EdgeInsets.zero,
    content: GestureDetector(
      key: const ValueKey<String>('toast'),
      behavior: HitTestBehavior.opaque,
      onTap: messenger.hideCurrentSnackBar,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Text(message),
      ),
    ),
    duration: duration,
    width: width,
    action: action,
  );
}
