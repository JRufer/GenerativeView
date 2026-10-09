/// Binding to the Rust core (`core/`, built as `libgvcore.so`).
///
/// Every call is asynchronous: Dart hands the core a port and a request id,
/// and the reply arrives on that port as `[id, status, payload]`. Nothing
/// here blocks the UI thread, and nothing is code-generated.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

class CoreException implements Exception {
  CoreException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reply statuses, mirroring `core/src/ffi.rs`.
const int _statusOk = 0;
const int _statusNeedHost = 2;

typedef _PostCObject =
    Pointer<NativeFunction<Int8 Function(Int64, Pointer<Dart_CObject>)>>;

typedef ThumbCallback = void Function(Uint8List? bytes, bool needHost);

class NativeCore {
  NativeCore._(DynamicLibrary lib)
    : _init = lib
          .lookupFunction<
            Void Function(_PostCObject),
            void Function(_PostCObject)
          >('gv_init'),
      _open = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int64),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('gv_open'),
      _call = lib
          .lookupFunction<
            Void Function(Int64, Int64, Pointer<Uint8>, Size),
            void Function(int, int, Pointer<Uint8>, int)
          >('gv_call'),
      _thumb = lib
          .lookupFunction<
            Void Function(
              Int64,
              Int64,
              Pointer<Uint8>,
              Size,
              Int64,
              Int64,
              Int32,
            ),
            void Function(int, int, Pointer<Uint8>, int, int, int, int)
          >('gv_thumb'),
      _thumbPut = lib
          .lookupFunction<
            Void Function(
              Int64,
              Int64,
              Pointer<Uint8>,
              Size,
              Int64,
              Int64,
              Int32,
              Pointer<Uint8>,
              Size,
            ),
            void Function(
              int,
              int,
              Pointer<Uint8>,
              int,
              int,
              int,
              int,
              Pointer<Uint8>,
              int,
            )
          >('gv_thumb_put'),
      _cancel = lib
          .lookupFunction<Void Function(Int64), void Function(int)>(
            'gv_cancel',
          );

  final void Function(_PostCObject) _init;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, int) _open;
  final void Function(int, int, Pointer<Uint8>, int) _call;
  final void Function(int, int, Pointer<Uint8>, int, int, int, int) _thumb;
  final void Function(
    int,
    int,
    Pointer<Uint8>,
    int,
    int,
    int,
    int,
    Pointer<Uint8>,
    int,
  )
  _thumbPut;
  final void Function(int) _cancel;

  final ReceivePort _replies = ReceivePort('gvcore replies');
  final ReceivePort _eventPort = ReceivePort('gvcore events');
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  final Map<int, void Function(int status, Object? payload)> _pending = {};
  int _nextId = 1;

  /// Scan progress and index-change notifications.
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Where the shared library lives. Bundled builds find it by name; tests
  /// and `flutter run` from a checkout can point at a cargo build.
  static String defaultLibraryPath() {
    final override = Platform.environment['GVCORE_LIB'];
    if (override != null && override.isNotEmpty) return override;
    return 'libgvcore.so';
  }

  /// Load the library and open the engine. Throws [CoreException] if the
  /// library is missing or the index database cannot be opened.
  static NativeCore start({
    required String dataDir,
    required String cacheDir,
    String? libraryPath,
  }) {
    final DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open(libraryPath ?? defaultLibraryPath());
    } on ArgumentError catch (e) {
      throw CoreException('Could not load the GenerativeView core: $e');
    }
    final core = NativeCore._(lib);
    core._init(NativeApi.postCObject);
    core._replies.listen(core._onReply);
    core._eventPort.listen(core._onEvent);

    final data = dataDir.toNativeUtf8();
    final cache = cacheDir.toNativeUtf8();
    try {
      final rc = core._open(data, cache, core._eventPort.sendPort.nativePort);
      if (rc != 0) {
        throw CoreException(
          'Could not open the image index in $dataDir (code $rc).',
        );
      }
    } finally {
      malloc.free(data);
      malloc.free(cache);
    }
    return core;
  }

  void _onReply(dynamic message) {
    if (message is! List || message.length != 3) return;
    final handler = _pending.remove(message[0] as int);
    handler?.call(message[1] as int, message[2]);
  }

  void _onEvent(dynamic message) {
    if (message is! String) return;
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic>) _events.add(decoded);
    } on FormatException {
      // An event we cannot read is not worth crashing over.
    }
  }

  Future<Object?> _request(String method, Map<String, Object?> args) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = (status, payload) {
      if (status == _statusOk) {
        completer.complete(payload);
      } else {
        completer.completeError(CoreException(payload?.toString() ?? 'error'));
      }
    };
    final bytes = utf8.encode(jsonEncode({'m': method, ...args}));
    final ptr = malloc<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    // The core copies the request before returning.
    _call(_replies.sendPort.nativePort, id, ptr, bytes.length);
    malloc.free(ptr);
    return completer.future;
  }

  /// Run a JSON method and decode its JSON reply.
  Future<dynamic> call(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final reply = await _request(method, args);
    return jsonDecode(reply as String);
  }

  /// The items of a folder view, in the packed layout described in
  /// `core/src/db.rs` (decode with `ItemList.parse`).
  Future<Uint8List> query({
    required String dir,
    required bool recursive,
    String text = '',
    String sort = 'newest',
  }) async {
    final reply = await _request('query', {
      'dir': dir,
      'recursive': recursive,
      'text': text,
      'sort': sort,
    });
    return reply as Uint8List;
  }

  /// Ask for a thumbnail. Returns a request id for [cancel]. [done] gets the
  /// JPEG bytes, or null on failure; `needHost` means the core wants the
  /// caller to supply a decoded frame through [thumbPut].
  int thumb(String path, int mtime, int size, int tier, ThumbCallback done) {
    final id = _nextId++;
    _pending[id] = (status, payload) => _finishThumb(status, payload, done);
    final units = utf8.encode(path);
    final ptr = malloc<Uint8>(units.length);
    ptr.asTypedList(units.length).setAll(0, units);
    _thumb(_replies.sendPort.nativePort, id, ptr, units.length, mtime, size, tier);
    malloc.free(ptr);
    return id;
  }

  /// Hand the core an encoded image (a video frame) to thumbnail.
  int thumbPut(
    String path,
    int mtime,
    int size,
    int tier,
    Uint8List encoded,
    ThumbCallback done,
  ) {
    final id = _nextId++;
    _pending[id] = (status, payload) => _finishThumb(status, payload, done);
    final units = utf8.encode(path);
    final pathPtr = malloc<Uint8>(units.length);
    pathPtr.asTypedList(units.length).setAll(0, units);
    final dataPtr = malloc<Uint8>(encoded.length);
    dataPtr.asTypedList(encoded.length).setAll(0, encoded);
    _thumbPut(
      _replies.sendPort.nativePort,
      id,
      pathPtr,
      units.length,
      mtime,
      size,
      tier,
      dataPtr,
      encoded.length,
    );
    malloc.free(pathPtr);
    malloc.free(dataPtr);
    return id;
  }

  void _finishThumb(int status, Object? payload, ThumbCallback done) {
    if (status == _statusOk && payload is Uint8List) {
      done(payload, false);
    } else {
      done(null, status == _statusNeedHost);
    }
  }

  /// Drop a thumbnail request that has not been served yet.
  void cancel(int id) {
    if (_pending.remove(id) != null) _cancel(id);
  }
}
