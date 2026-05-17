import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Panasonic-format MJPEG-over-UDP wire-format extractor.
///
/// Each Lumix datagram carries one JPEG frame wrapped in a small
/// Panasonic-specific envelope (see SPEC-flutter-app.md Phase 2
/// "Live preview"):
///
/// ```
///   bytes [0..29]   header (content undocumented; ignored)
///   bytes [30..31]  BE-16 integer N (length of metadata block)
///   bytes [32..32+N-1]  metadata (overlay rects, AF boxes; ignored)
///   bytes [32+N..]  JPEG payload, FF D8 SOI .. FF D9 EOI
/// ```
///
/// The SOI offset is `(BE-16 at byte 30) + 32`. Crucially we do NOT
/// scan for `FF D8` from byte 32 onwards — the metadata block can
/// legitimately contain `FF D8`/`FF D9` byte sequences.
class FrameDecodeException implements Exception {
  const FrameDecodeException(this.message);
  final String message;
  @override
  String toString() => 'FrameDecodeException: $message';
}

/// Pull the JPEG payload out of one Panasonic UDP datagram. The
/// returned bytes are a view into [datagram] (no copy); callers that
/// need to outlive the source buffer should copy.
Uint8List extractJpegPayload(Uint8List datagram) {
  if (datagram.length < 32) {
    throw FrameDecodeException(
        'datagram too short: ${datagram.length} bytes, need ≥ 32');
  }
  final metaLen = (datagram[30] << 8) | datagram[31];
  final soiOffset = 32 + metaLen;
  if (soiOffset + 2 > datagram.length) {
    throw FrameDecodeException(
        'computed SOI offset $soiOffset past end of '
        '${datagram.length}-byte datagram');
  }
  if (datagram[soiOffset] != 0xFF || datagram[soiOffset + 1] != 0xD8) {
    final got = '${datagram[soiOffset].toRadixString(16).padLeft(2, '0')} '
        '${datagram[soiOffset + 1].toRadixString(16).padLeft(2, '0')}';
    throw FrameDecodeException(
        'no SOI at computed offset $soiOffset (got $got, expected ff d8)');
  }
  if (datagram[datagram.length - 2] != 0xFF ||
      datagram[datagram.length - 1] != 0xD9) {
    throw const FrameDecodeException('no EOI at end of datagram');
  }
  return Uint8List.sublistView(datagram, soiOffset);
}

/// UDP receiver that emits a stream of JPEG payloads, one per
/// successfully-parsed Panasonic datagram.
///
/// Always drains the kernel UDP buffer (reads every datagram), but
/// skips emitting a JPEG if another was emitted within
/// [frameMinInterval] — this is the spec's ~5 fps cap to keep
/// downstream decode load sane. The drop happens before any
/// downstream decode work, so even when an Isolate or worker is
/// involved it doesn't have to spawn-and-discard.
class MjpegUdpStream {
  MjpegUdpStream._(this._socket, this._frameMinInterval);

  final RawDatagramSocket _socket;
  final Duration _frameMinInterval;

  late final StreamSubscription<RawSocketEvent> _sub;
  final _controller = StreamController<Uint8List>.broadcast();
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  /// Bind a UDP listener on [port]. [frameMinInterval] is the
  /// minimum gap between consecutive emitted JPEG frames; defaults
  /// to 200 ms (~5 fps), matching the SPEC default. The camera
  /// still streams at full rate; we just drop the surplus.
  static Future<MjpegUdpStream> open(
    int port, {
    Duration frameMinInterval = const Duration(milliseconds: 200),
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
    );
    socket.readEventsEnabled = true;
    final s = MjpegUdpStream._(socket, frameMinInterval);
    s._listen();
    return s;
  }

  Stream<Uint8List> get jpegFrames => _controller.stream;

  void _listen() {
    _sub = _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket.receive();
      if (dg == null) return;
      final now = DateTime.now();
      if (now.difference(_lastEmit) < _frameMinInterval) return;
      try {
        final view = extractJpegPayload(dg.data);
        _lastEmit = now;
        // Copy out of the view — the source buffer may be reused
        // by the socket on the next read.
        _controller.add(Uint8List.fromList(view));
      } on FrameDecodeException {
        // Malformed datagram — skip silently; the next one is ~33 ms
        // away. (Logging here would flood under packet loss.)
      }
    });
  }

  Future<void> close() async {
    await _sub.cancel();
    _socket.close();
    await _controller.close();
  }
}
