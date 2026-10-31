import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/native_core.dart';
import 'package:generativeview/src/platform.dart';
import 'package:generativeview/src/ui/smart_editor.dart';

/// Build a packed query result the way `core/src/db.rs` does.
Uint8List pack(
  List<String> dirs,
  List<
    (
      int id,
      int dir,
      String name,
      int kind,
      int w,
      int h,
      int mtime,
      int size,
      int dur,
    )
  >
  rows,
) {
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
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...body.toBytes(),
    ...strings.toBytes(),
  ]);
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
    expect(
      (a.id, a.name, a.dir, a.isVideo, a.width, a.height, a.mtime, a.size),
      (7, 'x.png', '/out', false, 640, 480, 1700000000123, 99),
    );
    expect(a.path, '/out/x.png');
    expect(identical(list[0], a), isTrue);

    final b = list[1];
    expect(
      (b.name, b.dir, b.isVideo, b.durationMs, b.size),
      ('ü.mp4', '/out/bé', true, 2500, 1 << 33),
    );
    expect(b.aspect, closeTo(16 / 9, 1e-9));

    // Neither row has generation data: the top bit of the kind is clear.
    expect((a.generated, b.generated), (false, false));
    final marked = ItemList.parse(
      pack(['/out'], [(1, 0, 'made.png', 0x80, 64, 64, 1, 1, 0), (2, 0, 'clip.mp4', 0x81, 64, 64, 1, 1, 0)]),
    );
    expect((marked[0].generated, marked[0].isVideo), (true, false));
    expect((marked[1].generated, marked[1].isVideo), (true, true));

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
      ''') as Map<String, dynamic>,
    );
    expect(info.hasGeneration, isTrue);
    expect(info.models[1].hash, 'abc');
    expect(info.loras[0].tag, '<lora:inkwash_v2:0.6>');
    expect(info.loras[1].tag, '<lora:plain:1>');
    expect(info.params.map((p) => '${p.key}=${p.value}'), [
      'Steps=20',
      'CFG=3.5',
    ]);
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

  test('cross-platform path joining normalizes Windows and Unix separators', () {
    expect(joinMediaPath('/out', 'a.png'), '/out/a.png');
    expect(joinMediaPath('/', 'a.png'), '/a.png');
    expect(joinMediaPath(r'C:\', 'a.png'), 'C:/a.png');
    expect(joinMediaPath('C:/', 'a.png'), 'C:/a.png');
    expect(
      joinMediaPath(r'C:\Users\josh\ComfyUI\output', '0001.png'),
      'C:/Users/josh/ComfyUI/output/0001.png',
    );
    expect(
      joinMediaPath(r'D:\renders\', 'clip.mp4'),
      'D:/renders/clip.mp4',
    );
    expect(normalizePath('c:/foo/bar/'), 'C:/foo/bar');
    expect(normalizePath(r'd:\foo\bar'), 'D:/foo/bar');
    expect(normalizePath('/private/var/folders/xyz'), '/var/folders/xyz');
    expect(normalizePath('/private/tmp'), '/tmp');
  });

  test('NativeCore.resolveLibraryPath selects platform binary or override', () {
    expect(
      NativeCore.resolveLibraryPath(operatingSystem: 'linux', environment: {}),
      'libgvcore.so',
    );
    expect(
      NativeCore.resolveLibraryPath(operatingSystem: 'android', environment: {}),
      'libgvcore.so',
    );
    expect(
      NativeCore.resolveLibraryPath(operatingSystem: 'windows', environment: {}),
      'gvcore.dll',
    );
    expect(
      NativeCore.resolveLibraryPath(operatingSystem: 'macos', environment: {}),
      'libgvcore.dylib',
    );
    expect(
      NativeCore.resolveLibraryPath(
        operatingSystem: 'windows',
        environment: {'GVCORE_LIB': r'C:\custom\gvcore.dll'},
      ),
      r'C:\custom\gvcore.dll',
    );
  });

  test('NativeCore.resolveLibraryPath prefers the core shipped beside the app', () {
    // Linux: the bundle's lib/, by full path, so no other build's core on
    // the system is found first.
    expect(
      NativeCore.resolveLibraryPath(operatingSystem: 'linux', environment: {}, executableDir: '/opt/gv', exists: (p) => p == '/opt/gv/lib/libgvcore.so'),
      '/opt/gv/lib/libgvcore.so',
    );
    expect(
      NativeCore.resolveLibraryPath(operatingSystem: 'windows', environment: {}, executableDir: r'C:\gv', exists: (p) => p == r'C:\gv\gvcore.dll'),
      r'C:\gv\gvcore.dll',
    );
    // Not there (a checkout run): by name, as before.
    expect(NativeCore.resolveLibraryPath(operatingSystem: 'linux', environment: {}, executableDir: '/opt/gv', exists: (_) => false), 'libgvcore.so');
    // Android loads it from the APK by name.
    expect(NativeCore.resolveLibraryPath(operatingSystem: 'android', environment: {}, executableDir: '/system/bin', exists: (_) => true), 'libgvcore.so');
    // GVCORE_LIB still wins.
    expect(
      NativeCore.resolveLibraryPath(operatingSystem: 'linux', environment: {'GVCORE_LIB': '/dev/core.so'}, executableDir: '/opt/gv', exists: (_) => true),
      '/dev/core.so',
    );
  });

test('desktopUrlCommand and shortcut modifiers adapt to Windows and macOS', () {
    final linuxCmd = desktopUrlCommand('https://civitai.com/models/1', operatingSystem: 'linux');
    expect(linuxCmd?.executable, 'xdg-open');
    expect(linuxCmd?.arguments, ['https://civitai.com/models/1']);

    final macCmd = desktopUrlCommand('https://civitai.com/models/1', operatingSystem: 'macos');
    expect(macCmd?.executable, 'open');
    expect(macCmd?.arguments, ['https://civitai.com/models/1']);

    final winCmd = desktopUrlCommand('https://civitai.com/models/1', operatingSystem: 'windows');
    expect(winCmd?.executable, 'rundll32');
    expect(winCmd?.arguments, ['url.dll,FileProtocolHandler', 'https://civitai.com/models/1']);
    expect(
      desktopUrlCommand('file:///etc/passwd', operatingSystem: 'linux'),
      isNull,
    );

    expect(
      isPrimaryShortcutModifier(
        isControlPressed: false,
        isMetaPressed: true,
        operatingSystem: 'macos',
      ),
      isTrue,
    );
    expect(
      isPrimaryShortcutModifier(
        isControlPressed: true,
        isMetaPressed: false,
        operatingSystem: 'macos',
      ),
      isFalse,
    );
    expect(
      isPrimaryShortcutModifier(
        isControlPressed: true,
        isMetaPressed: false,
        operatingSystem: 'windows',
      ),
      isTrue,
    );
  });

  testWidgets('generativeview/media MethodChannel contract handles all outcomes', (tester) async {
    const channel = MethodChannel('generativeview/media');
    String? nextTrashReply = 'trashed';

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'copyFile':
          return (call.arguments as Map)['path'] == 'C:/pics/a.png';
        case 'readCopiedFile':
          return Uint8List.fromList([1, 2, 3, 4]);
        case 'pasteSource':
          return <String, Object?>{
            'path': 'C:/pics/a.png',
            'type': 'image/png',
            'name': 'a.png',
            'more': [
              {'path': 'C:/pics/b.png'},
              {'bytes': Uint8List.fromList([9]), 'type': 'image/webp'},
            ],
          };
        case 'trashFile':
          return nextTrashReply;
        case 'copyFiles':
          return ((call.arguments as Map)['paths'] as List).length == 2;
        case 'dragFiles':
          return true;
        default:
          return null;
      }
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    expect(await copyFileToClipboard('C:/pics/a.png'), isTrue);
    // Several files go as one list; one goes as before.
    expect(await copyFilesToClipboard(['C:/pics/a.png', 'C:/pics/b.png']), isTrue);
    expect(await copyFilesToClipboard(['C:/pics/a.png']), isTrue);
    expect(await dragFilesOut(['C:/pics/a.png']), canDragFilesOut);
    // No share sheet off Android.
    expect(await shareFiles(['C:/pics/a.png']), canShareFiles);
    expect(await copyFileToClipboard('C:/pics/other.png'), isFalse);
    expect(await readCopiedFile(), Uint8List.fromList([1, 2, 3, 4]));

    final paste = await readPasteSource();
    expect(paste?.path, 'C:/pics/a.png');
    expect(paste?.type, 'image/png');
    expect(paste?.name, 'a.png');
    // Several copied items paste as several, in order.
    final all = await readPasteSources();
    expect(all.length, 3);
    expect(all[1].path, 'C:/pics/b.png');
    expect(all[2].type, 'image/webp');

    expect(await trashFile('C:/pics/a.png'), (TrashOutcome.trashed, null));
    nextTrashReply = 'cancelled';
    expect(await trashFile('C:/pics/a.png'), (TrashOutcome.cancelled, null));
    nextTrashReply = 'unsupported';
    expect(await trashFile('C:/pics/a.png'), (TrashOutcome.unsupported, null));
    nextTrashReply = 'failed: permission denied';
    expect(await trashFile('C:/pics/a.png'), (TrashOutcome.failed, 'permission denied'));
  });

  group('smart collection rules', () {
    String roundTrip(String query) => SmartRule.query(SmartRule.parse(query));

    test('read from a search and written back the same', () {
      for (final q in [
        'fox lora:=fur_detail.safetensors',
        'model:="flux1 dev.safetensors" rating:>=4',
        'collection:=Foxes -model:=sdxl.safetensors',
        'prompt:fox -prompt:snow',
        'rating:none flag:keep',
        'steps:30 cfg:7 size:1024x1024 source:comfyui date:2026-10',
        'sampler:euler -flag:reject',
        'is:duplicate type:image "red fox"',
      ]) {
        expect(roundTrip(q), q, reason: q);
      }
    });

    test('each term becomes the rule it reads as', () {
      final rules = SmartRule.parse('model:=flux.safetensors lora:detail rating:4+ rating:<3 rating:2 prompt:fox');
      expect([for (final r in rules) (r.field, r.op, r.value)], [
        (SmartField.model, SmartOp.isOne, 'flux.safetensors'),
        (SmartField.lora, SmartOp.contains, 'detail'),
        (SmartField.rating, SmartOp.atLeast, '4'),
        (SmartField.rating, SmartOp.atMost, '2'),
        (SmartField.rating, SmartOp.exactly, '2'),
        (SmartField.word, SmartOp.has, 'fox'),
      ]);
      // Rewritten in the one way each is written.
      expect(SmartRule.query(rules), 'model:=flux.safetensors lora:detail rating:>=4 rating:<3 rating:2 prompt:fox');
    });

    test('what no rule can say stays as search text, and empty rules drop out', () {
      final rules = SmartRule.parse('-rating:5 flag:keep|none similar:"/a b.png"');
      expect(rules.every((r) => r.field == SmartField.text), isTrue);
      rules.add(SmartRule(SmartField.model, SmartOp.isOne, '  '));
      expect(SmartRule.query(rules), '-rating:5 flag:keep|none similar:"/a b.png"');
      expect(SmartRule(SmartField.lora, SmartOp.lacks, 'film grain').toTerm(), '-lora:"film grain"');
      expect(SmartRule(SmartField.rating, SmartOp.atMost, '5').toTerm(), 'rating:<6');
    });
  });
}
