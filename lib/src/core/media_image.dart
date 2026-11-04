import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Flutter's image codecs cannot read JPEG XL, so those come from the core.
bool isJxl(String path) => path.toLowerCase().endsWith('.jxl');

/// The core's `jxl_pixels`, set when the app starts.
Future<Uint8List> Function(String path)? jxlPixels;

/// The picture at [path], whatever its format, ready to draw.
Future<ui.Codec> pictureCodec(String path) async {
  if (!isJxl(path)) return ui.instantiateImageCodec(await File(path).readAsBytes());
  final read = jxlPixels;
  if (read == null) throw StateError('no core to read $path');
  final reply = await read(path);
  final head = ByteData.sublistView(reply, 0, 8);
  final buffer = await ui.ImmutableBuffer.fromUint8List(Uint8List.sublistView(reply, 8));
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: head.getUint32(0, Endian.little),
    height: head.getUint32(4, Endian.little),
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  return descriptor.instantiateCodec();
}

/// A file other programs can open with the picture at [path]: the file itself
/// unless it is a `.jxl`, which is written out as a temporary PNG.
Future<String> readablePath(String path) async {
  if (!isJxl(path)) return path;
  final codec = await pictureCodec(path);
  final frame = await codec.getNextFrame();
  try {
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}/generativeview_${DateTime.now().microsecondsSinceEpoch}.png');
    await out.writeAsBytes(data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    return out.path;
  } finally {
    frame.image.dispose();
    codec.dispose();
  }
}

/// A [FileImage] that knows which version of the file it shows.
///
/// Flutter's image cache tells a [FileImage] apart by its path alone, so
/// when a file is replaced by another under the same name — a picture
/// trashed and a new remix or bred picture saved as `…_remix2.png` again,
/// or a file rewritten in place — the cache keeps handing back the old
/// picture until the app restarts. This one also compares [version]
/// (see [MediaItem.version]), so a new file is always decoded afresh.
@immutable
class VersionedFileImage extends FileImage {
  const VersionedFileImage(super.file, {required this.version, super.scale});

  /// What changes whenever the file's contents may have.
  final String version;

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) {
    if (!isJxl(file.path)) return super.loadImage(key, decode);
    return MultiFrameImageStreamCompleter(codec: pictureCodec(file.path), scale: key.scale, debugLabel: file.path);
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is VersionedFileImage &&
        other.file.path == file.path &&
        other.version == version &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(file.path, version, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'VersionedFileImage')}("${file.path}", version: $version, scale: ${scale.toStringAsFixed(1)})';
}

/// The full picture of [item], cached by its version.
VersionedFileImage mediaImage(MediaItem item) =>
    VersionedFileImage(File(item.path), version: item.version);

/// The full picture at [path] when only the path is known: its version is
/// read from the file's modification time and size.
VersionedFileImage pathImage(String path) {
  final file = File(path);
  String version;
  try {
    final stat = file.statSync();
    // A missing file is not an error to statSync: it says so in its type.
    version = stat.type == FileSystemEntityType.notFound
        ? ''
        : '${stat.modified.millisecondsSinceEpoch}/${stat.size}';
  } catch (_) {
    version = '';
  }
  return VersionedFileImage(file, version: version);
}

/// Let go of what the image cache holds for [item]'s full picture. Called
/// when a file is trashed or deleted, so its decoded picture does not stay
/// in memory. (A new file under the same name is told apart by its version
/// either way.)
void forgetMediaImage(MediaItem item) {
  try {
    PaintingBinding.instance.imageCache.evict(mediaImage(item), includeLive: true);
  } catch (_) {
    // No painting binding (a plain unit test): nothing is cached.
  }
}
