import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One file of the content-search model: its name, and its exact size.
class ModelFile {
  const ModelFile(this.name, this.bytes);
  final String name;
  final int bytes;
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => 'The download was cancelled.';
}

class DownloadFailed implements Exception {
  const DownloadFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The server sent the whole file where a range was asked for: it cannot
/// be fetched in pieces.
class _NoRanges implements Exception {
  const _NoRanges();
}

/// Fetches the model's files into a folder.
///
/// Each file is written beside its final name as `<name>.part` and only
/// renamed once every byte has arrived, so a file that is there is whole. A
/// download that was cut short carries on from where it stopped.
///
/// A large file is fetched as [connections] ranges at once, each into its
/// own piece (`<name>.part`, `<name>.part1`, …, with where each starts kept
/// in `<name>.pieces`), then joined: a CDN often caps what one connection
/// gets well below what the line can take. A server that will not give
/// ranges gets the file in one stream, as before.
class ModelDownload {
  ModelDownload({
    required this.source,
    required this.directory,
    required this.files,
    required this.onProgress,
    this.connections = 8,
    this.pieceFrom = 32 * 1000 * 1000,
  });

  /// The address the file names are appended to.
  final String source;
  final String directory;
  final List<ModelFile> files;

  /// Called with the bytes fetched so far, over all files, and the total.
  final void Function(int received, int total) onProgress;

  /// How many ranges of a large file are fetched at once.
  final int connections;

  /// Files this size or larger are fetched in pieces.
  final int pieceFrom;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 16;
  bool _cancelled = false;

  int get total => files.fold(0, (sum, file) => sum + file.bytes);

  /// Stop as soon as possible; [run] then throws [DownloadCancelled].
  void cancel() {
    _cancelled = true;
    _client.close(force: true);
  }

  Future<void> run() async {
    try {
      await Directory(directory).create(recursive: true);
      var before = 0;
      for (final file in files) {
        await _fetch(file, before);
        before += file.bytes;
      }
    } on DownloadCancelled {
      rethrow;
    } on DownloadFailed {
      rethrow;
    } catch (e) {
      if (_cancelled) throw const DownloadCancelled();
      throw DownloadFailed('The download did not finish: $e');
    } finally {
      _client.close(force: true);
    }
  }

  Future<void> _fetch(ModelFile file, int before) async {
    final target = File('$directory/${file.name}');
    if (await target.exists() && await target.length() == file.bytes) {
      onProgress(before + file.bytes, total);
      return;
    }
    final part = File('${target.path}.part');
    if (file.bytes >= pieceFrom && connections > 1) {
      try {
        await _fetchInPieces(file, part, before);
      } on _NoRanges {
        await _forgetPieces(target.path);
        await _fetchWhole(file, part, before);
      }
    } else {
      await _fetchWhole(file, part, before);
    }
    if (_cancelled) throw const DownloadCancelled();
    final got = await part.length();
    if (got != file.bytes) {
      // Not the file we expected: do not build on it next time.
      await part.delete();
      throw DownloadFailed(
        '${file.name} arrived as $got bytes where ${file.bytes} were expected.',
      );
    }
    await part.rename(target.path);
    onProgress(before + file.bytes, total);
  }

