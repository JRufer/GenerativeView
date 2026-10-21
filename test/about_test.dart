// The build named on the About page as GitHub's Releases page names it.
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/ui/about_panel.dart';

void main() {
  test('a published build is named as its release, with its commit', () {
    expect(buildLabel(release: 'build-159', commit: 'a06630b1234567890'), 'build-159 · a06630b');
    expect(buildLabel(release: 'v0.2.0', commit: 'a06630b'), 'v0.2.0 · a06630b');
  });

  test('a build that was never published says so', () {
    expect(buildLabel(release: 'test-171', commit: 'beefcafe0000'), 'test build 171, not published · beefcafe');
  });

  test('a build made by hand says so', () {
    expect(buildLabel(release: '', commit: ''), 'built locally');
  });
}
