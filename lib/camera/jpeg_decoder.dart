import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decode a JPEG byte sequence into a `dart:ui` [ui.Image].
///
/// **Why no manual Isolate.** The SPEC originally called for an
/// `Isolate.run`-based decoder. In practice
/// [ui.instantiateImageCodec] already dispatches the actual codec
/// work to the Flutter engine's image worker (a native thread pool),
/// so the Dart main isolate is not blocked. Spawning an additional
/// Dart isolate would only add per-frame setup cost and force a
/// roundtrip of decoded pixels back to the main isolate (a
/// [ui.Image] can't cross isolate boundaries directly).
///
/// If profiling later shows frame jitter, options include:
///   - Using `decodeImageFromPixels` from raw RGBA on a worker.
///   - Pre-allocating a long-lived isolate.
/// Neither is needed for the SPEC's ~5 fps cap.
Future<ui.Image> decodeJpeg(Uint8List jpeg) async {
  final codec = await ui.instantiateImageCodec(jpeg);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}
