// Opening the app from the desktop: what a file manager's double-click
// starts it with, and the desktop entry an AppImage registers.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/desktop_integration.dart';

void main() {
  late Directory scratch;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('gv_desktop_');
    File('${scratch.path}/a fox.png').writeAsBytesSync([0]);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  group('launchTarget', () {
    test('a folder opens that folder', () {
      final target = launchTarget([scratch.path]);
      expect(target.folder, Directory(scratch.path).absolute.path);
      expect(target.file, isNull);
    });

    test('a picture opens its folder, at the picture', () {
      final target = launchTarget(['${scratch.path}/a fox.png']);
      expect(target.folder, Directory(scratch.path).absolute.path);
      expect(target.file, '${Directory(scratch.path).absolute.path}/a fox.png');
    });

    test('a file:// address works the same', () {
      final uri = Uri.file('${scratch.path}/a fox.png').toString();
      expect(uri, contains('%20'));
      expect(launchTarget([uri]).file, endsWith('/a fox.png'));
    });

    test('options and missing paths are skipped', () {
      expect(launchTarget(['--verbose', '${scratch.path}/gone.png']), (folder: null, file: null));
      expect(launchTarget(['--x', scratch.path]).folder, isNotNull);
    });
  }, skip: Platform.isWindows ? 'Linux and macOS paths' : null);

  group('desktop entry', () {
    const template = '[Desktop Entry]\nType=Application\nName=GenerativeView\nExec=generativeview %f\n'
        'MimeType=image/png;inode/directory;\n';

    test('points at the AppImage, and is hidden if it goes', () {
      final entry = desktopEntryFor(template, '/home/josh/Apps/GenerativeView-x86_64.AppImage');
      expect(entry, contains('Exec=/home/josh/Apps/GenerativeView-x86_64.AppImage %f\n'));
      expect(entry, contains('TryExec=/home/josh/Apps/GenerativeView-x86_64.AppImage\n'));
      expect(entry, contains('MimeType=image/png;inode/directory;'));
    });

    test('quotes a path with spaces or special characters', () {
      expect(execArgument('/a b/app'), '"/a b/app"');
      expect(execArgument(r'/a$b/app'), r'"/a\\$b/app"');
      expect(execArgument('/100%/app'), '/100%%/app');
      final entry = desktopEntryFor(template, '/home/j/My Apps/gv.AppImage');
      expect(entry, contains('Exec="/home/j/My Apps/gv.AppImage" %f'));
    });

    test('the shipped entry offers the app for pictures', () {
      final shipped = File('linux/packaging/generativeview.desktop').readAsStringSync();
      final types = RegExp(r'^MimeType=(.*)$', multiLine: true).firstMatch(shipped)!.group(1)!.split(';');
      for (final type in desktopImageTypes) {
        expect(types, contains(type));
      }
      expect(shipped, contains('Exec=generativeview %f'));
    });
  });
}
