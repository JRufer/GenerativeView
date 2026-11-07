// Opening the app from the desktop: what to show for the file or folder it
// was started with, and, on Linux, telling the desktop the app opens
// pictures, so they offer it under "Open With" and a double-click can open
// one straight in it.

import 'dart:io';

/// Picture types the app tells the desktop it opens.
const desktopImageTypes = [
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
  'image/bmp',
  'image/jxl',
];

/// The desktop entry's file name, which is also how `xdg-mime` names the app.
const desktopEntryName = 'generativeview.desktop';

/// What the app was asked to open on its command line: a folder, or a
/// picture and the folder it is in. Both null when nothing usable was given.
typedef LaunchTarget = ({String? folder, String? file});

/// The folder (and picture) to open for [args]. Takes plain paths and the
/// `file://` addresses some file managers pass instead; options are skipped.
LaunchTarget launchTarget(List<String> args) {
  for (final arg in args) {
    if (arg.isEmpty || arg.startsWith('-')) continue;
    String path = arg;
    if (arg.startsWith('file://')) {
      try {
        path = Uri.parse(arg).toFilePath();
      } on FormatException {
        continue;
      } on UnsupportedError {
        continue;
      }
    }
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      return (folder: Directory(path).absolute.path, file: null);
    }
    if (type == FileSystemEntityType.file) {
      final file = File(path).absolute;
      return (folder: file.parent.path, file: file.path);
    }
  }
  return (folder: null, file: null);
}

/// [path] as one argument of a desktop entry's Exec line: quoted when it
/// needs to be, with the escaping the Desktop Entry spec asks for.
String execArgument(String path) {
  final safe = path.replaceAll('%', '%%');
  if (!RegExp(r'''[\s"'\\><~|&;$*?#()`=]''').hasMatch(safe)) return safe;
  final quoted = safe.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}');
  // A desktop file's values escape backslashes once more.
  return '"${quoted.replaceAll(r'\', r'\\')}"';
}

/// The app's desktop entry ([template], the one it ships with) set to start
/// [executable], and hidden by the desktop if that file goes away.
String desktopEntryFor(String template, String executable) {
  final exec = execArgument(executable);
  final lines = <String>[];
  for (final line in template.split('\n')) {
    if (line.startsWith('TryExec=')) continue;
    if (line.startsWith('Exec=')) {
      final rest = line.substring(5).trim();
      final cut = rest.indexOf(' ');
      lines.add('TryExec=${executable.replaceAll(r'\', r'\\')}');
      lines.add('Exec=$exec${cut < 0 ? '' : rest.substring(cut)}');
    } else {
      lines.add(line);
    }
  }
  return lines.join('\n');
}

String? get _dataHome {
  final env = Platform.environment;
  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) return xdg;
  final home = env['HOME'];
  return home == null || home.isEmpty ? null : '$home/.local/share';
}

/// Run as an AppImage, put the app on the desktop's list of programs, with
/// the picture types it opens, so it shows under "Open With" and can be made
/// the program pictures open in. A folder install (`install.sh`) already
/// did this; a build run from a checkout is left alone. Nothing is changed
/// when the entry is already right, or when something else (AppImageLauncher,
/// Gear Lever) has put this AppImage on the list already.
Future<void> registerWithDesktop() async {
  if (!Platform.isLinux) return;
  try {
    final env = Platform.environment;
    final appImage = env['APPIMAGE'];
    final appDir = env['APPDIR'];
    final data = _dataHome;
    if (appImage == null || appImage.isEmpty || appDir == null || data == null) return;

    final template = File('$appDir/$desktopEntryName');
    if (!template.existsSync()) return;
    final apps = Directory('$data/applications');
    final ours = File('${apps.path}/$desktopEntryName');

    if (apps.existsSync()) {
      for (final entity in apps.listSync()) {
        if (entity is! File || !entity.path.endsWith('.desktop') || entity.path == ours.path) continue;
        try {
          if (entity.readAsStringSync().contains(appImage)) return;
        } on FileSystemException {
          continue;
        }
      }
    }

    final entry = desktopEntryFor(await template.readAsString(), appImage);
    final current = ours.existsSync() ? await ours.readAsString() : null;
    if (current != entry) {
      await apps.create(recursive: true);
      await ours.writeAsString(entry);
    }

    final icon = File('$appDir/generativeview.png');
    final iconOut = File('$data/icons/hicolor/256x256/apps/generativeview.png');
    if (icon.existsSync() && (!iconOut.existsSync() || iconOut.lengthSync() != icon.lengthSync())) {
      await iconOut.parent.create(recursive: true);
      await icon.copy(iconOut.path);
    }

    if (current != entry) {
      await Process.run('update-desktop-database', [apps.path]);
    }
  } catch (_) {
    // Only a convenience: the app runs the same without it.
  }
}

/// Whether this app is the one pictures open in, as far as the desktop says;
/// null when that can't be told or changed here (not Linux, no `xdg-mime`,
/// or the app is not on the desktop's list of programs).
Future<bool?> isDefaultImageViewer() async {
  if (!Platform.isLinux || !_registered()) return null;
  try {
    var all = true;
    for (final type in desktopImageTypes) {
      final result = await Process.run('xdg-mime', ['query', 'default', type]);
      if (result.exitCode != 0) return null;
      if ('${result.stdout}'.trim() != desktopEntryName) all = false;
    }
    return all;
  } on ProcessException {
    return null;
  }
}

/// Make this app the one the desktop opens pictures in. True if it worked.
Future<bool> makeDefaultImageViewer() async {
  if (!Platform.isLinux) return false;
  try {
    final result = await Process.run('xdg-mime', ['default', desktopEntryName, ...desktopImageTypes]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

bool _registered() {
  final dirs = [
    ?_dataHome,
    ...(Platform.environment['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share').split(':'),
  ];
  return dirs.any((dir) => dir.isNotEmpty && File('$dir/applications/$desktopEntryName').existsSync());
}
