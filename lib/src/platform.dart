/// Platform-specific integration across Linux, Android, Windows, and macOS.
library;

import 'dart:async';
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
/// notifications at all, so it leans on this; on desktop it only matters for
/// network mounts.
int get pollIntervalMs => Platform.isAndroid ? 3000 : 15000;

/// Decoded thumbnail budget.
int get thumbCacheBytes => Platform.isAndroid ? 160 << 20 : 384 << 20;

/// Full-size image cache budget (Flutter's own image cache).
int get imageCacheBytes => Platform.isAndroid ? 256 << 20 : 768 << 20;

/// Whether the primary keyboard shortcut modifier (`Cmd` on macOS, `Ctrl` on
/// Windows, Linux, and Android) is currently pressed.
bool isPrimaryShortcutModifier({
  required bool isControlPressed,
  required bool isMetaPressed,
  String? operatingSystem,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  return os == 'macos' ? isMetaPressed : isControlPressed;
}

/// Build the desktop process invocation to launch an external HTTP(S) [url],
/// or null if [url] is not an HTTP(S) address.
({String executable, List<String> arguments})? desktopUrlCommand(
  String url, {
  String? operatingSystem,
}) {
  if (!url.startsWith('https://') && !url.startsWith('http://')) return null;
  return switch (operatingSystem ?? Platform.operatingSystem) {
    'macos' => (executable: 'open', arguments: [url]),
    'windows' => (
      executable: 'rundll32',
      arguments: ['url.dll,FileProtocolHandler', url],
    ),
    _ => (executable: 'xdg-open', arguments: [url]),
  };
}

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
/// or native clipboard file/image targets on desktop. Here so the integration
/// test can check that the bytes arrive unchanged.
Future<Uint8List?> readCopiedFile() async {
  try {
    return await _media.invokeMethod<Uint8List>('readCopiedFile');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Put the system's own furniture away for the full-screen view, or bring
/// it back: the status and navigation bars on Android, the window frame on
/// Linux (the window fills its monitor). Elsewhere the app's own chrome is
/// hidden and the window is left as it is.
Future<void> setSystemFullScreen(bool on) async {
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(
      on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    return;
  }
  if (!Platform.isLinux) return;
  try {
    await _media.invokeMethod<void>('setFullScreen', {'on': on});
  } on PlatformException catch (e) {
    debugPrint('full screen failed: $e');
  } on MissingPluginException {
    // An older runner, or a test: the app's own chrome is still hidden.
  }
}

/// Open a web page in the user's browser.
Future<bool> openUrl(String url) async {
  final cmd = desktopUrlCommand(url);
  if (cmd == null) return false;
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
    final result = await Process.run(cmd.executable, cmd.arguments);
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
/// Only the first item; see [readPasteSources] for all of them.
Future<PasteSource?> readPasteSource() async {
  final all = await readPasteSources();
  return all.isEmpty ? null : all.first;
}

/// Everything a paste would bring in, in clipboard order: several copied
/// files paste as several. Empty if the clipboard holds no picture.
Future<List<PasteSource>> readPasteSources() async {
  try {
    final raw = await _media.invokeMethod<Map<Object?, Object?>>('pasteSource');
    if (raw == null) return const [];
    final out = <PasteSource>[];
    void add(Map<Object?, Object?> m) {
      final path = m['path'] as String?;
      final bytes = m['bytes'] as Uint8List?;
      if (path == null && bytes == null) return;
      out.add(PasteSource(path: path, bytes: bytes, type: m['type'] as String?, name: m['name'] as String?));
    }

    add(raw);
    final more = raw['more'];
    if (more is List) {
      for (final m in more) {
        if (m is Map) add(m.cast<Object?, Object?>());
      }
    }
    return out;
  } on PlatformException {
    return const [];
  } on MissingPluginException {
    return const [];
  }
}

/// Put several files on the clipboard as files, bytes untouched. False if
/// this platform cannot, or none of them could be copied.
Future<bool> copyFilesToClipboard(List<String> paths) async {
  if (paths.length == 1) return copyFileToClipboard(paths.single);
  try {
    return await _media.invokeMethod<bool>('copyFiles', {'paths': paths}) ?? false;
  } on PlatformException catch (e) {
    debugPrint('copy failed: $e');
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Whether there is a system share sheet to hand files to other apps.
bool get canShareFiles => Platform.isAndroid;

/// Offer [paths] to another app through the system's share sheet, as the
/// files themselves. Android only (see [canShareFiles]).
Future<bool> shareFiles(List<String> paths) async {
  if (!canShareFiles || paths.isEmpty) return false;
  try {
    return await _media.invokeMethod<bool>('shareFiles', {'paths': paths}) ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Whether files can be dragged out of the window into other programs.
bool get canDragFilesOut => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

/// Start dragging [paths] out of the window, as the files themselves, from
/// the mouse press that is under way.
Future<bool> dragFilesOut(List<String> paths) async {
  if (!canDragFilesOut || paths.isEmpty) return false;
  try {
    return await _media.invokeMethod<bool>('dragFiles', {'paths': paths}) ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Move several files to the trash at once. On Android the system asks
/// once for all of them; [TrashOutcome.unsupported] means it cannot, and
/// they should go one by one. Elsewhere this is the same as each in turn,
/// and the outcome is the first that was not [TrashOutcome.trashed].
Future<(TrashOutcome, String?)> trashFiles(List<String> paths) async {
  if (paths.length == 1) return trashFile(paths.single);
  if (Platform.isAndroid) {
    try {
      final answer = await _media.invokeMethod<String>('trashFiles', {'paths': paths}) ?? 'unsupported';
      return switch (answer) {
        'trashed' => (TrashOutcome.trashed, null),
        'cancelled' => (TrashOutcome.cancelled, null),
        _ => (TrashOutcome.unsupported, null),
      };
    } on PlatformException catch (e) {
      return (TrashOutcome.failed, e.message);
    } on MissingPluginException {
      return (TrashOutcome.unsupported, null);
    }
  }
  return (TrashOutcome.unsupported, null);
}

/// Pictures shared to the app from another (Android), as paths of the
/// copies kept in its shared folder. Each list is handed over once.
final StreamController<List<String>> _shared = StreamController<List<String>>.broadcast();
bool _sharedListening = false;

Stream<List<String>> get sharedFiles {
  if (!_sharedListening && Platform.isAndroid) {
    _sharedListening = true;
    _listenToAndroid();
    // Anything shared before the app was listening (it was opened by it).
    scheduleMicrotask(_takeShared);
  }
  return _shared.stream;
}

bool _androidListening = false;

/// Calls from the Android side: pictures shared in, and a "remix done"
/// notification tapped.
void _listenToAndroid() {
  if (_androidListening) return;
  _androidListening = true;
  _media.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'sharedReady':
        await _takeShared();
      case 'openRemixes':
        _openRemixes.add(null);
    }
    return null;
  });
}

final StreamController<void> _openRemixes = StreamController<void>.broadcast();

/// Each time a "remix done" notification is tapped (Android).
Stream<void> get remixNotificationTaps {
  if (Platform.isAndroid) _listenToAndroid();
  return _openRemixes.stream;
}

/// Tell Android how many remixes are being waited for: while any are, a
/// quiet notification says so and keeps the app waiting with the screen
/// locked; at none it goes. Nothing elsewhere.
Future<void> setRemixesWaiting(int count) async {
  if (!Platform.isAndroid) return;
  try {
    await _media.invokeMethod<void>('remixWaiting', {'count': count});
  } on PlatformException {
    // Notifications refused or unavailable: the wait goes on regardless.
  } on MissingPluginException {
    // Not on this platform.
  }
}

/// Tell the user, with a notification, that a remix is back (Android).
/// Tapping it shows the Remixes collection.
Future<void> notifyRemixDone(String title, String text) async {
  if (!Platform.isAndroid) return;
  try {
    await _media.invokeMethod<void>('remixDone', {'title': title, 'text': text});
  } on PlatformException {
    // As above.
  } on MissingPluginException {
    // As above.
  }
}

Future<void> _takeShared() async {
  try {
    final paths = await _media.invokeListMethod<String>('takeShared');
    if (paths != null && paths.isNotEmpty) _shared.add(paths);
  } on PlatformException {
    // Nothing to take.
  } on MissingPluginException {
    // Not Android.
  }
}
