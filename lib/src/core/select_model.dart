/// Tap to select as the app runs it: MobileSAM (Apache 2.0) fetched once
/// with [ModelDownload], then the core encodes each picture once and
/// outlines what is tapped.
library;

import 'dart:async';
import 'dart:ui' show Offset;

import 'model_download.dart';
import 'native_core.dart';
import 'object_select.dart';

/// Where MobileSAM comes from, and its one file with its exact size.
const String selectModelSource = 'https://huggingface.co/nielsr/mobilesam/resolve/main/';
const ModelFile selectModelFile = ModelFile('model.safetensors', 40613056);

/// The model, shared by every picture: whether it is here, and fetching it.
class SelectModel {
  SelectModel(this.core);
  final NativeCore core;

  SelectModelState _state = const SelectModelState(installed: false);
  final _changes = StreamController<SelectModelState>.broadcast();
  ModelDownload? _job;
  String _dir = '';

  SelectModelState get state => _state;
  Stream<SelectModelState> get changes => _changes.stream;

  void _set(SelectModelState s) {
    _state = s;
    if (!_changes.isClosed) _changes.add(s);
  }

  Future<void> check() async {
    try {
      final reply = await core.call('select_status') as Map<String, dynamic>;
      _dir = reply['dir'] as String? ?? '';
      if (!_state.downloading) _set(SelectModelState(installed: reply['installed'] == true));
    } catch (_) {}
  }

  Future<void> download() async {
    if (_job != null) return;
    if (_dir.isEmpty) await check();
    if (_state.installed) return;
    _set(SelectModelState(installed: false, downloading: true, total: selectModelFile.bytes));
    final job = ModelDownload(
      source: selectModelSource,
      directory: _dir,
      files: const [selectModelFile],
      onProgress: (received, total) => _set(SelectModelState(installed: false, downloading: true, received: received, total: total)),
    );
    _job = job;
    try {
      await job.run();
      _set(const SelectModelState(installed: true));
    } catch (e) {
      _set(SelectModelState(installed: false, error: e is DownloadCancelled ? null : 'The download failed: $e'));
    } finally {
      _job = null;
    }
  }

  /// A selector for the picture at [path].
  ObjectSelector selectorFor(String path) => CoreSelector(this, path);

  void dispose() {
    _job?.cancel();
    _changes.close();
  }
}

/// Outlines objects in one picture. The picture is encoded in the
/// background as soon as the model is here, so the first tap is quick too.
class CoreSelector implements ObjectSelector {
  CoreSelector(this.shared, this.path) {
    _sub = shared.changes.listen((s) {
      if (s.installed) _prepare();
    });
    if (shared.state.installed) _prepare();
  }

  final SelectModel shared;
  final String path;
  late final StreamSubscription<SelectModelState> _sub;
  Future<void>? _ready;

  void _prepare() => _ready ??= shared.core.call('select_prepare', {'path': path}).then((_) {});

  @override
  int get downloadBytes => selectModelFile.bytes;

  @override
  SelectModelState get model => shared.state;

  @override
  Stream<SelectModelState> get changes => shared.changes;

  @override
  Future<void> download() => shared.download();

  @override
  Future<List<Offset>> outline(Offset point) async {
    _prepare();
    await _ready;
    final reply = await shared.core.call('select_outline', {'path': path, 'x': point.dx, 'y': point.dy}) as List;
    return [
      for (final p in reply)
        if (p is List && p.length == 2) Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
  }

  @override
  void dispose() => _sub.cancel();
}
