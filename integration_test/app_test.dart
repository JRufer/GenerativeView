// Runs the real, built app — bundled Rust library, real plugins, a real
// window — against a folder of generated images.
//
//   Linux:    xvfb-run -a flutter test integration_test -d linux
//   Android:  grant "All files access" first, then
//             flutter test integration_test -d <device>

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/main.dart' as app;
import 'package:generativeview/src/platform.dart';
import 'package:generativeview/src/ui/focus_view.dart';
import 'package:generativeview/src/ui/media_grid.dart';
import 'package:generativeview/src/ui/meta_panel.dart';
import 'package:generativeview/src/ui/stats_page.dart';
import 'package:generativeview/src/ui/video_page.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support.dart';

// Settings come from --dart-define on a device (which has no access to the
// host's environment) and from the environment on desktop.
const String _fixturesDefine = String.fromEnvironment('GV_FIXTURES');
const String _videoDefine = String.fromEnvironment('GV_TEST_VIDEO');

String? get _fixtures => _fixturesDefine.isNotEmpty ? _fixturesDefine : Platform.environment['GV_FIXTURES'];
bool get _testVideo => (_videoDefine.isNotEmpty ? _videoDefine : Platform.environment['GV_TEST_VIDEO']) == '1';

Future<void> waitFor(
  WidgetTester tester,
  bool Function() done, {
  required String what,
  Duration timeout = const Duration(seconds: 90),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      final focus = FocusManager.instance.primaryFocus;
      await shot(tester, 'it-99-failure');
      fail('timed out waiting for $what (keyboard focus: ${focus?.debugLabel ?? focus})');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// On Linux, grab the X display (the CI run sits inside Xvfb).
Future<void> shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['GV_SCREENSHOT_DIR'];
  await tester.pump(const Duration(milliseconds: 400));
  if (dir == null || dir.isEmpty || !Platform.isLinux) {
    // On a device, hold the frame long enough for an outside screen capture.
    if (Platform.isAndroid) await tester.pump(const Duration(seconds: 3));
    return;
  }
  Directory(dir).createSync(recursive: true);
  await Process.run('import', ['-window', 'root', '$dir/$name.png']);
}

/// What another program gets when it pastes the clipboard as [type], or null
/// where there is no way to ask (no `xclip` on this machine).
Future<List<int>?> pasteFromX(String type) async {
  try {
    final result = await Process.run('xclip', ['-selection', 'clipboard', '-t', type, '-o'], stdoutEncoding: null);
    return result.exitCode == 0 ? result.stdout as List<int> : const [];
  } on ProcessException {
    return null;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('index a folder, browse it, read metadata, follow changes', (tester) async {
    final root = Platform.isAndroid
        ? Directory('/storage/emulated/0/Pictures/gv-integration')
        : Directory('${Directory.systemTemp.path}/gv-integration');
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
      root.createSync(recursive: true);
    } on FileSystemException catch (e) {
      fail('Cannot write to ${root.path} ($e). On Android, grant "All files access" before running.');
    }

    var n = 0;
    void write(String name, Map<String, String> texts, {int w = 512, int h = 512}) {
      final file = File('${root.path}/$name');
      file.writeAsBytesSync(pngWithText(w, h, ++n, texts));
      file.setLastModifiedSync(DateTime(2026, 10, 1, 12).add(Duration(minutes: n)));
    }

    write('ComfyUI_00001_.png', {'prompt': comfyGraph(prompt: 'cinematic photo of a lighthouse on a cliff', seed: 219670278747233, lora: 'style/inkwash_v2.safetensors')});
    write('ComfyUI_00002_.png', {'prompt': comfyGraph(prompt: 'a red fox asleep in fresh snow', seed: 22)}, w: 640, h: 384);
    write('00012-3958203417.png', {'parameters': a1111Parameters('oil painting of a lighthouse at dusk', seed: 3958203417)}, w: 384, h: 640);
    write('a1b2c3.png', {'invokeai_metadata': invokeMetadata('an isometric cutaway of a cozy submarine cabin')});
    write('plain-photo.png', const {});
    var expected = 5;

    // Videos, when the run supplies the fixtures (CI does).
    final fixtures = _fixtures;
    var videos = 0;
    if (fixtures != null && fixtures.isNotEmpty) {
      for (final name in ['comfy_tags.mp4', 'comfy_tags.webm']) {
        final source = File('$fixtures/$name');
        if (source.existsSync()) {
          source.copySync('${root.path}/$name');
          File('${root.path}/$name').setLastModifiedSync(DateTime(2026, 9, 1));
          videos++;
        }
      }
    }
    expected += videos;

    await app.main([root.path]);

    int thumbnails() => tester
        .widgetList<RawImage>(find.descendant(of: find.byType(MediaGrid), matching: find.byType(RawImage)))
        .where((w) => w.image != null)
        .length;

    await waitFor(tester, () => thumbnails() == expected, what: '$expected thumbnails (have ${thumbnails()})');
    await shot(tester, 'it-01-grid');

    // ---- search -----------------------------------------------------------
    final search = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search prompts, models, names');
    await tester.enterText(search, 'lighthouse');
    await waitFor(tester, () => thumbnails() == 2 && find.text('2 matches').evaluate().isNotEmpty, what: 'two search results');
    await tester.enterText(search, '');
    await waitFor(tester, () => thumbnails() == expected, what: 'the full grid again');

    // ---- metadata panel ---------------------------------------------------
    final images = find.descendant(of: find.byType(MediaGrid), matching: find.byType(RawImage));
    // Newest first, videos (dated earlier) last: index 4 is ComfyUI_00001_.
    await tester.tap(images.at(4));
    await tester.pump();
    if (find.byType(MetaPanel).evaluate().isEmpty) {
      await tester.tap(find.byTooltip('Generation data (I)'));
    }
    await waitFor(tester, () => find.text('cinematic photo of a lighthouse on a cliff').evaluate().isNotEmpty, what: 'the prompt');
    await shot(tester, 'it-02-metadata');
    String panelText() => tester
        .widgetList<Text>(find.descendant(of: find.byType(MetaPanel), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .join(' | ');
    expect(find.text('219670278747233'), findsOneWidget, reason: panelText());
    // The panel is a lazy list; on a short screen the lower rows need a scroll.
    await tester.scrollUntilVisible(
      find.text('style/inkwash_v2.safetensors'),
      120,
      scrollable: find.descendant(of: find.byType(MetaPanel), matching: find.byType(Scrollable)).first,
    );
    expect(find.text('style/inkwash_v2.safetensors'), findsOneWidget, reason: panelText());
    await tester.drag(find.byType(MetaPanel), const Offset(0, 600));
    await tester.pump(const Duration(milliseconds: 300));

    // Tap to copy puts the prompt on the real clipboard.
    await tester.tap(find.text('cinematic photo of a lighthouse on a cliff'));
    await tester.pump(const Duration(milliseconds: 300));
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clip?.text, 'cinematic photo of a lighthouse on a cliff');

    // ---- copy image: the file itself, generation data and all -------------
    final original = File('${root.path}/ComfyUI_00001_.png');
    await tester.longPress(images.at(4));
    await waitFor(tester, () => find.text('Copy image').evaluate().isNotEmpty, what: 'the image menu');
    await shot(tester, 'it-02b-image-menu');
    await tester.tap(find.text('Copy image'));
    await waitFor(tester, () => find.text('Copied image').evaluate().isNotEmpty, what: 'the image to be copied');
    // Read it back the way a program pasting it would: through the address on
    // the clipboard on Android, as the picture on Linux.
    final pasted = await readCopiedFile();
    expect(pasted, isNotNull, reason: 'the clipboard holds the image');
    expect(pasted, original.readAsBytesSync(), reason: 'the pasted image is the file, byte for byte');
    debugPrint('COPY IMAGE: ${pasted!.length} bytes read back unchanged');
    if (Platform.isLinux) {
      // And from outside the app, where there is a tool to ask with.
      final outside = await pasteFromX('image/png');
      if (outside == null) {
        debugPrint('COPY IMAGE: no xclip here, so no other program asked for the clipboard');
      } else {
        expect(outside, original.readAsBytesSync(), reason: 'another program gets the file, byte for byte');
        final uris = String.fromCharCodes((await pasteFromX('text/uri-list'))!).trim();
        expect(uris, Uri.file(original.path).toString());
        final targets = String.fromCharCodes((await pasteFromX('TARGETS'))!);
        expect(targets, contains('x-special/gnome-copied-files'));
      }
    }
    await tester.pump(const Duration(seconds: 2)); // let the toast go

    // ---- usage -------------------------------------------------------------
    if (find.byTooltip('Usage stats').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Usage stats'));
      // The grid (and the metadata panel) stay alive under the page.
      Finder onPage(String text) => find.descendant(of: find.byType(StatsPage), matching: find.text(text));
      await waitFor(tester, () => onPage('MODELS').evaluate().isNotEmpty, what: 'the usage page');
      expect(onPage('flux1-dev.safetensors'), findsOneWidget);
      await shot(tester, 'it-02c-usage');
      await tester.tap(onPage('sd_xl_base_1.0'));
      await waitFor(tester, () => find.byType(StatsPage).evaluate().isEmpty && thumbnails() == 1, what: 'the grid filtered to one model');
      expect(find.text('1 match'), findsOneWidget);
      // The filter is ordinary search text: the box's own X clears it.
      await tester.tap(find.byTooltip('Clear search'));
      await waitFor(tester, () => thumbnails() == expected, what: 'the full grid again');
      // The filter kept the selection; make sure it is the image we expect.
      await tester.tap(images.at(4));
      await tester.pump();
    }

    // ---- focus view -------------------------------------------------------
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitFor(tester, () => find.byType(FocusView).evaluate().isNotEmpty, what: 'the focus view to open');
    await waitFor(
      tester,
      () => tester.widgetList<RawImage>(find.descendant(of: find.byType(Image), matching: find.byType(RawImage))).any((w) => w.image != null),
      what: 'the full image',
    );
    expect(find.byType(FocusView), findsOneWidget);
    // The zoom chip knows the image's real size (512 px), whatever the screen.
    expect(find.byType(ZoomChip), findsWidgets);
    await shot(tester, 'it-03-focus');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await waitFor(tester, () => find.text('ComfyUI_00002_.png').evaluate().isNotEmpty, what: 'the previous image');

    if (videos > 0 && _testVideo) {
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await waitFor(tester, () => find.byType(VideoPage).evaluate().isNotEmpty, what: 'the video page');
      await tester.pump(const Duration(seconds: 6));
      final banner = find.textContaining('could not be played').evaluate().isNotEmpty;
      debugPrint('VIDEO: failure banner shown = $banner');
      await shot(tester, 'it-04-video');
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitFor(tester, () => find.byType(FocusView).evaluate().isEmpty, what: 'the grid');

    // ---- live update ------------------------------------------------------
    File('${root.path}/ComfyUI_00003_.png').writeAsBytesSync(pngWithText(512, 512, 42, {'prompt': comfyGraph(prompt: 'a paper boat in a storm drain', seed: 99)}));
    await waitFor(tester, () => thumbnails() == expected + 1, what: 'the new image to appear on its own');
    File('${root.path}/ComfyUI_00003_.png').deleteSync();
    await waitFor(tester, () => thumbnails() == expected, what: 'the deleted image to go');
    await shot(tester, 'it-05-final');
  });
}
