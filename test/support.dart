/// Helpers for tests that drive the real app against the real Rust core.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where the host build of the core lives when running from a checkout.
String coreLibraryPath() {
  final fromEnv = Platform.environment['GVCORE_LIB'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return '${Directory.current.path}/core/target/release/libgvcore.so';
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> a, List<int> b) {
  var c = 0xFFFFFFFF;
  for (final byte in a) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  for (final byte in b) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

List<int> _chunk(String type, List<int> data) {
  final t = ascii.encode(type);
  final out = BytesBuilder();
  final len = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32(t, data));
  out
    ..add(len.buffer.asUint8List())
    ..add(t)
    ..add(data)
    ..add(crc.buffer.asUint8List());
  return out.toBytes();
}

/// A real PNG — a soft two-colour gradient, different per [seed] — with
/// `tEXt` chunks ahead of the pixels, the way image generators write them.
Uint8List pngWithText(
  int width,
  int height,
  int seed,
  Map<String, String> texts,
) {
  final hueA = (seed * 47) % 360;
  final hueB = (hueA + 40 + seed * 13) % 360;
  final a = HSVColor.fromAHSV(1, hueA.toDouble(), 0.55, 0.85).toColor();
  final b = HSVColor.fromAHSV(1, hueB.toDouble(), 0.65, 0.35).toColor();
  final raw = Uint8List(height * (1 + width * 3));
  var o = 0;
  for (var y = 0; y < height; y++) {
    raw[o++] = 0;
    for (var x = 0; x < width; x++) {
      final t = (x / width * 0.45) + (y / height * 0.55);
      raw[o++] = ((a.r + (b.r - a.r) * t) * 255).round();
      raw[o++] = ((a.g + (b.g - a.g) * t) * 255).round();
      raw[o++] = ((a.b + (b.b - a.b) * t) * 255).round();
    }
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk('IHDR', header.buffer.asUint8List()));
  texts.forEach((key, value) {
    out.add(_chunk('tEXt', [...latin1.encode(key), 0, ...utf8.encode(value)]));
  });
  out
    ..add(_chunk('IDAT', zlib.encode(raw)))
    ..add(_chunk('IEND', const []));
  return out.toBytes();
}

/// A minimal ComfyUI API-format graph.
String comfyGraph({
  required String prompt,
  String negative = 'watermark, text',
  int seed = 1,
  String checkpoint = 'flux1-dev.safetensors',
  String? lora,
}) {
  return jsonEncode({
    '3': {
      'class_type': 'KSampler',
      'inputs': {
        'seed': seed,
        'steps': 24,
        'cfg': 6.5,
        'sampler_name': 'dpmpp_2m',
        'scheduler': 'karras',
        'denoise': 1,
        'model': [lora == null ? '4' : '10', 0],
        'positive': ['6', 0],
        'negative': ['7', 0],
        'latent_image': ['5', 0],
      },
    },
    '4': {
      'class_type': 'CheckpointLoaderSimple',
      'inputs': {'ckpt_name': checkpoint},
    },
    '5': {
      'class_type': 'EmptyLatentImage',
      'inputs': {'width': 1024, 'height': 1024, 'batch_size': 1},
    },
    '6': {
      'class_type': 'CLIPTextEncode',
      'inputs': {
        'text': prompt,
        'clip': ['4', 1],
      },
    },
    '7': {
      'class_type': 'CLIPTextEncode',
      'inputs': {
        'text': negative,
        'clip': ['4', 1],
      },
    },
    if (lora != null)
      '10': {
        'class_type': 'LoraLoader',
        'inputs': {
          'lora_name': lora,
          'strength_model': 0.8,
          'strength_clip': 0.8,
          'model': ['4', 0],
          'clip': ['4', 1],
        },
      },
  });
}

String a1111Parameters(
  String prompt, {
  int seed = 7,
  String model = 'sd_xl_base_1.0',
}) =>
    '$prompt\nNegative prompt: lowres, blurry\n'
    'Steps: 30, Sampler: DPM++ 2M Karras, CFG scale: 7, Seed: $seed, Size: 832x1216, Model: $model, Version: v1.9.4';

String invokeMetadata(
  String prompt, {
  int seed = 9,
  String model = 'Juggernaut XL v9',
}) => jsonEncode({
  'generation_mode': 'sdxl_txt2img',
  'positive_prompt': prompt,
  'negative_prompt': 'people',
  'width': 1216,
  'height': 832,
  'seed': seed,
  'cfg_scale': 5.5,
  'steps': 28,
  'scheduler': 'dpmpp_2m_sde_k',
  'model': {
    'key': 'k1',
    'hash': 'blake3:aa',
    'name': model,
    'base': 'sdxl',
    'type': 'main',
  },
  'loras': [
    {
      'model': {
        'key': 'k2',
        'hash': 'blake3:bb',
        'name': 'cutaway-diagram-xl',
        'base': 'sdxl',
        'type': 'lora',
      },
      'weight': 0.85,
    },
  ],
});

/// Real fonts for screenshots: without them every glyph renders as a box.
Future<void> loadAppFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    var any = false;
    for (final name in files) {
      final file = File('$dir/$name');
      if (file.existsSync()) {
        loader.addFont(file.readAsBytes().then((b) => ByteData.sublistView(b)));
        any = true;
      }
    }
    if (any) await loader.load();
  }

  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

/// Let real time pass (for the core and for file IO), advance the test
/// clock (for the app's debounce timers), and rebuild — until [done].
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 150));
    if (done()) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
  }
}

/// Save what is on screen as a PNG when GV_SCREENSHOT_DIR is set.
Future<void> screenshot(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String name,
) async {
  final dir = Platform.environment['GV_SCREENSHOT_DIR'];
  if (dir == null || dir.isEmpty) return;
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

/// Capture clipboard writes instead of touching a real clipboard.
List<String> captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  return copied;
}
