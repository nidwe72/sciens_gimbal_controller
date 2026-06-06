import 'dart:ui' as ui;

/// Outcome of a stitch attempt: an OK image, or a human-readable error.
class StitchResult {
  StitchResult.ok(this.image)
      : error = null,
        ok = true;
  StitchResult.failed(this.error)
      : image = null,
        ok = false;

  final bool ok;
  final ui.Image? image;
  final String? error;
}
