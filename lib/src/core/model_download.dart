import 'dart:async';
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

/// Fetches the model's files into a folder, one at a time.
///
/// Each file is written beside its final name as `<name>.part` and only
/// renamed once every byte has arrived, so a file that is there is whole. A
/// download that was cut short carries on from where it stopped.
class ModelDownload {
  ModelDownload({
    required this.source,
    required this.directory,
    required this.files,
    required this.onProgress,
  });

  /// The address the file names are appended to.
  final String source;
  final String directory;
  final List<ModelFile> files;

  /// Called with the bytes fetched so far, over all files, and the total.
  final void Function(int received, int total) onProgress;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30);
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
    var have = await part.exists() ? await part.length() : 0;
    if (have > file.bytes) {
      await part.delete();
      have = 0;
    }
    if (have < file.bytes) {
      final request = await _client.getUrl(Uri.parse('$source${file.name}'));
      if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final response = await request.close();
      if (response.statusCode == HttpStatus.ok) {
        // The whole file, whatever we asked for: start it again.
        have = 0;
      } else if (response.statusCode != HttpStatus.partialContent) {
        await response.drain<void>();
        throw DownloadFailed(
          'The server answered ${response.statusCode} for ${file.name}.',
        );
      }
      final sink = part.openWrite(
        mode: have == 0 ? FileMode.write : FileMode.append,
      );
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
}
