// Keeping the app up to date from its own GitHub releases.
//
// Every merge to main publishes a release named build-<run number>
// (.github/workflows/build.yml). A build that came from one of those knows
// its own name (GV_RELEASE), so it can look for a newer one: a little after
// start, then every few hours while it stays open, never on the way to the
// first frame. When there is one, it says so, and only installs when asked:
//
//   Android  the APK for this device's ABI is downloaded to the app's cache,
//            checked against the digest GitHub lists for it, and handed to
//            the system installer, which asks before it updates.
//   Linux    run as an AppImage, the new AppImage is downloaded beside the
//            running one, checked, and moved over it; the next start (or
//            Restart) runs it. Otherwise the release page is opened.
//   Others   the release page is opened.
//
// Tagged releases (v0.1.0), pull-request builds and builds made by hand have
// no build number to compare, so they never look.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/model_download.dart';

/// The repository whose releases are looked at.
const String updateRepository = 'JRufer/GenerativeView';

/// GitHub's list of the repository's releases, newest first. Unsigned
/// requests are allowed 60 an hour from one address; a check makes one.
final Uri releasesUri = Uri.parse('https://api.github.com/repos/$updateRepository/releases?per_page=30');

/// The setting that turns the checks off.
const String updateCheckPref = 'pref_update_check';

/// The build number in a release name: 353 for `build-353`; null for any
/// other name (a tagged release, a test build, a build made by hand).
int? buildNumberOf(String release) {
  final match = RegExp(r'^build-(\d+)$').firstMatch(release.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// One file of a release.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.size, required this.url, this.sha256});

  final String name;
  final int size;
  final Uri url;

  /// The SHA-256 GitHub lists for the file, as lowercase hex; null where it
  /// lists none.
  final String? sha256;

  static ReleaseAsset? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final size = json['size'];
    final url = json['browser_download_url'];
    if (name is! String || size is! int || url is! String) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return null;
    final digest = json['digest'];
    String? sha;
    if (digest is String && digest.startsWith('sha256:')) {
      final hex = digest.substring(7).toLowerCase();
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) sha = hex;
    }
    return ReleaseAsset(name: name, size: size, url: uri, sha256: sha);
  }
}

/// A published automatic build.
class AvailableBuild {
  const AvailableBuild({required this.tag, required this.number, required this.title, required this.page, required this.assets});

  /// `build-354`.
  final String tag;
  final int number;

  /// `Build 354`.
  final String title;

  /// The release's page on GitHub, with what changed.
  final Uri page;
  final List<ReleaseAsset> assets;

  ReleaseAsset? asset(String name) {
    for (final a in assets) {
      if (a.name == name) return a;
    }
    return null;
  }
}

/// The newest automatic build in GitHub's [releases] list that is newer
/// than build [after]; null if there is none. Drafts and pre-releases are
/// passed over.
AvailableBuild? newestBuild(Object? releases, {required int after}) {
  if (releases is! List) return null;
  AvailableBuild? best;
  for (final r in releases) {
    if (r is! Map || r['draft'] == true || r['prerelease'] == true) continue;
    final tag = r['tag_name'];
    if (tag is! String) continue;
    final number = buildNumberOf(tag);
    if (number == null || number <= after || (best != null && number <= best.number)) continue;
    final page = Uri.tryParse('${r['html_url'] ?? ''}');
    best = AvailableBuild(
      tag: tag,
      number: number,
      title: r['name'] is String && (r['name'] as String).isNotEmpty ? r['name'] as String : 'Build $number',
      page: page != null && page.scheme == 'https' ? page : Uri.parse('https://github.com/$updateRepository/releases/tag/$tag'),
      assets: [
        for (final a in (r['assets'] is List ? r['assets'] as List : const []))
          ?ReleaseAsset.fromJson(a),
      ],
    );
  }
  return best;
}

/// How an update gets onto this machine.
enum InstallWay {
  /// The APK, handed to Android's installer.
  apk,

  /// The AppImage, moved over the running one.
  appImage,

  /// The release page, to download by hand.
  page,
}

