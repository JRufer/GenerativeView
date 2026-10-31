// A file trashed and another saved under its name (the next remix or bred
// picture numbered into the gap) must show the new picture in the focus
// view, not the old one still in Flutter's image cache.
import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/media_image.dart';
import 'package:generativeview/src/core/models.dart';

import 'support.dart';

MediaItem _item(int id, File file, int width, int height) {
  final stat = file.statSync();
  final name = file.uri.pathSegments.last;
  return MediaItem(
    id: id,
    dir: file.parent.path,
    name: name,
    isVideo: false,
    width: width,
    height: height,
    mtime: stat.modified.millisecondsSinceEpoch,
    size: stat.size,
    durationMs: 0,
  );
}

/// Width of the picture [provider] gives, going through the image cache.
Future<int> _width(WidgetTester tester, ImageProvider provider) async {
  final width = await tester.runAsync(() {
    final done = Completer<int>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!done.isCompleted) done.complete(info.image.width);
        stream.removeListener(listener);
      },
      onError: (e, s) {
        if (!done.isCompleted) done.completeError(e, s);
      },
    );
    stream.addListener(listener);
    return done.future;
  });
  return width!;
}

void main() {
  test('a different version of the same file is a different image', () {
    final file = File('/pics/cat_remix2.png');
    final a = VersionedFileImage(file, version: '1/100/2000');
    final a2 = VersionedFileImage(File('/pics/cat_remix2.png'), version: '1/100/2000');
    final b = VersionedFileImage(file, version: '7/250/3100');
    expect(a, a2);
    expect(a.hashCode, a2.hashCode);
    expect(a, isNot(b));
    expect(a, isNot(FileImage(file)), reason: 'not mixed up with a plain FileImage');
  });

  testWidgets('a new file under a trashed one\'s name shows the new picture', (tester) async {
    final dir = Directory.systemTemp.createTempSync('gv_media_image');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/cat_remix2.png');

    // The second bred picture, opened in the focus view.
    file.writeAsBytesSync(pngWithText(4, 3, 1, const {}));
    final trashed = _item(1, file, 4, 3);
    expect(await _width(tester, mediaImage(trashed)), 4);
    // What the focus view used to do: keep it under its path alone.
    expect(await _width(tester, FileImage(file)), 4);

    // Trashed, then the third bred picture is saved under the same name.
    forgetMediaImage(trashed);
    file.deleteSync();
    file.writeAsBytesSync(pngWithText(9, 5, 2, const {}));
    final next = _item(2, file, 9, 5);
    expect(next.version, isNot(trashed.version));

    expect(await _width(tester, mediaImage(next)), 9, reason: 'the new picture, not the trashed one');
    // The bug, for the record: a path-only key still hands back the old one.
    expect(await _width(tester, FileImage(file)), 4);
    PaintingBinding.instance.imageCache.clear();
  });

  test('the picture at a path is versioned by the file on disk', () {
    final dir = Directory.systemTemp.createTempSync('gv_path_image');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/a.png')..writeAsBytesSync(pngWithText(2, 2, 1, const {}));
    final first = pathImage(file.path);
    expect(first, pathImage(file.path));
    file.writeAsBytesSync(pngWithText(6, 6, 3, const {}));
    expect(pathImage(file.path), isNot(first), reason: 'size changed');
    expect(pathImage('${dir.path}/missing.png').version, '');
  });
}
