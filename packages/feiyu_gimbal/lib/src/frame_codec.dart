import 'dart:typed_data';

import 'crc.dart';

/// AK protocol frame as defined in `AkCmdWriter.generateWholeCmd`.
/// See PROTOCOL-NOTES.md §5 for the byte layout.
class AkFrame {
  static const int header1 = 0xA5;
  static const int header2 = 0x5A;
  static const int constByte = 0x03;
  static const int overheadBytes = 11; // 2 header + 1 const + 1 target + 2 cmd16 + 1 msgId + 2 length + 2 crc

  final int target;
  final int cmdType; // 0..7
  final int cmdId;   // 0..0x1FFF
  final int msgId;
  final Uint8List payload;

  AkFrame({
    required this.target,
    required this.cmdType,
    required this.cmdId,
    this.msgId = 0,
    Uint8List? payload,
  })  : payload = payload ?? Uint8List(0),
        assert(target >= 0 && target <= 0xFF),
        assert(cmdType >= 0 && cmdType <= 0x07),
        assert(cmdId >= 0 && cmdId <= 0x1FFF),
        assert(msgId >= 0 && msgId <= 0xFF);

  /// Serialize to wire bytes. Computes and appends the CRC.
  Uint8List encode() {
    final L = payload.length;
    final out = Uint8List(overheadBytes + L);
    out[0] = header1;
    out[1] = header2;
    out[2] = constByte;
    out[3] = target & 0xFF;
    final cmd16 = ((cmdType & 0x07) << 13) | (cmdId & 0x1FFF);
    out[4] = cmd16 & 0xFF;
    out[5] = (cmd16 >> 8) & 0xFF;
    out[6] = msgId & 0xFF;
    out[7] = L & 0xFF;
    out[8] = (L >> 8) & 0xFF;
    for (int i = 0; i < L; i++) {
      out[9 + i] = payload[i] & 0xFF;
    }
    final crc = crc16Xmodem(out.sublist(2, 9 + L));
    out[9 + L] = crc & 0xFF;
    out[10 + L] = (crc >> 8) & 0xFF;
    return out;
  }

  @override
  String toString() {
    final p = payload.isEmpty
        ? ''
        : ' payload=${payload.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ')}';
    return 'AkFrame(target=$target cmdType=$cmdType cmdId=$cmdId msgId=$msgId len=${payload.length}$p)';
  }
}

/// Why decoding failed.
enum DecodeError { tooShort, badHeader, badCrc }

class DecodeResult {
  final AkFrame? frame;
  final DecodeError? error;
  const DecodeResult.ok(AkFrame this.frame) : error = null;
  const DecodeResult.fail(DecodeError this.error) : frame = null;
}

/// Parse a single complete frame buffer. Returns the parsed frame or an
/// error code. Strict — extra trailing bytes are an error.
DecodeResult decodeFrame(List<int> bytes) {
  if (bytes.length < AkFrame.overheadBytes) {
    return const DecodeResult.fail(DecodeError.tooShort);
  }
  if (bytes[0] != AkFrame.header1 || bytes[1] != AkFrame.header2) {
    return const DecodeResult.fail(DecodeError.badHeader);
  }
  final L = bytes[7] | (bytes[8] << 8);
  if (bytes.length < AkFrame.overheadBytes + L) {
    return const DecodeResult.fail(DecodeError.tooShort);
  }
  final crcInput = bytes.sublist(2, 9 + L);
  final expectedCrc = bytes[9 + L] | (bytes[10 + L] << 8);
  final actualCrc = crc16Xmodem(crcInput);
  if (actualCrc != expectedCrc) {
    return const DecodeResult.fail(DecodeError.badCrc);
  }
  final cmd16 = bytes[4] | (bytes[5] << 8);
  final cmdType = (cmd16 >> 13) & 0x07;
  final cmdId = cmd16 & 0x1FFF;
  final frame = AkFrame(
    target: bytes[3],
    cmdType: cmdType,
    cmdId: cmdId,
    msgId: bytes[6],
    payload: Uint8List.fromList(bytes.sublist(9, 9 + L)),
  );
  return DecodeResult.ok(frame);
}

/// Streaming frame extractor. Feed it raw notify chunks; it emits
/// complete validated frames via [onFrame]. Resyncs on bad header/CRC by
/// advancing one byte at a time.
class FrameStreamDecoder {
  final void Function(AkFrame frame) onFrame;
  final void Function(DecodeError error)? onError;
  final List<int> _buffer = <int>[];

  FrameStreamDecoder({required this.onFrame, this.onError});

  void feed(List<int> bytes) {
    _buffer.addAll(bytes);
    _extract();
  }

  void _extract() {
    while (true) {
      // Find sync.
      while (_buffer.length >= 2 &&
          !(_buffer[0] == AkFrame.header1 && _buffer[1] == AkFrame.header2)) {
        _buffer.removeAt(0);
      }
      if (_buffer.length < AkFrame.overheadBytes) return;
      final L = _buffer[7] | (_buffer[8] << 8);
      final total = AkFrame.overheadBytes + L;
      if (_buffer.length < total) return;

      final frameBytes = _buffer.sublist(0, total);
      final result = decodeFrame(frameBytes);
      if (result.frame != null) {
        onFrame(result.frame!);
        _buffer.removeRange(0, total);
      } else {
        // Bad CRC or bad header — drop one byte and resync.
        onError?.call(result.error!);
        _buffer.removeAt(0);
      }
    }
  }

  int get bufferedBytes => _buffer.length;
}