/// The file of [build] this install takes, and how it is put in place.
/// [abis] are the device's ABIs, best first (Android); [appImage] is the
/// path of the running AppImage, if it is one (Linux).
(InstallWay, ReleaseAsset?) installFor(
  AvailableBuild build, {
  required String os,
  List<String> abis = const [],
  String? appImage,
}) {
  switch (os) {
    case 'android':
      for (final abi in abis) {
        final apk = build.asset('GenerativeView-$abi.apk');
        if (apk != null) return (InstallWay.apk, apk);
      }
    case 'linux':
      final image = build.asset('GenerativeView-x86_64.AppImage');
      if (appImage != null && appImage.isNotEmpty && image != null) return (InstallWay.appImage, image);
  }
  return (InstallWay.page, null);
}

/// The environment to start a new copy of the AppImage with: this one's,
/// less what the AppImage runtime set for the copy that is running (its
/// mount goes away when it quits), so the new one sets its own.
Map<String, String> restartEnvironment(Map<String, String> env) {
  final appDir = env['APPDIR'];
  final out = Map<String, String>.of(env)
    ..remove('APPIMAGE')
    ..remove('APPDIR')
    ..remove('ARGV0')
    ..remove('OWD');
  final libs = env['LD_LIBRARY_PATH'];
  if (libs != null && appDir != null && appDir.isNotEmpty) {
    final kept = libs.split(':').where((p) => p.isNotEmpty && !p.startsWith(appDir)).join(':');
    if (kept.isEmpty) {
      out.remove('LD_LIBRARY_PATH');
    } else {
      out['LD_LIBRARY_PATH'] = kept;
    }
  }
  return out;
}

enum UpdateStage {
  /// Nothing looked for yet (or checks are off).
  idle,
  checking,
  upToDate,
  available,
  downloading,

  /// Android: the APK is downloaded and checked; the installer is next (or
  /// waits for the permission to install apps).
  readyToInstall,

  /// Linux: the new AppImage is in place; a restart runs it.
  installed,
  failed,
}

@immutable
class UpdateStatus {
  const UpdateStatus(this.stage, {this.build, this.progress, this.message});
  final UpdateStage stage;
  final AvailableBuild? build;

  /// 0 to 1 while downloading.
  final double? progress;

  /// What went wrong, or what to do next.
  final String? message;

  UpdateStatus copyWith(UpdateStage stage, {double? progress, String? message}) =>
      UpdateStatus(stage, build: build, progress: progress, message: message);
}

const MethodChannel _media = MethodChannel('generativeview/media');

/// Looks for newer builds and installs one when asked. One per app, made in
/// `main.dart` as [appUpdater].
class Updater {
  Updater({
    required this.currentRelease,
    required this.enabled,
    this.firstDelay = const Duration(seconds: 20),
    this.every = const Duration(hours: 6),
    String? os,
    Map<String, String>? environment,
    this.fetchReleases,
  }) : os = os ?? Platform.operatingSystem,
       _env = environment ?? Platform.environment;

  /// This build's release name: `build-353`.
  final String currentRelease;

  /// Whether the setting lets it look.
  final bool Function() enabled;
  final Duration firstDelay;
  final Duration every;
  final String os;
  final Map<String, String> _env;

  /// Stands in for GitHub in tests.
  final Future<Object?> Function()? fetchReleases;

  final ValueNotifier<UpdateStatus> status = ValueNotifier(const UpdateStatus(UpdateStage.idle));

  Timer? _first;
  Timer? _timer;
  ModelDownload? _download;
  String? _apkPath;
  bool _disposed = false;

  int? get currentNumber => buildNumberOf(currentRelease);

  /// Whether this build can look for updates at all.
  bool get canCheck => currentNumber != null;

  String? get _appImage {
    final path = _env['APPIMAGE'];
    return path == null || path.isEmpty ? null : path;
  }

  /// Start looking: once after [firstDelay], then every [every]. Off-thread
  /// of startup entirely; does nothing for a build that can't look.
  void start() {
    if (!canCheck) return;
    _first = Timer(firstDelay, () => unawaited(_scheduled()));
    _timer = Timer.periodic(every, (_) => unawaited(_scheduled()));
  }

