// JPEG XL pictures against the real core: found, read, shown, and handed to
// a server as a PNG, the same as any other picture.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/media_image.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/core/thumb_cache.dart';
import 'package:generativeview/src/ui/mask_editor.dart' show prepareImageInput;

import 'support.dart';

void main() {
  late Directory scratch;
  late Directory library;
  late NativeCore core;

  setUpAll(() async {
    await loadAppFonts();
    scratch = Directory.systemTemp.createTempSync('gv-jxl-');
    library = Directory('${scratch.path}/library')..createSync();
    final png = File('${library.path}/fox.png');
    png.writeAsBytesSync(pngWithText(320, 320, 5, {'prompt': comfyGraph(prompt: 'a red fox in the snow', seed: 7)}));
    core = NativeCore.start(dataDir: '${scratch.path}/data', cacheDir: '${scratch.path}/cache', libraryPath: coreLibraryPath());
    await core.call('jxl_convert', {'path': png.path, 'dest': '${library.path}/fox.jxl'});
    png.deleteSync();
  });

  tearDownAll(() {
    try {
      scratch.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('a .jxl is listed, read, shown and sent on as a PNG', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(core: core, thumbs: ThumbCache(core, maxBytes: 64 << 20));
    await tester.pumpWidget(GenerativeViewApp(state: state));
    var done = false;
    state.restore(initialFolder: library.path).whenComplete(() => done = true);
    await pumpUntil(tester, () => done, what: 'the folder to open');
    await pumpUntil(tester, () => state.items.length == 1, what: 'the listing');

    final item = state.items[0];
    expect(item.name, 'fox.jxl');
    expect(item.isVideo, isFalse);
    expect((item.width, item.height), (320, 320));

    // The recipe reads as it did in the PNG, so Remix and Breed have it.
    final info = (await tester.runAsync(() => state.metadata(item)))!;
    expect(info.hasGeneration, isTrue);
    expect(info.prompt, contains('a red fox in the snow'));

    // Shown by the viewers' own image provider.
    final codec = (await tester.runAsync(() => pictureCodec(item.path)))!;
    final frame = (await tester.runAsync(() => codec.getNextFrame()))!;
    expect((frame.image.width, frame.image.height), (320, 320));

    // What a server is given is a PNG.
    final input = (await tester.runAsync(
      () => prepareImageInput(path: item.path, width: 320, height: 320, strength: 0.5, ops: const []),
    ))!;
    expect(input.image.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump(const Duration(seconds: 5));
  });
}
