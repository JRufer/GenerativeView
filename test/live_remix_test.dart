// Remixes on real servers: what backend_parity_test checks against stand-ins,
// tried for real, start to finish, pictures and all. Skipped unless a
// server's address is given, so it never runs in CI. To run it:
//
//   GV_LIVE_COMFYUI=http://192.168.1.20:8188 \
//   GV_LIVE_INVOKEAI=http://192.168.1.20:9090 \
//   GV_LIVE_KREA2_MODEL=krea2_turbo_fp8_scaled \
//   GV_LIVE_OUT=/tmp/gv-live \
//   flutter test test/live_remix_test.dart
//
// Any of GV_LIVE_COMFYUI, GV_LIVE_INVOKEAI and GV_LIVE_FORGE may be left
// out. The model each picture names (GV_LIVE_SDXL_MODEL, GV_LIVE_KREA2_MODEL)
// is matched as the app matches it: by name, then (for Krea 2) by family, so
// one name works for every server. A family whose model is not given is
// skipped. With GV_LIVE_OUT, every picture made is saved there to look at.
@Timeout(Duration(minutes: 20))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/backends.dart';
import 'package:generativeview/src/core/models.dart';

String? env(String name) {
  final v = Platform.environment[name]?.trim();
  return v == null || v.isEmpty ? null : v;
}

/// A picture's settings for [model], as another program would have saved
/// them, so every server builds its graph from them.
GenInfo pictureOf(String model, {required bool krea2}) => GenInfo.fromJson({
      'source': 'a1111',
      'prompt': krea2
          ? 'a lighthouse on a rocky coast in thick fog, soft morning light, photograph'
          : 'a red fox sitting in fresh snow, detailed fur, photograph',
      'negative': krea2 ? '' : 'blurry, lowres',
      'seed': '7',
      'model': model,
      'params': [
        ['Steps', krea2 ? '8' : '25'],
        ['CFG scale', krea2 ? '1' : '6'],
        ['Sampler', 'euler'],
      ],
      'width': size,
      'height': size,
    });

const int size = 768;

Remix remixOf(GenInfo info, {String? prompt, ImageInput? init, int count = 1}) => Remix(
  info: info,
  prompt: prompt ?? info.prompt,
  negative: info.negative,
  seed: 1234,
  randomSeed: false,
  count: count,
  width: size,
  height: size,
  init: init,
);

/// A greyscale PNG [width] × [height]: white where [white] says, else black.
Uint8List maskPng(int width, int height, bool Function(int x, int y) white) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    for (var x = 0; x < width; x++) {
      raw.addByte(white(x, y) ? 255 : 0);
    }
  }
  Uint8List chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    final out = BytesBuilder()
      ..add(_u32(data.length))
      ..add(body)
      ..add(_u32(_crc(body)));
    return out.toBytes();
  }

  return (BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(chunk('IHDR', [..._u32(width), ..._u32(height), 8, 0, 0, 0, 0]))
        ..add(chunk('IDAT', ZLibCodec().encode(raw.toBytes())))
        ..add(chunk('IEND', const [])))
      .toBytes();
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

int _crc(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Wait for every picture [ticket] brings, check they are pictures, and
/// save them to GV_LIVE_OUT as [name].
Future<List<RemixImage>> collect(RemixTicket ticket, String name) async {
  final images = await ticket.results.toList();
  expect(images, hasLength(ticket.count), reason: ticket.message);
  final out = env('GV_LIVE_OUT');
  for (final (i, image) in images.indexed) {
    expect(image.bytes.length, greaterThan(1000), reason: 'a real picture, not an empty answer');
    if (out != null) {
      await Directory(out).create(recursive: true);
      await File('$out/${name}_$i.${image.extension}').writeAsBytes(image.bytes);
    }
  }
  return images;
}

void main() {
  final families = {
    'SDXL': (env('GV_LIVE_SDXL_MODEL'), false),
    'Krea 2': (env('GV_LIVE_KREA2_MODEL'), true),
  };

  for (final kind in backendNames.keys) {
    final base = env('GV_LIVE_${kind.toUpperCase()}');
    group('${backendNames[kind]} (live)', skip: base == null ? 'GV_LIVE_${kind.toUpperCase()} not set' : null, () {
      test('answers', () async {
        expect(await probeBackend(kind, base!), isNotEmpty);
      });

      for (final MapEntry(key: family, value: (model, krea2)) in families.entries) {
        final skip = model == null ? 'GV_LIVE_${krea2 ? 'KREA2' : 'SDXL'}_MODEL not set' : null;
        final tag = '${kind}_${family.replaceAll(' ', '').toLowerCase()}';
        group(family, skip: skip, () {
          // Each step starts from the picture the one before made, as the
          // app's own image to image and hires fix do.
          Uint8List? made;

          test('text to image, two pictures', () async {
            final info = pictureOf(model!, krea2: krea2);
            final images = await collect(await sendRemix(kind, base!, remixOf(info, count: 2)), '${tag}_t2i');
            made = images.first.bytes;
          });

          test('image to image from that picture', () async {
            final info = pictureOf(model!, krea2: krea2);
            final init = ImageInput(image: made!, strength: 0.5);
            await collect(await sendRemix(kind, base!, remixOf(info, init: init)), '${tag}_i2i');
          });

          test('only the painted half redrawn', () async {
            final info = pictureOf(model!, krea2: krea2);
            final init = ImageInput(
              image: made!,
              strength: 0.8,
              mask: maskPng(size, size, (x, y) => y < size ~/ 2),
              keepMask: maskPng(size, size, (x, y) => y >= size ~/ 2),
            );
            await collect(
              await sendRemix(kind, base!, remixOf(info, prompt: '${info.prompt}, a red sky', init: init)),
              '${tag}_masked',
            );
          });

          test('picked up again after the app was closed', skip: kind == 'forge' ? 'Forge keeps no jobs to ask about later' : null, () async {
            final info = pictureOf(model!, krea2: krea2);
            final first = await sendRemix(kind, base!, remixOf(info));
            expect(first.jobs, isNotEmpty);
            // As though the app were closed: the first ticket is left, and a
            // new one made from what was saved of it.
            await collect(resumeRemix(first.kind, first.base, first.jobs), '${tag}_resumed');
          });
        });
      }
    });
  }
}
