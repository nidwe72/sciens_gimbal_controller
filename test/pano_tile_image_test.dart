import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/camera/camera_connection.dart';
import 'package:sciens_gimbal_controller/panorama/panorama_grid.dart';

/// The demo branch of `CameraConnection.fetchPanoTile` (PR 18a + PR 20):
/// it maps a tile's fractional window onto the shared bundled asset,
/// clamped to bounds, never owning the image — and adjacent tiles
/// **overlap** so the Phase 6 stitcher has correspondences.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CameraConnection.fetchPanoTile — demo overlapping crop', () {
    test('shared, non-owned crops sized + positioned to the tile window',
        () async {
      final conn = CameraConnection(pollInterval: const Duration(hours: 1));
      addTearDown(conn.dispose);
      await conn.connect(demo: true);
      expect(conn.isDemo, isTrue);

      final grid = computePanoramaGrid(
        focalStitch: 24,
        focalTaking: 50,
        overlap: 0.30,
      );
      // Two horizontally-adjacent tiles in the same row.
      final a = grid.tiles.firstWhere((t) => t.row == 0 && t.col == 0);
      final b = grid.tiles.firstWhere((t) => t.row == 0 && t.col == 1);

      final ta = await conn.fetchPanoTile(
        srcFracLeft: a.srcFracLeft,
        srcFracTop: a.srcFracTop,
        srcFracWidth: a.srcFracWidth,
        srcFracHeight: a.srcFracHeight,
      );
      final tb = await conn.fetchPanoTile(
        srcFracLeft: b.srcFracLeft,
        srcFracTop: b.srcFracTop,
        srcFracWidth: b.srcFracWidth,
        srcFracHeight: b.srcFracHeight,
      );
      expect(ta, isNotNull);
      expect(tb, isNotNull);
      expect(ta!.ownsImage, isFalse, reason: 'asset is shared, not owned');
      expect(identical(ta.image, tb!.image), isTrue);

      final aw = ta.image.width.toDouble();
      // Crops stay within the asset bounds.
      expect(ta.src.left, greaterThanOrEqualTo(0));
      expect(ta.src.right, lessThanOrEqualTo(aw));
      expect(tb.src.right, lessThanOrEqualTo(aw));

      // Adjacent columns overlap: tile B starts before tile A ends.
      expect(tb.src.left, lessThan(ta.src.right),
          reason: 'overlap means neighbouring windows share pixels');
      // ...and B is to the right of A.
      expect(tb.src.left, greaterThan(ta.src.left));
    });
  });
}
