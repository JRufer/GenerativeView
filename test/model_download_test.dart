import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/model_download.dart';

/// A file server like the model's: `/model/<name>` redirects to
/// `/cdn/<name>`, which answers ranges (unless [ranges] is off).
class _Server {
  _Server(this.files, {this.ranges = true});
  final Map<String, Uint8List> files;
  final bool ranges;
  late HttpServer server;
  final List<String> asked = [];
  int open = 0;
  int mostOpen = 0;

  String get source => 'http://127.0.0.1:${server.port}/model/';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      if (path.startsWith('/model/')) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/cdn/${path.substring(7)}');
        await request.response.close();
        return;
      }
      final data = files[path.substring(5)];
      if (data == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      asked.add(range ?? 'all');
      open++;
      if (open > mostOpen) mostOpen = open;
      var from = 0, to = data.length;
      if (ranges && range != null) {
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
        from = int.parse(m.group(1)!);
        if (m.group(2)!.isNotEmpty) to = int.parse(m.group(2)!) + 1;
        request.response.statusCode = HttpStatus.partialContent;
      }
      request.response.contentLength = to - from;
      // Slow enough that the pieces overlap.
      for (var at = from; at < to; at += 65536) {
        request.response.add(data.sublist(at, (at + 65536).clamp(0, to)));
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await request.response.close().catchError((_) => null);
      open--;
    });
  }

  Future<void> stop() => server.close(force: true);
}

Uint8List _bytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + i ~/ 251) & 0xff]);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('gv-download'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a large file comes in pieces at once, through a redirect', () async {
    final big = _bytes(2000003);
    final server = _Server({'model.safetensors': big, 'tokenizer.json': _bytes(5000)});
    await server.start();
    final progress = <int>[];
    await ModelDownload(
      source: server.source,
      directory: dir.path,
      files: [ModelFile('tokenizer.json', 5000), ModelFile('model.safetensors', big.length)],
      onProgress: (got, _) => progress.add(got),
      connections: 4,
      pieceFrom: 100000,
    ).run();
    await server.stop();
    expect(File('${dir.path}/model.safetensors').readAsBytesSync(), big);
    expect(File('${dir.path}/tokenizer.json').readAsBytesSync(), _bytes(5000));
    // The small file in one stream; the large one as four ranges, together.
    expect(server.asked.where((a) => a.startsWith('bytes=')).length, 4);
    expect(server.mostOpen, greaterThan(1));
    expect(progress.last, big.length + 5000);
    // Nothing left over beside the files.
    expect(dir.listSync().map((f) => f.uri.pathSegments.last).toSet(), {'model.safetensors', 'tokenizer.json'});
  });

  test('a download cut short carries on from what it has', () async {
    final big = _bytes(1500000);
    // Half of it from a download made before, in one stream.
    File('${dir.path}/model.safetensors.part').writeAsBytesSync(big.sublist(0, 700000));
    final server = _Server({'model.safetensors': big});
    await server.start();
    await ModelDownload(
      source: server.source,
      directory: dir.path,
      files: [ModelFile('model.safetensors', big.length)],
      onProgress: (_, _) {},
      connections: 4,
      pieceFrom: 100000,
    ).run();
    await server.stop();
    expect(File('${dir.path}/model.safetensors').readAsBytesSync(), big);
    // What was there is not fetched again.
    final starts = server.asked.map((a) => int.parse(RegExp(r'bytes=(\d+)').firstMatch(a)!.group(1)!)).toList();
    expect(starts.every((s) => s >= 700000), isTrue, reason: '$starts');
  });

  test('a server that will not give ranges gets the file in one stream', () async {
    final big = _bytes(1200000);
    final server = _Server({'model.safetensors': big}, ranges: false);
    await server.start();
    await ModelDownload(
      source: server.source,
      directory: dir.path,
      files: [ModelFile('model.safetensors', big.length)],
      onProgress: (_, _) {},
      connections: 4,
      pieceFrom: 100000,
    ).run();
    await server.stop();
    expect(File('${dir.path}/model.safetensors').readAsBytesSync(), big);
    expect(dir.listSync().map((f) => f.uri.pathSegments.last).toList(), ['model.safetensors']);
  });
}
