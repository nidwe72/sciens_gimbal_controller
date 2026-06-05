import 'dart:ui' as ui;

/// One panorama tile's rendered image plus the source rectangle to draw
/// from it.
///
/// - **Demo mode**: many tiles share one decoded asset [image] and each
///   carries its own [src] sub-rectangle (the `(col, row)` slice), so the
///   completed grid reassembles the asset into a mosaic. [ownsImage] is
///   `false` — the shared asset is owned/disposed by `CameraConnection`.
/// - **Live mode**: each tile owns a distinct SM-thumbnail [image] drawn
///   whole ([src] == the image's full bounds). [ownsImage] is `true` —
///   the controller disposes it when the run resets.
///
/// See SPEC-flutter-app.md "Phase 4 — Per-tile tile images".
class PanoTileImage {
  PanoTileImage({
    required this.image,
    required this.src,
    required this.ownsImage,
  });

  final ui.Image image;
  final ui.Rect src;
  final bool ownsImage;
}