  Future<void> _scheduled() async {
    if (!enabled()) return;
    // A download, an update waiting to be installed or restarted into, is
    // not replaced by a later check.
    final stage = status.value.stage;
    if (stage == UpdateStage.downloading || stage == UpdateStage.readyToInstall || stage == UpdateStage.installed) return;
    await check();
  }

  /// Look now. Also what Check now runs.
  Future<void> check() async {
    final current = currentNumber;
    if (current == null || _disposed) return;
    final stage = status.value.stage;
    if (stage == UpdateStage.checking || stage == UpdateStage.downloading) return;
    _set(const UpdateStatus(UpdateStage.checking));
    try {
      final releases = await (fetchReleases ?? _fetchReleases)();
      final build = newestBuild(releases, after: current);
      _set(build == null ? const UpdateStatus(UpdateStage.upToDate) : UpdateStatus(UpdateStage.available, build: build));
    } catch (e) {
      _set(UpdateStatus(UpdateStage.failed, message: 'Could not reach GitHub to check for updates.'));
      debugPrint('update check failed: $e');
    }
  }

  Future<Object?> _fetchReleases() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(releasesUri);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'GenerativeView/$currentRelease');
      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('GitHub answered ${response.statusCode}', uri: releasesUri);
      }
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  /// How the update on offer would be installed here.
  Future<InstallWay> installWay() async {
    final build = status.value.build;
    if (build == null) return InstallWay.page;
    return installFor(build, os: os, abis: await _abis(), appImage: _appImage).$1;
  }

  Future<List<String>> _abis() async {
    if (os != 'android') return const [];
    try {
      return (await _media.invokeListMethod<String>('supportedAbis')) ?? const [];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Fetch the update on offer and put it in place, as [installFor] says.
  /// For [InstallWay.page] there is nothing to do here: the caller opens
  /// the release page.
  Future<void> install() async {
    final build = status.value.build;
    if (build == null) return;
    if (status.value.stage == UpdateStage.readyToInstall && _apkPath != null) {
      await _handToInstaller();
      return;
    }
    final stage = status.value.stage;
    if (stage != UpdateStage.available && stage != UpdateStage.failed) return;
    final (way, asset) = installFor(build, os: os, abis: await _abis(), appImage: _appImage);
    if (asset == null) return;
    try {
      switch (way) {
        case InstallWay.apk:
          final dir = '${(await getApplicationCacheDirectory()).path}/updates';
          await _clearOld(dir, keep: asset.name);
          await _fetch(build, asset, dir);
          _apkPath = '$dir/${asset.name}';
          _set(status.value.copyWith(UpdateStage.readyToInstall));
          await _handToInstaller();
        case InstallWay.appImage:
          await _replaceAppImage(build, asset, _appImage!);
        case InstallWay.page:
          return;
      }
    } on DownloadCancelled {
      _set(status.value.copyWith(UpdateStage.available));
    } catch (e) {
      _set(status.value.copyWith(UpdateStage.failed, message: e is DownloadFailed || e is UpdateFailed ? '$e' : 'The update did not finish: $e'));
    }
  }

  /// Stop a download under way.
  void cancel() => _download?.cancel();

  Future<void> _fetch(AvailableBuild build, ReleaseAsset asset, String dir) async {
    final source = asset.url.toString();
    final cut = source.lastIndexOf('/');
    _set(status.value.copyWith(UpdateStage.downloading, progress: 0));
    final download = _download = ModelDownload(
      source: source.substring(0, cut + 1),
      directory: dir,
      files: [ModelFile(source.substring(cut + 1), asset.size)],
      onProgress: (got, total) {
        if (total > 0) _set(status.value.copyWith(UpdateStage.downloading, progress: got / total));
      },
    );
    try {
      await download.run();
    } finally {
      _download = null;
    }
  }

  Future<void> _clearOld(String dir, {required String keep}) async {
    final folder = Directory(dir);
    if (!await folder.exists()) return;
    await for (final entity in folder.list()) {
      final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
      // A part-fetched copy of the same file carries on where it stopped.
      if (name == keep || name.startsWith('$keep.')) continue;
      try {
        await entity.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _handToInstaller() async {
    final path = _apkPath;
    final asset = status.value.build == null ? null : installFor(status.value.build!, os: os, abis: await _abis()).$2;
    if (path == null) return;
    String answer;
    try {
      answer = await _media.invokeMethod<String>('installApk', {'path': path, 'sha256': asset?.sha256 ?? ''}) ?? 'failed';
    } on PlatformException catch (e) {
      answer = 'failed: ${e.message}';
    } on MissingPluginException {
      answer = 'failed';
    }
    switch (answer) {
      case 'started':
        _set(status.value.copyWith(UpdateStage.readyToInstall, message: 'Tap Update in the box Android shows. If it went away, tap Install again.'));
      case 'permission':
        _set(status.value.copyWith(
          UpdateStage.readyToInstall,
          message: 'Android needs your OK first: turn on "Allow from this source" for GenerativeView, come back, and tap Install again.',
        ));
      case 'mismatch':
        try {
          await File(path).delete();
        } catch (_) {}
        _apkPath = null;
        _set(status.value.copyWith(UpdateStage.failed, message: 'The download did not match the file on GitHub, so it was thrown away. Try again.'));
      default:
        _set(status.value.copyWith(UpdateStage.failed, message: 'Android would not open its installer.'));
    }
  }

  /// Download the new AppImage beside [target], check it, and move it over
  /// [target]. The running copy keeps going from its own mount until it
  /// quits.
  Future<void> _replaceAppImage(AvailableBuild build, ReleaseAsset asset, String target) async {
    final folder = File(target).parent.path;
    // Beside it, so the last step is a rename on one file system.
    final staging = '$folder/.generativeview-update';
    try {
      await Directory(staging).create(recursive: true);
    } on FileSystemException {
      throw UpdateFailed('Can\'t write to $folder, where the AppImage is. Download it from the release page instead.');
    }
    await _clearOld(staging, keep: asset.name);
    await _fetch(build, asset, staging);
    final fresh = File('$staging/${asset.name}');
    final expected = asset.sha256;
    if (expected != null) {
      final actual = await _sha256(fresh.path);
      if (actual != null && actual != expected) {
        await fresh.delete();
        throw UpdateFailed('The download did not match the file on GitHub, so it was thrown away. Try again.');
      }
    }
    final mode = await Process.run('chmod', ['755', fresh.path]);
    if (mode.exitCode != 0) throw UpdateFailed('Could not make the new AppImage runnable.');
    await fresh.rename(target);
    try {
      await Directory(staging).delete(recursive: true);
    } catch (_) {}
    _set(status.value.copyWith(UpdateStage.installed));
  }

  Future<String?> _sha256(String path) async {
    try {
      final result = await Process.run('sha256sum', [path]);
      if (result.exitCode != 0) return null;
      return '${result.stdout}'.split(' ').first.trim().toLowerCase();
    } on ProcessException {
      return null;
    }
  }

  /// Linux: start the updated AppImage and quit this copy.
  Future<bool> restart() async {
    final target = _appImage;
    if (target == null || status.value.stage != UpdateStage.installed) return false;
    try {
      await Process.start(
        target,
        const [],
        mode: ProcessStartMode.detached,
        includeParentEnvironment: false,
        environment: restartEnvironment(_env),
        workingDirectory: _env['OWD'],
      );
    } on ProcessException {
      return false;
    }
    exit(0);
  }

  void _set(UpdateStatus value) {
    if (!_disposed) status.value = value;
  }

  void dispose() {
    _disposed = true;
    _first?.cancel();
    _timer?.cancel();
    _download?.cancel();
    status.dispose();
  }
}

class UpdateFailed implements Exception {
  const UpdateFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The app's updater, once `main.dart` has made it; null in tests and for
/// builds that can't look.
Updater? appUpdater;
