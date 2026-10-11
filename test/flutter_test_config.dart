import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs around every test file in this folder.
///
/// On GitHub Actions each failure is repeated as an annotation, so why a test
/// failed shows on the run's summary page without opening the log.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.environment['GITHUB_ACTIONS'] == 'true') annotateFailures();
  await testMain();
}

/// Print each test failure as a GitHub Actions annotation as well as in the
/// usual way.
void annotateFailures() {
  final report = reportTestException;
  reportTestException = (FlutterErrorDetails details, String description) {
    final text = [
      description,
      details.exceptionAsString(),
      ...'${details.stack ?? ''}'.split('\n').take(30),
    ].join('\n');
    // A workflow command is a single line.
    final message = text
        .replaceAll('%', '%25')
        .replaceAll('\r', '%0D')
        .replaceAll('\n', '%0A');
    // ignore: avoid_print
    print('::error title=Test failed::$message');
    report(details, description);
  };
}
