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
import 'package:generativeview/src/ui/focus_view.dart';
import 'package:generativeview/src/ui/media_grid.dart';
import 'package:generativeview/src/ui/meta_panel.dart';
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

    // ---- focus view -------------------------------------------------------
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitFor(tester, () => find.byType(FocusView).evaluate().isNotEmpty, what: 'the focus view to open');
    await waitFor(
      tester,
      () => tester.widgetList<RawImage>(find.descendant(of: find.byType(Image), matching: find.byType(RawImage))).any((w) => w.image != null),
      what: 'the full image',
    );
    expect(find.byType(FocusView), findsOneWidget);
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
