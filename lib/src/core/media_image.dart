import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'models.dart';

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
