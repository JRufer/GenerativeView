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

/// Put a file on the clipboard as the file itself, bytes untouched, so a
/// copied image keeps the generation data stored inside it. False if this
/// platform (or this file) cannot be copied.
Future<bool> copyFileToClipboard(String path) async {
  try {
    return await _media.invokeMethod<bool>('copyFile', {'path': path}) ?? false;
  } on PlatformException catch (e) {
    debugPrint('copy failed: $e');
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// What is on the clipboard after [copyFileToClipboard], read back the way a
/// program pasting it would read it: through the content address on Android,
/// as the picture on Linux. Here so the integration test can check that the
/// bytes arrive unchanged.
Future<Uint8List?> readCopiedFile() async {
  try {
    return await _media.invokeMethod<Uint8List>('readCopiedFile');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Open a web page in the user's browser.
Future<bool> openUrl(String url) async {
  if (!url.startsWith('https://') && !url.startsWith('http://')) return false;
  if (Platform.isAndroid) {
    try {
      return await _media.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
  try {
    final result = await Process.run('xdg-open', [url]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// How moving a file to the trash went.
enum TrashOutcome {
  trashed,

  /// The user said no to the system's own prompt (Android).
  cancelled,

  /// There is no trash for this file: older Android, a file the media
  /// store doesn't know, or a drive without one. It can still be deleted.
  unsupported,
  failed,
}

/// Whether the system shows its own "move to trash?" prompt, so the app
/// need not ask first. True on Android, where the media store always asks.
bool get trashAsksFirst => Platform.isAndroid;

/// Move the file at [path] to the system trash. The text is why, if it
/// failed.
Future<(TrashOutcome, String?)> trashFile(String path) async {
  try {
    final answer = await _media.invokeMethod<String>('trashFile', {'path': path}) ?? 'unsupported';
    return switch (answer) {
      'trashed' => (TrashOutcome.trashed, null),
      'cancelled' => (TrashOutcome.cancelled, null),
      'unsupported' => (TrashOutcome.unsupported, null),
      _ => (TrashOutcome.failed, answer.replaceFirst('failed: ', '')),
    };
  } on PlatformException catch (e) {
    return (TrashOutcome.failed, e.message);
  } on MissingPluginException {
    return (TrashOutcome.unsupported, null);
  }
}

/// What is on the clipboard to paste as a picture or video: a file to copy
/// (generation data and all), or a picture's bytes with its type.
class PasteSource {
  const PasteSource({this.path, this.bytes, this.type, this.name});
  final String? path;
  final Uint8List? bytes;

  /// The MIME type of [bytes], such as image/png.
  final String? type;

  /// The name the source gave it, if any.
  final String? name;
}

/// What a paste would bring in, or null if the clipboard holds no picture.
Future<PasteSource?> readPasteSource() async {
  try {
    final raw = await _media.invokeMethod<Map<Object?, Object?>>('pasteSource');
    if (raw == null) return null;
    final path = raw['path'] as String?;
    final bytes = raw['bytes'] as Uint8List?;
    if (path == null && bytes == null) return null;
    return PasteSource(path: path, bytes: bytes, type: raw['type'] as String?, name: raw['name'] as String?);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
