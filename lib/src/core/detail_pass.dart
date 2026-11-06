/// Two ways of redrawing a picture closer up than the server can draw it
/// whole: the hires fix in tiles, and the detail pass on faces and hands.
///
/// Both cut the picture into pieces here, send each piece to the server as
/// an ordinary image to image job, and put the redrawn pieces back with
/// soft edges, so no server needs an extension or custom node for them.
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

// ------------------------------------------------------------ tiles

/// How a hires fix is sent: in tiles when it is large, or always, or whole.
enum TileMode { auto, tiles, whole }

/// The tile sizes offered, a side in pixels. 1024 suits SDXL and Krea 2;
/// 768 an SD 1.5 model; 1536 a server with room to spare.
const List<int> tileSizes = [768, 1024, 1536];
const int defaultTileSize = 1024;

/// How much neighbouring tiles share, to blend across.
const List<int> tileOverlaps = [64, 128, 192, 256];
const int defaultTileOverlap = 128;

/// In [TileMode.auto], a hires fix whose long side is past this is tiled.
const int autoTileAbove = 2560;

/// Whether a hires fix to [width] × [height] goes in tiles under [mode].
bool usesTiles(TileMode mode, int width, int height) => switch (mode) {
  TileMode.tiles => true,
  TileMode.whole => false,
  TileMode.auto => math.max(width, height) > autoTileAbove,
};

/// The tiles covering a [width] × [height] picture: [tile] pixels a side
/// (smaller when the picture is), each sharing [overlap] with the next,
/// spread evenly so the last does not hang off the edge. Row by row.
List<Rect> planTiles(int width, int height, {int tile = defaultTileSize, int overlap = defaultTileOverlap}) {
  List<double> starts(int length) {
    final t = math.min(tile, length);
    if (t >= length) return [0];
    final step = t - overlap;
    final n = ((length - t) / step).ceil() + 1;
    // Spread so the first starts at 0 and the last ends at the edge.
    final gap = (length - t) / (n - 1);
    return [for (var i = 0; i < n; i++) (i * gap).roundToDouble()];
  }

  final tw = math.min(tile, width).toDouble(), th = math.min(tile, height).toDouble();
  return [
    for (final y in starts(height))
      for (final x in starts(width)) Rect.fromLTWH(x, y, tw, th),
  ];
}

// ------------------------------------------------------------ detail pass

/// What a detail pass looks for.
enum DetailKind { face, hand }

/// A face or hand found in a picture: where (fractions of the picture's
/// width and height) and how sure the finder is.
class DetailRegion {
  const DetailRegion(this.kind, this.box, this.score);
  final DetailKind kind;
  final Rect box;
  final double score;
}

/// What a detail pass redraws and how much.
class DetailPass {
  const DetailPass({this.faces = false, this.hands = false, this.strength = defaultDetailStrength, this.extra = '', this.skipped = const {}});

  final bool faces;
  final bool hands;

  /// Denoising strength for each piece.
  final double strength;

  /// Words added to the prompt for these pieces: "detailed eyes", say.
  final String extra;

  /// Regions found that are left alone, by their place in what was found.
  final Set<int> skipped;

  bool get on => faces || hands;

  bool wants(DetailKind k) => k == DetailKind.face ? faces : hands;

  DetailPass copyWith({bool? faces, bool? hands, double? strength, String? extra, Set<int>? skipped}) => DetailPass(
    faces: faces ?? this.faces,
    hands: hands ?? this.hands,
    strength: strength ?? this.strength,
    extra: extra ?? this.extra,
    skipped: skipped ?? this.skipped,
  );

  /// A line to sum it up: "Faces and hands · 0.40".
  String get summary {
    if (!on) return 'Off';
    final what = faces && hands ? 'Faces and hands' : (faces ? 'Faces' : 'Hands');
    return '$what · ${strength.toStringAsFixed(2)}';
  }
}

const double defaultDetailStrength = 0.4;
const double minDetailStrength = 0.15;
const double maxDetailStrength = 0.7;

/// The side, in pixels, each piece is redrawn at before it is put back.
const int detailSide = 1024;

/// Where the face and hand finder stands.
class FinderModelState {
  const FinderModelState({required this.installed, this.downloading = false, this.received = 0, this.total = 0, this.error});
  final bool installed;
  final bool downloading;
  final int received;
  final int total;
  final String? error;
  double? get progress => total > 0 ? received / total : null;
}

/// Finds faces and hands in a picture, on the device. Its model is
/// downloaded the first time it is needed.
abstract class RegionFinder {
  int get downloadBytes;
  FinderModelState get model;
  Stream<FinderModelState> get changes;
  Future<void> download();

  /// The faces and hands in the picture at [path], best first.
  Future<List<DetailRegion>> find(String path);
}
