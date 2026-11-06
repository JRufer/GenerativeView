/// The face and hand finder for the detail pass, as the app runs it: the
/// three models fetched once with [ModelDownload] (each into a folder of
/// its own under the core's model folder), then asked of the core.
library;

import 'dart:async';
import 'dart:ui' show Rect;

import 'detail_pass.dart';
import 'model_download.dart';
import 'native_core.dart';

/// One of the finder's models: where it comes from, its folder here, and
/// its file with its exact size.
class DetailModelFile {
  const DetailModelFile(this.source, this.folder, this.file);
  final String source;
  final String folder;
  final ModelFile file;
}

/// RetinaFace (MIT) for faces in photographs and renders, and YOLOv8n
/// models (MIT for faces, OpenRAIL for hands) trained on anime and
/// illustration, from Hugging Face.
const List<DetailModelFile> detailModelFiles = [
  DetailModelFile('https://huggingface.co/py-feat/retinaface/resolve/main/', 'retinaface', ModelFile('mobilenet0.25_Final.pth', 1786259)),
  DetailModelFile(
    'https://huggingface.co/deepghs/anime_face_detection/resolve/main/face_detect_v1.4_n/',
    'anime_face_v1.4_n',
    ModelFile('model.pt', 6229496),
  ),
  DetailModelFile(
    'https://huggingface.co/deepghs/anime_hand_detection/resolve/main/hand_detect_v1.0_n/',
    'anime_hand_v1.0_n',
    ModelFile('model.pt', 6229496),
  ),
];

class DetailModels implements RegionFinder {
  DetailModels(this.core);
  final NativeCore core;

  FinderModelState _model = const FinderModelState(installed: false);
  final _changes = StreamController<FinderModelState>.broadcast();
  ModelDownload? _job;
  String _dir = '';

  @override
  int get downloadBytes => detailModelFiles.fold(0, (n, f) => n + f.file.bytes);

  @override
  FinderModelState get model => _model;

  @override
  Stream<FinderModelState> get changes => _changes.stream;

  void _set(FinderModelState s) {
    _model = s;
    if (!_changes.isClosed) _changes.add(s);
  }

  /// Ask the core whether the models are here.
  Future<void> check() async {
    try {
      final reply = await core.call('detail_status') as Map<String, dynamic>;
      _dir = reply['dir'] as String? ?? '';
      if (!_model.downloading) _set(FinderModelState(installed: reply['installed'] == true));
    } catch (_) {
      // Not known: left as it was.
    }
  }

  @override
  Future<void> download() async {
    if (_job != null) return;
    if (_dir.isEmpty) await check();
    if (_model.installed) return;
    final total = downloadBytes;
    var before = 0;
    _set(FinderModelState(installed: false, downloading: true, total: total));
    try {
      for (final f in detailModelFiles) {
        final job = ModelDownload(
          source: f.source,
          directory: '$_dir/${f.folder}',
          files: [f.file],
          onProgress: (received, _) => _set(FinderModelState(installed: false, downloading: true, received: before + received, total: total)),
        );
        _job = job;
        await job.run();
        before += f.file.bytes;
      }
      _job = null;
      _set(const FinderModelState(installed: true));
    } catch (e) {
      _job = null;
      _set(FinderModelState(installed: false, error: e is DownloadCancelled ? null : 'The download failed: $e'));
    }
  }

  void cancel() => _job?.cancel();

  @override
  Future<List<DetailRegion>> find(String path) async {
    final reply = await core.call('detail_find', {'path': path}) as List;
    return [
      for (final r in reply.cast<Map<String, dynamic>>())
        if ((r['box'] as List).length == 4)
          DetailRegion(
            r['kind'] == 'hand' ? DetailKind.hand : DetailKind.face,
            Rect.fromLTRB(
              (r['box'][0] as num).toDouble(),
              (r['box'][1] as num).toDouble(),
              (r['box'][2] as num).toDouble(),
              (r['box'][3] as num).toDouble(),
            ),
            (r['score'] as num).toDouble(),
          ),
    ];
  }

  void dispose() {
    _job?.cancel();
    _changes.close();
  }
}
