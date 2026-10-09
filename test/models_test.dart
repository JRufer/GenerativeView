import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/models.dart';

/// Build a packed query result the way `core/src/db.rs` does.
Uint8List pack(List<String> dirs, List<(int id, int dir, String name, int kind, int w, int h, int mtime, int size, int dur)> rows) {
  final strings = BytesBuilder();
  final body = BytesBuilder();
  for (final r in rows) {
    final name = utf8.encode(r.$3);
    final b = ByteData(48)
      ..setInt64(0, r.$1, Endian.little)
      ..setInt64(8, r.$7, Endian.little)
      ..setInt64(16, r.$8, Endian.little)
      ..setUint32(24, r.$5, Endian.little)
      ..setUint32(28, r.$6, Endian.little)
      ..setUint32(32, r.$9, Endian.little)
      ..setUint32(36, strings.length, Endian.little)
      ..setUint16(40, name.length, Endian.little)
      ..setUint8(42, r.$4)
      ..setUint32(44, r.$2, Endian.little);
    body.add(b.buffer.asUint8List());
    strings.add(name);
  }
  for (final d in dirs) {
    final bytes = utf8.encode(d);
    final b = ByteData(8)
      ..setUint32(0, strings.length, Endian.little)
      ..setUint32(4, bytes.length, Endian.little);
    body.add(b.buffer.asUint8List());
    strings.add(bytes);
  }
  final header = ByteData(16)
    ..setUint32(0, 0x31515647, Endian.little)
    ..setUint32(4, rows.length, Endian.little)
    ..setUint32(8, dirs.length, Endian.little)
    ..setUint32(12, strings.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...body.toBytes(), ...strings.toBytes()]);
}

void main() {
  test('packed query results decode lazily and exactly', () {
    final bytes = pack(
      ['/out', '/out/bé'],
      [
        (7, 0, 'x.png', 0, 640, 480, 1700000000123, 99, 0),
        (-2, 1, 'ü.mp4', 1, 1920, 1080, 5, 1 << 33, 2500),
      ],
    );
    // Parse from the middle of a larger buffer, as a view.
    final padded = Uint8List(bytes.length + 5)..setAll(5, bytes);
    final list = ItemList.parse(Uint8List.sublistView(padded, 5));
    expect(list.length, 2);
    expect(list.idAt(1), -2);
    expect(list.indexOfId(7), 0);
    expect(list.indexOfId(404), -1);

    final a = list[0];
    expect((a.id, a.name, a.dir, a.isVideo, a.width, a.height, a.mtime, a.size), (7, 'x.png', '/out', false, 640, 480, 1700000000123, 99));
    expect(a.path, '/out/x.png');
    expect(identical(list[0], a), isTrue);

    final b = list[1];
    expect((b.name, b.dir, b.isVideo, b.durationMs, b.size), ('ü.mp4', '/out/bé', true, 2500, 1 << 33));
    expect(b.aspect, closeTo(16 / 9, 1e-9));

    expect(ItemList.empty.length, 0);
    expect(() => ItemList.parse(Uint8List(16)), throwsFormatException);
  });

  test('generation info from the core\'s JSON', () {
    final info = GenInfo.fromJson(
      jsonDecode('''
      {"source":"comfyui","prompt":"a fox","negative":"blur","seed":"42","model":"flux1-dev.safetensors",
       "models":[{"kind":"unet","name":"flux1-dev.safetensors"},{"kind":"vae","name":"ae.safetensors","hash":"abc"}],
       "loras":[{"name":"style/inkwash_v2.safetensors","weight":0.6},{"name":"plain"}],
       "params":[["Steps","20"],["CFG","3.5"]],
       "nodes":[{"id":"3","class":"KSampler","title":"KSampler","inputs":[["seed","42"],["model","→ Load #4"]]}],
       "width":1024,"height":768,"duration_ms":0,
       "raw":[["prompt","{}"],["workflow","{\\"a\\":1}"]]}
      ''')
          as Map<String, dynamic>,
    );
    expect(info.hasGeneration, isTrue);
    expect(info.models[1].hash, 'abc');
    expect(info.loras[0].tag, '<lora:inkwash_v2:0.6>');
    expect(info.loras[1].tag, '<lora:plain:1>');
    expect(info.params.map((p) => '${p.key}=${p.value}'), ['Steps=20', 'CFG=3.5']);
    expect(info.nodes.single.inputs.last.value, '→ Load #4');
    expect(info.raw.last.value, '{"a":1}');
    expect(
      info.summary(),
      'Prompt: a fox\nNegative prompt: blur\nSeed: 42\nModel: flux1-dev.safetensors\n'
      'VAE: ae.safetensors\nLoRAs: style/inkwash_v2.safetensors (0.6), plain\nSteps: 20\nCFG: 3.5',
    );
    expect(GenInfo.fromJson(const {}).hasGeneration, isFalse);
  });

  test('formatting', () {
    expect(formatNumber(1), '1');
    expect(formatNumber(0.85), '0.85');
    expect(formatNumber(0.30000000000000004), '0.3');
    expect(formatBytes(900), '900 B');
    expect(formatBytes(1536 * 1024), '1.5 MB');
    expect(formatDuration(65400), '1:05');
    expect(GenInfo.sourceLabel('invokeai'), 'InvokeAI');
    expect(GenInfo.kindLabel('clip'), 'Text encoder');
    expect(GenInfo.kindLabel('wan_t5_encoder'), 'Wan t5 encoder');
  });
}
