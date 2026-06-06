import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../camera/jpeg_decoder.dart';
import 'pano_tile_image.dart';
import 'stitch_result.dart';

/// The `advanced` StitchMode. Returns a [StitchResult] (same shape the simple
/// path's caller expects) but drives the in-process panostitch-renderer over its
/// localhost HTTP/GraphQL surface: tiles go up via `POST /upload`, a `stitch`
/// mutation (with the chosen [projection]) kicks off the Chaquopy/Python
/// stitcher, the `stitchEvents` WebSocket subscription streams live progress,
/// and the panorama PNG comes back from `GET /result/{stitchId}`.
///
/// The backend runs in-process (started in MainActivity); its port is obtained
/// once via the `…/backend` MethodChannel.
class ServerStitcher {
  ServerStitcher({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('at.sciens.gimbal_controller/backend');

  final MethodChannel _channel;
  Uri? _base;

  Future<Uri> _baseUrl() async {
    final cached = _base;
    if (cached != null) return cached;
    final port = await _channel.invokeMethod<int>('getBackendPort');
    if (port == null || port <= 0) {
      throw StateError('backend returned no port ($port)');
    }
    return _base = Uri.parse('http://127.0.0.1:$port');
  }

  /// Stitch [tilesRowMajor] via the server with the given [projection]
  /// (`AFFINE` / `RECTILINEAR` / `SPHERICAL`). [onStage] reports a coarse stage
  /// label + [0,1] progress for the overlay.
  Future<StitchResult> stitch(
    List<PanoTileImage> tilesRowMajor, {
    required int nCols,
    required String projection,
    void Function(String stage, double? progress)? onStage,
  }) async {
    if (tilesRowMajor.length < 2) {
      return StitchResult.failed('Need at least two tiles to stitch.');
    }
    try {
      final base = await _baseUrl();

      // 1. Upload each tile PNG, collect upload ids (in row-major order).
      onStage?.call('Preparing tiles…', null);
      final uploadIds = <String>[];
      for (final tile in tilesRowMajor) {
        final png = await _encodeTilePng(tile);
        final res = await http.post(
          base.resolve('/upload'),
          headers: const {'Content-Type': 'application/octet-stream'},
          body: png,
        );
        if (res.statusCode != 200) {
          return StitchResult.failed('upload failed (${res.statusCode})');
        }
        uploadIds.add(jsonDecode(res.body)['uploadId'] as String);
      }

      // 2. Kick off the stitch; get a stitchId back immediately.
      onStage?.call('Stitching…', null);
      final stitchId = await _mutateStitch(base, uploadIds, nCols, projection);

      // 3. Stream progress over the subscription (best-effort), while…
      final progressSub = _streamProgress(base, stitchId, onStage);

      // 4. …blocking on the result bytes (GET /result waits for completion).
      try {
        final res = await http.get(base.resolve('/result/$stitchId'));
        if (res.statusCode != 200) {
          return StitchResult.failed(_resultError(res));
        }
        final image = await decodeJpeg(res.bodyBytes, targetWidth: 3000);
        return StitchResult.ok(image);
      } finally {
        await progressSub;
      }
    } on PlatformException catch (e) {
      return StitchResult.failed(e.message ?? 'Backend error (${e.code}).');
    } catch (e) {
      return StitchResult.failed('$e');
    }
  }

  Future<String> _mutateStitch(
      Uri base, List<String> uploadIds, int nCols, String projection) async {
    const query =
        r'mutation($ids:[ID!]!,$n:Int,$p:Projection){ stitch(uploadIds:$ids, nCols:$n, projection:$p) }';
    final res = await http.post(
      base.resolve('/graphql'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'query': query,
        'variables': {'ids': uploadIds, 'n': nCols, 'p': projection},
      }),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final errors = body['errors'];
    if (errors != null) throw StateError('stitch mutation: $errors');
    return body['data']['stitch'] as String;
  }

  /// Subscribe to `stitchEvents` and forward `done` to [onStage]. Completes
  /// when the server emits a terminal status (or the socket drops). Failures
  /// here are non-fatal — the result still arrives via GET /result.
  Future<void> _streamProgress(
    Uri base,
    String stitchId,
    void Function(String stage, double? progress)? onStage,
  ) async {
    if (onStage == null) return;
    final wsUri = base.replace(scheme: 'ws', path: '/graphql-ws');
    final done = Completer<void>();
    WebSocketChannel? channel;
    try {
      channel = WebSocketChannel.connect(wsUri);
      const opId = '1';
      channel.sink.add(jsonEncode({'type': 'connection_init'}));
      late final StreamSubscription sub;
      sub = channel.stream.listen(
        (raw) {
          try {
            final m = jsonDecode(raw as String) as Map<String, dynamic>;
            switch (m['type']) {
              case 'connection_ack':
                channel!.sink.add(jsonEncode({
                  'id': opId,
                  'type': 'subscribe',
                  'payload': {
                    'query':
                        r'subscription($id:ID!){ stitchEvents(stitchId:$id){ done status } }',
                    'variables': {'id': stitchId},
                  },
                }));
              case 'next':
                final ev = (m['payload']?['data'])?['stitchEvents']
                    as Map<String, dynamic>?;
                if (ev != null) {
                  final d = ev['done'];
                  if (d is num) onStage(_labelFor(d.toDouble()), d.toDouble());
                  final status = ev['status'] as String?;
                  if (status != null && status != 'PROGRESS') {
                    if (!done.isCompleted) done.complete();
                  }
                }
              case 'complete':
              case 'error':
                if (!done.isCompleted) done.complete();
            }
          } catch (_) {/* best effort */}
        },
        onError: (_) => done.isCompleted ? null : done.complete(),
        onDone: () => done.isCompleted ? null : done.complete(),
      );
      await done.future;
      await sub.cancel();
    } catch (_) {
      if (!done.isCompleted) done.complete();
    } finally {
      await channel?.sink.close();
    }
  }

  /// Map the server's already-weighted [0,1] `done` onto a stage label that
  /// matches the OpenPano path's wording (the python worker uses the same
  /// 35/45/60/85 phase boundaries).
  String _labelFor(double done) {
    if (done < 0.35) return 'Detecting features…';
    if (done < 0.45) return 'Matching tiles…';
    if (done < 0.60) return 'Estimating geometry…';
    if (done < 0.85) return 'Warping…';
    if (done < 1.0) return 'Blending…';
    return 'Finishing…';
  }

  String _resultError(http.Response res) {
    final body = res.body.trim();
    if (res.statusCode == 410) return 'Stitch was cancelled.';
    if (body.isNotEmpty) return body;
    return 'Stitch failed (${res.statusCode}).';
  }

  /// Render the tile's `src`
  /// sub-rectangle into a `w×h` image and encode it.
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
