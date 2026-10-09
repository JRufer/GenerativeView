import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'models.dart';
import 'native_core.dart';

/// Supplies an encoded frame for a file the core cannot decode on this
/// platform (videos on Android).
typedef HostFrame = Future<Uint8List?> Function(String path);

typedef _Listener = void Function(ui.Image? image);

class _Load {
  int requestId = 0;
  final List<_Listener> listeners = [];
}

/// A handle on an in-flight thumbnail request.
class ThumbRequest {
  ThumbRequest._(this._cache, this._key, this._listener);
  final ThumbCache _cache;
  final String _key;
  final _Listener _listener;

  /// Stop waiting. If nobody else wants the image the core is told to skip it.
  void cancel() => _cache._cancel(_key, _listener);
}

/// Decoded thumbnails, least-recently-used first out.
///
/// The cache owns one handle per image and gives every caller its own
/// [ui.Image.clone], so a tile can keep painting an image after the cache
/// has evicted it. Callers dispose what they are given.
class ThumbCache {
  ThumbCache(this._core, {required this.maxBytes, this.hostFrame});

  final NativeCore _core;
  final int maxBytes;
  final HostFrame? hostFrame;

  static const int tiers = 2;

  // Insertion order doubles as recency order: entries are re-inserted on use.
  final Map<String, ui.Image> _images = {};
  final Map<String, _Load> _loads = {};
  final Set<String> _failed = {};
  int _bytes = 0;

  /// Pick the tier for a tile that is [physicalPixels] wide.
  static int tierFor(double physicalPixels) => physicalPixels > 300 ? 1 : 0;

  static String _key(MediaItem item, int tier) => '${item.version}/$tier';

  /// The cached image at [tier] or, failing that, at any other tier — a
  /// slightly soft thumbnail now beats a blank tile.
  ui.Image? peek(MediaItem item, int tier, {bool exact = false}) {
    final key = _key(item, tier);
    final hit = _images.remove(key);
    if (hit != null) {
      _images[key] = hit;
      return hit.clone();
    }
    if (exact) return null;
    for (var t = tiers - 1; t >= 0; t--) {
      final other = _images[_key(item, t)];
      if (other != null) return other.clone();
    }
    return null;
  }

  bool hasFailed(MediaItem item, int tier) =>
      _failed.contains(_key(item, tier));

  /// Load a thumbnail. [onImage] receives a handle the caller must dispose,
  /// or null if the file could not be decoded.
  ThumbRequest load(
    MediaItem item,
    int tier,
    void Function(ui.Image? image) onImage,
  ) {
    final key = _key(item, tier);
    final request = ThumbRequest._(this, key, onImage);
    final existing = _loads[key];
    if (existing != null) {
      existing.listeners.add(onImage);
      return request;
    }
    final load = _Load()..listeners.add(onImage);
    _loads[key] = load;
    load.requestId = _core.thumb(item.path, item.mtime, item.size, tier, (
      bytes,
      needHost,
    ) {
      if (bytes != null) {
        _decode(key, load, bytes);
      } else if (needHost && hostFrame != null) {
        _fromHost(key, load, item, tier);
      } else {
        _finish(key, load, null);
      }
    });
    return request;
  }

  Future<void> _fromHost(
    String key,
    _Load load,
    MediaItem item,
    int tier,
  ) async {
    Uint8List? frame;
    try {
      frame = await hostFrame!(item.path);
    } catch (_) {
      frame = null;
    }
    if (frame == null) {
      _finish(key, load, null);
      return;
    }
    load.requestId = _core.thumbPut(
      item.path,
      item.mtime,
      item.size,
      tier,
      frame,
      (bytes, _) {
        if (bytes != null) {
          _decode(key, load, bytes);
        } else {
          _finish(key, load, null);
        }
      },
    );
  }

  Future<void> _decode(String key, _Load load, Uint8List bytes) async {
    ui.Image? image;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
      codec.dispose();
    } catch (_) {
      image = null;
    }
    _finish(key, load, image);
  }

  void _finish(String key, _Load load, ui.Image? image) {
    // A cancelled load may already have been replaced by a fresh one.
    if (identical(_loads[key], load)) _loads.remove(key);
    if (image == null) {
      _failed.add(key);
      for (final l in load.listeners) {
        l(null);
      }
      return;
    }
    _failed.remove(key);
    final previous = _images.remove(key);
    if (previous != null) {
      _bytes -= previous.width * previous.height * 4;
      previous.dispose();
    }
    _images[key] = image;
    _bytes += image.width * image.height * 4;
    for (final l in load.listeners) {
      l(image.clone());
    }
    _evict();
  }

  void _evict() {
    while (_bytes > maxBytes && _images.length > 1) {
      final oldest = _images.keys.first;
      final image = _images.remove(oldest)!;
      _bytes -= image.width * image.height * 4;
      image.dispose();
    }
  }

  void _cancel(String key, _Listener listener) {
    final load = _loads[key];
    if (load == null) return;
    load.listeners.remove(listener);
    if (load.listeners.isEmpty) {
      _loads.remove(key);
      _core.cancel(load.requestId);
    }
  }

  /// Forget failures, so files that were mid-write get another chance.
  void retryFailed() => _failed.clear();

  void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _bytes = 0;
    _failed.clear();
  }
}
