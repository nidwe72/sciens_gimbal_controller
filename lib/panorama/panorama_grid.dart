import 'dart:math' as math;

/// Pure-Dart Brenizer grid math. No Flutter, no transport — given two
/// focal lengths + overlap + a centre orientation, produce the list of
/// tile positions the sequencer drives the gimbal through, plus the
/// guard flags the UI uses to warn / lock the Take button.
///
/// See SPEC-flutter-app.md "Phase 4 — Panorama sequencer / Grid math".

/// Full-frame sensor half-extents (36 × 24 mm).
const double kSensorHalfWmm = 18.0;
const double kSensorHalfHmm = 12.0;

/// GUI overlap ceiling. Capped at 0.6 so the vertical step always stays
/// well above `moveByAngle`'s 1° pitch-coast floor.
const double kOverlapMax = 0.6;

/// Tile-count guardrails.
const int kPanoWarnTileCount = 50;
const int kPanoMaxTileCount = 100;

/// Degenerate-panorama guard: if the stitched FOV is below this multiple
/// of a single taking-lens frame in *both* axes, there's nothing
/// meaningful to stitch. Tunable.
const double kPanoMinCoverageRatio = 1.5;

double _fovDeg(double halfExtentMm, double focalMm) =>
    2 * math.atan(halfExtentMm / focalMm) * 180 / math.pi;

/// Number of tiles needed to cover [span] with frames of width [tile]
/// stepping [step]. Clamps to 1 when the span fits inside one frame
/// (the `+1` formula overshoots near that boundary).
int _tileCount(double span, double tile, double step) {
  if (span <= tile || step <= 0) return 1;
  return (span / step).ceil() + 1;
}

/// One tile's absolute target plus its grid position. [index] is the
/// serpentine visit order; [row]/[col] are the grid coordinates (for
/// the UI cells).
class TilePosition {
  final double yawDeg;
  final double pitchDeg;
  final int row;
  final int col;
  final int index;

  const TilePosition({
    required this.yawDeg,
    required this.pitchDeg,
    required this.row,
    required this.col,
    required this.index,
  });
}

class PanoramaGrid {
  final List<TilePosition> tiles;
  final int nCols;
  final int nRows;
  final double hSpanDeg;
  final double vSpanDeg;
  final double stepHDeg;
  final double stepVDeg;
  final double tileHDeg;
  final double tileVDeg;

  /// stitched FOV ÷ single-frame FOV, per axis.
  final double coverageH;
  final double coverageV;

  const PanoramaGrid({
    required this.tiles,
    required this.nCols,
    required this.nRows,
    required this.hSpanDeg,
    required this.vSpanDeg,
    required this.stepHDeg,
    required this.stepVDeg,
    required this.tileHDeg,
    required this.tileVDeg,
    required this.coverageH,
    required this.coverageV,
  });

  int get totalShots => tiles.length;

  /// > [kPanoWarnTileCount] tiles — UI warns but allows.
  bool get warnCount => totalShots > kPanoWarnTileCount;

  /// > [kPanoMaxTileCount] tiles — UI locks Take (hard ceiling).
  bool get overCap => totalShots > kPanoMaxTileCount;

  /// Stitched FOV barely larger than one untiled frame in *both* axes —
  /// nothing meaningful to stitch. UI warns + locks Take. A legit 1×N
  /// strip passes because one axis clears the ratio.
  bool get degenerate =>
      coverageH < kPanoMinCoverageRatio && coverageV < kPanoMinCoverageRatio;

  /// Whether a run may start (the math side of the gate; the UI also
  /// requires both devices connected).
  bool get canRun => !overCap && !degenerate && totalShots >= 1;
}

/// Compute the symmetric, serpentine-ordered tile grid.
///
/// [focalStitch] sets the total span (the FOV the finished panorama
/// covers); [focalTaking] sets one tile's FOV (the mounted lens).
/// [overlap] is clamped to `[0, kOverlapMax]`. Non-positive focals are
/// guarded to 1 mm so the math never divides by zero.
PanoramaGrid computePanoramaGrid({
  required double focalStitch,
  required double focalTaking,
  required double overlap,
  double centreYaw = 0,
  double centrePitch = 0,
}) {
  final fStitch = focalStitch <= 0 ? 1.0 : focalStitch;
  final fTaking = focalTaking <= 0 ? 1.0 : focalTaking;
  final ov = overlap.clamp(0.0, kOverlapMax);

  final hSpan = _fovDeg(kSensorHalfWmm, fStitch);
  final vSpan = _fovDeg(kSensorHalfHmm, fStitch);
  final tileH = _fovDeg(kSensorHalfWmm, fTaking);
  final tileV = _fovDeg(kSensorHalfHmm, fTaking);
  final stepH = tileH * (1 - ov);
  final stepV = tileV * (1 - ov);

  final nCols = _tileCount(hSpan, tileH, stepH);
  final nRows = _tileCount(vSpan, tileV, stepV);

  // Symmetric about the centre: position p = centre + (k − (n−1)/2)·step.
  double yawForCol(int c) => centreYaw + (c - (nCols - 1) / 2.0) * stepH;
  double pitchForRow(int r) => centrePitch + (r - (nRows - 1) / 2.0) * stepV;

  final tiles = <TilePosition>[];
  var index = 0;
  for (var r = 0; r < nRows; r++) {
    // Serpentine: even rows left→right, odd rows right→left, so
    // consecutive visits are always adjacent.
    final cols = r.isEven
        ? List<int>.generate(nCols, (c) => c)
        : List<int>.generate(nCols, (c) => nCols - 1 - c);
    for (final c in cols) {
      tiles.add(TilePosition(
        yawDeg: yawForCol(c),
        pitchDeg: pitchForRow(r),
        row: r,
        col: c,
        index: index++,
      ));
    }
  }

  return PanoramaGrid(
    tiles: tiles,
    nCols: nCols,
    nRows: nRows,
    hSpanDeg: hSpan,
    vSpanDeg: vSpan,
    stepHDeg: stepH,
    stepVDeg: stepV,
    tileHDeg: tileH,
    tileVDeg: tileV,
    coverageH: hSpan / tileH,
    coverageV: vSpan / tileV,
  );
}
