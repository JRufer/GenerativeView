import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'src/app_state.dart';
import 'src/core/native_core.dart';
import 'src/core/thumb_cache.dart';
import 'src/platform.dart';
import 'src/theme.dart';
import 'src/ui/home_page.dart';
import 'src/ui/shortcut_layer.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Video playback needs libmpv; without it videos still get thumbnails and
  // metadata, they just do not play.
  var videoPlayback = true;
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    videoPlayback = false;
    debugPrint('video playback disabled: $e');
  }

  PaintingBinding.instance.imageCache.maximumSizeBytes = imageCacheBytes;
  PaintingBinding.instance.imageCache.maximumSize = 200;

  AppState? state;
  Object? failure;
  try {
    final dirs = await resolveAppDirs();
    final core = NativeCore.start(dataDir: dirs.data, cacheDir: dirs.cache);
    final thumbs = ThumbCache(
      core,
      maxBytes: thumbCacheBytes,
      hostFrame: Platform.isAndroid ? androidVideoFrame : null,
    );
    state = AppState(
      core: core,
      thumbs: thumbs,
      pollMs: pollIntervalMs,
      videoPlayback: videoPlayback,
    );
    // `generativeview /some/folder` opens that folder.
    final requested = args.where((a) => !a.startsWith('-')).firstOrNull;
    final initial = requested != null && Directory(requested).existsSync()
        ? Directory(requested).absolute.path
        : null;
    await state.restore(initialFolder: initial);
  } catch (e) {
    failure = e;
  }

  runApp(GenerativeViewApp(state: state, failure: failure));
}

class GenerativeViewApp extends StatefulWidget {
  const GenerativeViewApp({super.key, required this.state, this.failure});
  final AppState? state;
  final Object? failure;

  @override
  State<GenerativeViewApp> createState() => _GenerativeViewAppState();
}

class _GenerativeViewAppState extends State<GenerativeViewApp> {
  final RouteCounter _routes = RouteCounter();

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return MaterialApp(
      title: 'GenerativeView',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorObservers: [_routes],
      builder: (context, child) => state == null
          ? child!
          : ShortcutLayer(state: state, routes: _routes, child: child!),
      home: state == null
          ? _StartupFailure(failure: widget.failure)
          : HomePage(state: state),
    );
  }
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.failure});
  final Object? failure;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 36, color: Palette.danger),
              const SizedBox(height: 14),
              const Text(
                'GenerativeView could not start',
                style: TextStyle(fontSize: 17),
              ),
              const SizedBox(height: 8),
              SelectableText(
                '$failure',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: Palette.muted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
