import 'dart:async';

import '../test/flutter_test_config.dart' show annotateFailures;

/// Runs around the integration test. Failures are always repeated as
/// annotations here: on a device there is no telling whether the run is on
/// GitHub Actions, and elsewhere the extra line does no harm.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  annotateFailures();
  await testMain();
}