  /// Open [uri] for reading from [from] up to (not including) [to] (the
  /// end, when null), following redirects by hand so the range goes along
  /// to wherever the file really is.
  Future<HttpClientResponse> _open(Uri uri, int from, [int? to]) async {
    var at = uri;
    for (var hop = 0; hop < 8; hop++) {
      final request = await _client.getUrl(at);
      request.followRedirects = false;
      if (from > 0 || to != null) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-${to == null ? '' : to - 1}');
      }
      final response = await request.close();
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) break;
        at = at.resolve(location);
        continue;
      }
      return response;
    }
    throw DownloadFailed('Too many redirects fetching $uri.');
  }

  /// The whole file in one stream, carrying on from what [part] holds.
  Future<void> _fetchWhole(ModelFile file, File part, int before) async {
    var have = await part.exists() ? await part.length() : 0;
    if (have > file.bytes) {
      await part.delete();
      have = 0;
    }
    if (have >= file.bytes) return;
    final response = await _open(Uri.parse('$source${file.name}'), have);
    if (response.statusCode == HttpStatus.ok) {
      // The whole file, whatever we asked for: start it again.
      have = 0;
    } else if (response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw DownloadFailed('The server answered ${response.statusCode} for ${file.name}.');
    }
    final sink = part.openWrite(mode: have == 0 ? FileMode.write : FileMode.append);
    try {
      await for (final chunk in response) {
        if (_cancelled) throw const DownloadCancelled();
        sink.add(chunk);
        have += chunk.length;
        onProgress(before + have, total);
      }
    } finally {
      await sink.close();
    }
  }

  File _piece(String target, int i) => File(i == 0 ? '$target.part' : '$target.part$i');

  /// Where each piece starts (the first at 0), kept beside the file so a
  /// download cut short carries on with the same pieces. A first piece
  /// already there (from a download made in one stream) is kept, and only
  /// what is left after it is split up.
  Future<List<int>> _pieces(ModelFile file, String target) async {
    final kept = File('$target.pieces');
    if (await kept.exists()) {
      try {
        final starts = (jsonDecode(await kept.readAsString()) as List).map((v) => (v as num).toInt()).toList();
        final sorted = starts.isNotEmpty && starts.first == 0 && [for (var i = 1; i < starts.length; i++) starts[i] > starts[i - 1]].every((b) => b) && starts.last < file.bytes;
        if (sorted) return starts;
      } catch (_) {}
    }
    final first = _piece(target, 0);
    var have = await first.exists() ? await first.length() : 0;
    if (have >= file.bytes) have = 0;
    final rest = file.bytes - have;
    final count = connections;
    final starts = <int>[0];
    for (var i = 1; i < count; i++) {
      final start = have + rest * i ~/ count;
      if (start > starts.last) starts.add(start);
    }
    await kept.writeAsString(jsonEncode(starts));
    return starts;
  }

  Future<void> _forgetPieces(String target) async {
    final kept = File('$target.pieces');
    if (await kept.exists()) await kept.delete();
    for (var i = 1; i <= connections * 2; i++) {
      final piece = _piece(target, i);
      if (await piece.exists()) await piece.delete();
    }
  }

  Future<void> _fetchInPieces(ModelFile file, File part, int before) async {
    final target = part.path.substring(0, part.path.length - '.part'.length);
    final starts = await _pieces(file, target);
    final ends = [...starts.skip(1), file.bytes];
    final have = List<int>.filled(starts.length, 0);
    for (var i = 0; i < starts.length; i++) {
      final piece = _piece(target, i);
      var length = await piece.exists() ? await piece.length() : 0;
      if (length > ends[i] - starts[i]) {
        await piece.delete();
        length = 0;
      }
      have[i] = length;
    }
    void report() => onProgress(before + have.fold(0, (a, b) => a + b), total);
    report();
    final uri = Uri.parse('$source${file.name}');
    Future<void> fetchPiece(int i) async {
      final from = starts[i] + have[i];
      if (from >= ends[i]) return;
      final response = await _open(uri, from, ends[i]);
      if (response.statusCode == HttpStatus.ok) {
        // The whole file is on its way: hang up rather than take it all.
        await response.detachSocket().then((socket) => socket.destroy(), onError: (Object _) {});
        throw const _NoRanges();
      }
      if (response.statusCode != HttpStatus.partialContent) {
        await response.drain<void>().catchError((_) {});
        throw DownloadFailed('The server answered ${response.statusCode} for ${file.name}.');
      }
      final sink = _piece(target, i).openWrite(mode: have[i] == 0 ? FileMode.write : FileMode.append);
      try {
        await for (final chunk in response) {
          if (_cancelled) throw const DownloadCancelled();
          // Never more than the piece's share, whatever the server sends.
          final room = ends[i] - starts[i] - have[i];
          final take = chunk.length <= room ? chunk : chunk.sublist(0, room);
          sink.add(take);
          have[i] += take.length;
          report();
          if (have[i] >= ends[i] - starts[i]) break;
        }
      } finally {
        await sink.close();
      }
    }

    // All at once; the first to fail stops the rest.
    await Future.wait([for (var i = 0; i < starts.length; i++) fetchPiece(i)], eagerError: true);
    if (_cancelled) throw const DownloadCancelled();
    for (var i = 0; i < starts.length; i++) {
      if (have[i] != ends[i] - starts[i]) {
        throw DownloadFailed('Part of ${file.name} did not arrive; try again to carry on.');
      }
    }
    // Join the pieces onto the first, in order.
    final sink = part.openWrite(mode: FileMode.append);
    try {
      for (var i = 1; i < starts.length; i++) {
        await sink.addStream(_piece(target, i).openRead());
      }
    } finally {
      await sink.close();
    }
    await _forgetPieces(target);
  }
}
