import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../camera/jpeg_decoder.dart';
import 'pano_tile_image.dart';

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

/// Phase 6 — drives the native OpenPano stitcher over a `MethodChannel`.
/// The Dart side writes each tile to a temp file under
/// `cacheDir/pano_stitch/` (cleared per run), hands the **paths** to the
/// native side (file-path transport sidesteps the ~1 MB Binder limit),
/// and decodes the returned result file into a `ui.Image`.
///
/// The stitch runs entirely in the vendored OpenPano C++ (via the JNI
/// shim); this class is the only Dart code that knows the stitch exists.
/// See SPEC-flutter-app.md "Phase 6".
class PanoStitcher {
  PanoStitcher({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('at.sciens.gimbal_controller/stitch');

  final MethodChannel _channel;

  /// Stitch [tilesRowMajor] (already in spatial row-major order) into a
  /// single panorama. [nCols] is the grid width, used to restrict feature
  /// matching to neighbouring tiles. [onStage] reports the coarse stage
  /// for the progress overlay. Returns an OK image or a failure.
  Future<StitchResult> stitch(
    List<PanoTileImage> tilesRowMajor, {
    required int nCols,
    void Function(String stage, double? progress)? onStage,
  }) async {
    if (tilesRowMajor.length < 2) {
      return StitchResult.failed('Need at least two tiles to stitch.');
    }

    final dir = Directory('${(await getTemporaryDirectory()).path}/pano_stitch');
    try {
      // Clear any previous run, then recreate.
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);

      onStage?.call('Preparing tiles…', null);
      final paths = <String>[];
      for (var i = 0; i < tilesRowMajor.length; i++) {
        final bytes = await _encodeTilePng(tilesRowMajor[i]);
        final file = File('${dir.path}/tile_$i.png');
        file.writeAsBytesSync(bytes, flush: true);
        paths.add(file.path);
      }
      final outPath = '${dir.path}/result.png'; // OpenPano writes PNG (lodepng)

      // Poll the native progress file while the (opaque) stitch runs.
      onStage?.call('Stitching…', null);
      final progressFile = File('${dir.path}/progress.txt');
      final timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        if (onStage == null) return;
        try {
          if (!progressFile.existsSync()) return;
          final parts = progressFile.readAsStringSync().trim().split(' ');
          final done = parts.length >= 2 ? (int.tryParse(parts[1]) ?? 0) : 0;
          final total = parts.length >= 3 ? (int.tryParse(parts[2]) ?? 0) : 0;
          final frac = total > 0 ? done / total : 0.0;
          // Phone weighting: features/matching parallelise (quick);
          // estimation (bundle adjustment) + blending are serial and
          // dominate, so they get the bulk of the bar.
          switch (parts[0]) {
            case 'features':
              onStage('Detecting features $done/$total', frac * 0.35);
            case 'matching':
              onStage('Matching tiles $done/$total', 0.35 + frac * 0.10);
            case 'estimating':
              if (total > 0) {
                onStage('Estimating geometry $done/$total', 0.45 + frac * 0.30);
              } else {
                onStage('Estimating geometry…', null);
              }
            case 'blending':
              onStage('Blending $done/$total', 0.75 + frac * 0.25);
          }
        } catch (_) {
          // Best effort.
        }
      });

      final String? resultPath;
      try {
        resultPath = await _channel.invokeMethod<String>('stitch', {
          'paths': paths,
          'outPath': outPath,
          'nCols': nCols,
        });
      } finally {
        timer.cancel();
      }
      if (resultPath == null) {
        return StitchResult.failed('Stitcher returned no image.');
      }

      final image = await decodeJpeg(
        File(resultPath).readAsBytesSync(),
        targetWidth: 3000,
      );
      return StitchResult.ok(image);
    } on PlatformException catch (e) {
      return StitchResult.failed(_messageFor(e));
    } catch (e) {
      return StitchResult.failed('$e');
    } finally {
      // Tiles + result decoded into memory — drop the temp files.
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {
        // Best effort.
      }
    }
  }

  String _messageFor(PlatformException e) {
    switch (e.code) {
      case 'stitch_failed':
        return "Couldn't stitch — not enough overlap or detail between "
            'frames.';
      default:
        return e.message ?? 'Stitch failed (${e.code}).';
    }
  }

  /// Render one tile's source sub-rectangle to PNG bytes. Live tiles
  /// have `src` == the whole image; demo tiles carry a `(col,row)`
  /// sub-rect of the shared asset.
  Future<Uint8List> _encodeTilePng(PanoTileImage tile) async {
    final w = tile.src.width.round();
    final h = tile.src.height.round();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      tile.image,
      tile.src,
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint(),
    );
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(w, h);
    try {
      final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      cropped.dispose();
      picture.dispose();
    }
  }
}
