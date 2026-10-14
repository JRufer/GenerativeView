/// Licences of what the app is built from that Flutter does not already
/// know about, added to the licences page beside the Dart packages' own.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The two notice files written by tool/gen-licenses.py: the Rust crates
/// compiled into the core, and the native libraries, models and data the
/// app ships with or downloads.
const List<String> _noticeAssets = [
  'assets/licenses/rust.txt.gz',
  'assets/licenses/other.txt.gz',
];

/// Between records in the notice files: a line of 80 dashes.
final String _separator = '\n${'-' * 80}\n';

var _registered = false;

/// Add the notices to [LicenseRegistry]. They are only read when the
/// licences page asks for them. Safe to call more than once.
void registerLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(_entries);
}

Stream<LicenseEntry> _entries() async* {
  for (final asset in _noticeAssets) {
    final String text;
    try {
      final data = await rootBundle.load(asset);
      text = utf8.decode(gzip.decode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)));
    } catch (e) {
      debugPrint('licences: could not read $asset: $e');
      continue;
    }
    for (final entry in parseNotices(text)) {
      yield entry;
    }
  }
}

/// Records of the form "package, package\n\nlicence text", separated by a
/// line of dashes.
@visibleForTesting
List<LicenseEntry> parseNotices(String text) {
  final entries = <LicenseEntry>[];
  for (final record in text.split(_separator)) {
    final body = record.trim();
    if (body.isEmpty) continue;
    final split = body.indexOf('\n\n');
    if (split < 0) continue;
    final packages = body.substring(0, split).split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    entries.add(LicenseEntryWithLineBreaks(packages, body.substring(split + 2)));
  }
  return entries;
}
