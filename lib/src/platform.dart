/// The few things that differ between Linux and Android.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class AppDirs {
  const AppDirs(this.data, this.cache);

  /// Index database.
  final String data;

  /// Thumbnails; safe for the system to clear.
  final String cache;
}

Future<AppDirs> resolveAppDirs() async {
  final data = await getApplicationSupportDirectory();
  final cache = await getApplicationCacheDirectory();
  return AppDirs(data.path, cache.path);
}

/// How often the core re-checks folder timestamps as a backstop to
/// file-system notifications. Android's shared storage often delivers no
/// notifications at all, so it leans on this; on Linux it only matters for
/// network mounts.
int get pollIntervalMs => Platform.isAndroid ? 3000 : 15000;

/// Decoded thumbnail budget.
int get thumbCacheBytes => Platform.isAndroid ? 160 << 20 : 384 << 20;

/// Full-size image cache budget (Flutter's own image cache).
int get imageCacheBytes => Platform.isAndroid ? 256 << 20 : 768 << 20;

/// Whether we can read arbitrary folders. Always true off Android.
Future<bool> hasStorageAccess() async {
  if (!Platform.isAndroid) return true;
  try {
    if (await Permission.manageExternalStorage.isGranted) return true;
    return await Permission.storage.isGranted;
  } catch (e) {
    debugPrint('permission check failed: $e');
    return false;
  }
}

/// Ask for folder access. On Android 11+ this opens the system's
/// "All files access" screen for the app.
Future<bool> requestStorageAccess() async {
  if (!Platform.isAndroid) return true;
  try {
    if (await Permission.manageExternalStorage.request().isGranted) return true;
    return await Permission.storage.request().isGranted;
  } catch (e) {
    debugPrint('permission request failed: $e');
    return false;
  }
}

const MethodChannel _media = MethodChannel('generativeview/media');

/// First frame of a video as JPEG bytes, via Android's own decoder.
Future<Uint8List?> androidVideoFrame(String path) async {
  if (!Platform.isAndroid) return null;
  try {
    return await _media.invokeMethod<Uint8List>('videoFrame', {'path': path});
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
