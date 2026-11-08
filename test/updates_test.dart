// Finding a newer build among GitHub's releases, and what to install from it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/updates.dart';
import 'package:generativeview/src/ui/update_ui.dart';

Map<String, Object?> _release(String tag, {bool draft = false, bool pre = false, List<String> files = const ['GenerativeView-arm64-v8a.apk', 'GenerativeView-x86_64.AppImage']}) => {
  'tag_name': tag,
  'name': tag.startsWith('build-') ? 'Build ${tag.substring(6)}' : tag,
  'draft': draft,
  'prerelease': pre,
  'html_url': 'https://github.com/JRufer/GenerativeView/releases/tag/$tag',
  'assets': [
    for (final f in files)
      {
        'name': f,
        'size': 1234,
        'browser_download_url': 'https://github.com/JRufer/GenerativeView/releases/download/$tag/$f',
        'digest': 'sha256:${'AB' * 32}',
      },
  ],
};

void main() {
  test('only automatic builds have a number to compare', () {
    expect(buildNumberOf('build-353'), 353);
    expect(buildNumberOf('v0.2.0'), isNull);
    expect(buildNumberOf('test-171'), isNull);
    expect(buildNumberOf(''), isNull);
  });

  test('the newest build newer than this one is offered', () {
    final releases = [_release('build-351'), _release('v0.3.0'), _release('build-356'), _release('build-354')];
    final build = newestBuild(releases, after: 353)!;
    expect(build.tag, 'build-356');
    expect(build.title, 'Build 356');
    expect(build.page.toString(), 'https://github.com/JRufer/GenerativeView/releases/tag/build-356');
    expect(build.asset('GenerativeView-arm64-v8a.apk')!.sha256, 'ab' * 32);
  });

  test('nothing is offered when this is the newest, or only drafts are newer', () {
    expect(newestBuild([_release('build-353'), _release('build-350')], after: 353), isNull);
    expect(newestBuild([_release('build-360', draft: true), _release('build-361', pre: true)], after: 353), isNull);
    expect(newestBuild('not a list', after: 1), isNull);
  });

  test('Android takes the APK for the device, best ABI first', () {
    final build = newestBuild([
      _release('build-354', files: ['GenerativeView-armeabi-v7a.apk', 'GenerativeView-arm64-v8a.apk']),
    ], after: 353)!;
    final (way, asset) = installFor(build, os: 'android', abis: ['arm64-v8a', 'armeabi-v7a']);
    expect(way, InstallWay.apk);
    expect(asset!.name, 'GenerativeView-arm64-v8a.apk');
    expect(installFor(build, os: 'android', abis: ['x86']).$1, InstallWay.page);
  });

  test('Linux replaces the AppImage only when run as one', () {
    final build = newestBuild([_release('build-354')], after: 353)!;
    final (way, asset) = installFor(build, os: 'linux', appImage: '/home/josh/Apps/GenerativeView.AppImage');
    expect(way, InstallWay.appImage);
    expect(asset!.name, 'GenerativeView-x86_64.AppImage');
    expect(installFor(build, os: 'linux').$1, InstallWay.page);
    expect(installFor(build, os: 'windows').$1, InstallWay.page);
  });

  test('a restarted AppImage does not inherit the old mount', () {
    final env = restartEnvironment({
      'HOME': '/home/josh',
      'APPIMAGE': '/home/josh/Apps/GenerativeView.AppImage',
      'APPDIR': '/tmp/.mount_Generaabc',
      'ARGV0': 'GenerativeView',
      'OWD': '/home/josh',
      'LD_LIBRARY_PATH': '/tmp/.mount_Generaabc/mpv:/opt/lib',
    });
    expect(env, {'HOME': '/home/josh', 'LD_LIBRARY_PATH': '/opt/lib'});
    expect(restartEnvironment({'APPDIR': '/tmp/m', 'LD_LIBRARY_PATH': '/tmp/m/mpv'}).containsKey('LD_LIBRARY_PATH'), isFalse);
  });

  test('a check finds the newer build, and is skipped when turned off', () async {
    var on = true;
    var asked = 0;
    final updater = Updater(
      currentRelease: 'build-353',
      enabled: () => on,
      os: 'linux',
      environment: const {},
      firstDelay: const Duration(milliseconds: 10),
      fetchReleases: () async {
        asked++;
        return [_release('build-354')];
      },
    );
    addTearDown(updater.dispose);
    expect(updater.canCheck, isTrue);
    await updater.check();
    expect(updater.status.value.stage, UpdateStage.available);
    expect(updater.status.value.build!.tag, 'build-354');
    expect(await updater.installWay(), InstallWay.page);

    on = false;
    updater.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(asked, 1);
  });

  test('a build that is not an automatic one never looks', () {
    final updater = Updater(currentRelease: 'test-12', enabled: () => true, fetchReleases: () async => throw StateError('asked'));
    addTearDown(updater.dispose);
    expect(updater.canCheck, isFalse);
  });

  testWidgets('the card offers the newer build and its notes', (tester) async {
    final updater = Updater(
      currentRelease: 'build-353',
      enabled: () => true,
      os: 'linux',
      environment: const {},
      fetchReleases: () async => [_release('build-354')],
    );
    addTearDown(updater.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: UpdateCard(updater: updater))));
    expect(find.text('Updates'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('update-check')));
    await tester.pumpAndSettle();
    expect(find.text('Build 354 is out'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('update-install')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('update-notes')), findsOneWidget);
  });
}
