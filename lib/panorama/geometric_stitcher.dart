import 'dart:ui' as ui;

import 'panorama_grid.dart';
import 'pano_tile_image.dart';

/// Geometric placement (Panoramique): paste each tile at its **known**
/// grid position (`srcFrac` from the gimbal geometry) on a flat canvas,
/// feather-blending the overlaps. Deterministic, instant, and — unlike
/// OpenPano's spherical camera-estimation — **flat, with no inward
/// projection shift**. Ideal for a framing preview. See SPEC Phase 6.
///
/// Works for both modes: demo tiles share one asset image (`src` = the
/// crop), live tiles are standalone thumbnails (`src` = full) — both are
/// drawn from `src` into their `srcFrac` destination.
Future<ui.Image> geometricStitch(
  PanoramaGrid grid,
  List<PanoTileImage?> tileImages, {
  int targetWidth = 2200,
}) async {
  // Canvas aspect = the grid's angular coverage aspect.
  final totalH = (grid.nCols - 1) * grid.stepHDeg + grid.tileHDeg;
  final totalV = (grid.nRows - 1) * grid.stepVDeg + grid.tileVDeg;
  final w = targetWidth;
  final h = (targetWidth * totalV / totalH).round().clamp(1, 8000);
  final wD = w.toDouble(), hD = h.toDouble();

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, wD, hD));
  canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, wD, hD), ui.Paint()..color = const ui.Color(0xFF000000));

  for (final t in grid.tiles) {
    final ti = t.index < tileImages.length ? tileImages[t.index] : null;
    if (ti == null) continue;
    final dst = ui.Rect.fromLTWH(
      t.srcFracLeft * wD,
      t.srcFracTop * hD,
      t.srcFracWidth * wD,
      t.srcFracHeight * hD,
    );
    // Feather the tile into the canvas: draw it, then multiply its alpha
    // by a centre-opaque → edge-transparent mask so overlaps blend.
    canvas.saveLayer(dst, ui.Paint());
    canvas.drawImageRect(
      ti.image,
      _coverSrc(ti.src, dst.size),
      dst,
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    canvas.drawRect(
      dst,
      ui.Paint()
        ..blendMode = ui.BlendMode.dstIn
        ..shader = ui.Gradient.radial(
          dst.center,
          dst.longestSide * 0.5,
          const [ui.Color(0xFFFFFFFF), ui.Color(0x00FFFFFF)],
          const [0.55, 1.0],
        ),
    );
    canvas.restore();
  }

  return recorder.endRecording().toImage(w, h);
}

/// Sub-rect of [src] matching [cell]'s aspect (centred) for cover-fit.
ui.Rect _coverSrc(ui.Rect src, ui.Size cell) {
  final srcAr = src.width / src.height;
  final dstAr = cell.width / cell.height;
  var w = src.width, h = src.height;
  if (srcAr > dstAr) {
    w = src.height * dstAr;
  } else {
    h = src.width / dstAr;
  }
  return ui.Rect.fromCenter(center: src.center, width: w, height: h);
}
