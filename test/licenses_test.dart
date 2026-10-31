import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/licenses.dart';

/// The notice files the licences page reads: present, readable, and naming
/// what the app ships with.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<LicenseEntry>> read(String asset) async {
    final data = await rootBundle.load(asset);
    return parseNotices(utf8.decode(gzip.decode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))));
  }

  Set<String> packagesOf(List<LicenseEntry> entries) => {for (final e in entries) ...e.packages};

  test('every Rust crate the core uses directly has its licence', () async {
    final entries = await read('assets/licenses/rust.txt.gz');
    final packages = packagesOf(entries);
    final cargo = File('core/Cargo.toml').readAsStringSync().replaceAll('\r\n', '\n');
    final deps = RegExp(r'^\[dependencies\]\n((?:[^\[\n].*\n|\n)*)', multiLine: true).firstMatch(cargo)!.group(1)!;
    for (final line in deps.split('\n')) {
      final name = RegExp(r'^([A-Za-z0-9_-]+)\s*=').firstMatch(line)?.group(1);
      if (name == null) continue;
      expect(packages, contains(name), reason: 'run tool/gen-licenses.py');
    }
    for (final e in entries) {
      expect(e.paragraphs, isNotEmpty, reason: e.packages.join(', '));
    }
  });

  test('the native libraries, models and word list are credited', () async {
    final packages = packagesOf(await read('assets/licenses/other.txt.gz'));
    for (final name in ['mpv (libmpv)', 'FFmpeg', 'dav1d', 'SQLite', 'Real-ESRGAN (upscale models)', 'DataComp CLIP ViT-B/32 (content-search model)']) {
      expect(packages, contains(name));
    }
  });

  test('the app licence is MIT', () async {
    final text = await rootBundle.loadString('LICENSE');
    expect(text, startsWith('MIT License'));
    expect(text, contains('Joshua Hamilton Rufer'));
  });
}
