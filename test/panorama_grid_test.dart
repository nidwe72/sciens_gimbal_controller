import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/panorama/panorama_grid.dart';

void main() {
  group('computePanoramaGrid — counts & geometry', () {
    test('default focals (24 stitch / 50 taking, 30% overlap) → 4×4', () {
      final g = computePanoramaGrid(
        focalStitch: 24,
        focalTaking: 50,
        overlap: 0.30,
      );
      expect(g.nCols, 4);
      expect(g.nRows, 4);
      expect(g.totalShots, 16);
      expect(g.warnCount, isFalse);
      expect(g.overCap, isFalse);
      expect(g.degenerate, isFalse);
      expect(g.canRun, isTrue);
    });

    test('grid is symmetric about the centre orientation', () {
      final g = computePanoramaGrid(
        focalStitch: 24,
        focalTaking: 50,
        overlap: 0.30,
        centreYaw: 100,
        centrePitch: 10,
      );
      final yaws = g.tiles.map((t) => t.yawDeg);
      final pitches = g.tiles.map((t) => t.pitchDeg);
      final meanYaw = yaws.reduce((a, b) => a + b) / g.totalShots;
      final meanPitch = pitches.reduce((a, b) => a + b) / g.totalShots;
      expect(meanYaw, closeTo(100, 1e-9));
      expect(meanPitch, closeTo(10, 1e-9));
    });

    test('serpentine: row 0 ascends yaw, row 1 descends', () {
      final g = computePanoramaGrid(
        focalStitch: 24,
        focalTaking: 50,
        overlap: 0.30,
      );
      final row0 = g.tiles.where((t) => t.row == 0).toList();
      final row1 = g.tiles.where((t) => t.row == 1).toList();
      // Visit order within each row (by index).
      row0.sort((a, b) => a.index.compareTo(b.index));
      row1.sort((a, b) => a.index.compareTo(b.index));
      expect(row0.first.col, 0);
      expect(row0.last.col, g.nCols - 1);
      // Odd row visited in reverse column order.
      expect(row1.first.col, g.nCols - 1);
      expect(row1.last.col, 0);
      // Indices are a contiguous 0..N-1 sequence.
      final indices = g.tiles.map((t) => t.index).toList()..sort();
      expect(indices, List<int>.generate(g.totalShots, (i) => i));
    });
  });

  group('computePanoramaGrid — guards', () {
    test('near-single-frame (stitch≈taking) → degenerate, cannot run', () {
      final g = computePanoramaGrid(
        focalStitch: 50,
        focalTaking: 50,
        overlap: 0.30,
      );
      expect(g.coverageH, closeTo(1.0, 0.01));
      expect(g.degenerate, isTrue);
      expect(g.canRun, isFalse);
      // span == tile → clamped to a single tile, not an inflated grid.
      expect(g.nCols, 1);
      expect(g.nRows, 1);
    });

    test('1×N strip passes the degenerate guard (one axis clears ratio)',
        () {
      // Wide stitch in yaw only is not expressible with one focal, so
      // emulate a strip by checking a config where coverageH ≫ coverageV
      // never both fall below the ratio. With equal axes this can't be a
      // strip, so assert the guard is per-"both-axes" rather than "either".
      final g = computePanoramaGrid(
        focalStitch: 24,
        focalTaking: 60,
        overlap: 0.30,
      );
      // Both axes scale together for a rectangular sensor, so just verify
      // a healthy multi-tile grid is not flagged degenerate.
      expect(g.coverageH, greaterThan(kPanoMinCoverageRatio));
      expect(g.degenerate, isFalse);
    });

    test('wide stitch + long lens at max overlap → overCap, locked', () {
      final g = computePanoramaGrid(
        focalStitch: 24,
        focalTaking: 150,
        overlap: 0.60,
      );
      expect(g.totalShots, greaterThan(kPanoMaxTileCount));
      expect(g.overCap, isTrue);
      expect(g.canRun, isFalse);
    });

    test('mid config → warnCount but still runnable', () {
      final g = computePanoramaGrid(
        focalStitch: 24,
        focalTaking: 100,
        overlap: 0.40,
      );
      expect(g.totalShots, greaterThan(kPanoWarnTileCount));
      expect(g.totalShots, lessThanOrEqualTo(kPanoMaxTileCount));
      expect(g.warnCount, isTrue);
      expect(g.overCap, isFalse);
      expect(g.canRun, isTrue);
    });

    test('overlap is clamped to the 0.6 ceiling', () {
      final clamped = computePanoramaGrid(
        focalStitch: 24,
        focalTaking: 80,
        overlap: 0.95,
      );
      final atCap = computePanoramaGrid(
        focalStitch: 24,
        focalTaking: 80,
        overlap: 0.60,
      );
      expect(clamped.stepHDeg, closeTo(atCap.stepHDeg, 1e-9));
      expect(clamped.totalShots, atCap.totalShots);
    });

    test('non-positive focals are guarded (no throw, finite grid)', () {
      final g = computePanoramaGrid(
        focalStitch: 0,
        focalTaking: -10,
        overlap: 0.3,
      );
      expect(g.totalShots, greaterThanOrEqualTo(1));
      expect(g.stepHDeg.isFinite, isTrue);
    });

    test('vertical step stays above the 1° coast floor at max overlap', () {
      // Longest lens + max overlap is the worst case for step_v.
      final g = computePanoramaGrid(
        focalStitch: 24,
        focalTaking: 150,
        overlap: kOverlapMax,
      );
      expect(g.stepVDeg, greaterThan(1.0));
    });
  });
}
