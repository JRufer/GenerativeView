/// Tap to select: an on-device model that, given a point on a picture,
/// outlines the object there. The model is downloaded the first time it is
/// needed, like the content-search model.
library;

import 'dart:ui' show Offset;

/// Where the selection model stands.
class SelectModelState {
  const SelectModelState({required this.installed, this.downloading = false, this.received = 0, this.total = 0, this.error});

  final bool installed;
  final bool downloading;
  final int received;
  final int total;
  final String? error;

  double? get progress => total > 0 ? received / total : null;
}

/// Outlines objects in one picture. Made for a picture when the mask
/// editor opens; the picture is read once, then each tap is quick.
abstract class ObjectSelector {
  /// How big the model download is, in bytes, for the editor to say.
  int get downloadBytes;

  /// Where the model stands now, and as it changes.
  SelectModelState get model;
  Stream<SelectModelState> get changes;

  /// Fetch the model.
  Future<void> download();

  /// The outline of the object at [point] (fractions of the picture's width
  /// and height), as the points round it in the same fractions; empty when
  /// nothing stands out there.
  Future<List<Offset>> outline(Offset point);

  void dispose();
}
