import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/ble/crc.dart';
import 'package:sciens_gimbal_controller/ble/frame_codec.dart';

void main() {
  group('crc16Xmodem', () {
    test('canonical "123456789" → 0x31C3', () {
      final bytes = '123456789'.codeUnits;
      expect(crc16Xmodem(bytes), 0x31C3);
    });

    test('empty input → 0x0000', () {
      expect(crc16Xmodem(const <int>[]), 0x0000);
    });

    test('single 0x00 byte → 0x0000', () {
      expect(crc16Xmodem(const [0x00]), 0x0000);
    });
  });

  group('AkFrame.encode', () {
    test('GET cmdId 30 (GIMBAL_STATE) with no payload', () {
      final f = AkFrame(target: 0, cmdType: 2, cmdId: 30);
      final bytes = f.encode();
      // header + const + target + cmd16(LE) + msgId + len(LE) + crc(LE) = 11 bytes
      expect(bytes.length, 11);
      expect(bytes[0], 0xA5);
      expect(bytes[1], 0x5A);
      expect(bytes[2], 0x03);
      expect(bytes[3], 0x00); // target=GIMBAL_A
      // cmd16 = (2 << 13) | 30 = 0x401E → LE bytes 1E 40
      expect(bytes[4], 0x1E);
      expect(bytes[5], 0x40);
      expect(bytes[6], 0x00); // msgId
      expect(bytes[7], 0x00); // len lo
      expect(bytes[8], 0x00); // len hi
      // CRC over bytes [2..8] = [03 00 1E 40 00 00 00]
      final expectedCrc = crc16Xmodem([0x03, 0x00, 0x1E, 0x40, 0x00, 0x00, 0x00]);
      expect(bytes[9], expectedCrc & 0xFF);
      expect(bytes[10], (expectedCrc >> 8) & 0xFF);
    });

    test('PUSH CONTROL_JOYSTICK with 5-byte payload', () {
      // enableRoll=0, course=100 (0x0064), pitch=-50 (0xFFCE)
      final payload = Uint8List.fromList([0x00, 0x64, 0x00, 0xCE, 0xFF]);
      final f = AkFrame(target: 0, cmdType: 0, cmdId: 14, payload: payload);
      final bytes = f.encode();
      expect(bytes.length, 16);
      expect(bytes.sublist(0, 9),
          Uint8List.fromList([0xA5, 0x5A, 0x03, 0x00, 0x0E, 0x00, 0x00, 0x05, 0x00]));
      expect(bytes.sublist(9, 14), payload);
      // verify CRC roundtrips through decode
      final res = decodeFrame(bytes);
      expect(res.frame, isNotNull);
      expect(res.frame!.payload, payload);
    });
  });

  group('decodeFrame', () {
    test('encode → decode roundtrip preserves all fields', () {
      final f = AkFrame(
        target: 0,
        cmdType: 1,
        cmdId: 51,
        msgId: 42,
        payload: Uint8List.fromList([0x02]),
      );
      final res = decodeFrame(f.encode());
      expect(res.frame, isNotNull);
      final d = res.frame!;
      expect(d.target, 0);
      expect(d.cmdType, 1);
      expect(d.cmdId, 51);
      expect(d.msgId, 42);
      expect(d.payload, Uint8List.fromList([0x02]));
    });

    test('bad header returns badHeader error', () {
      final bytes = [0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
      final res = decodeFrame(bytes);
      expect(res.frame, isNull);
      expect(res.error, DecodeError.badHeader);
    });

    test('short buffer returns tooShort error', () {
      final res = decodeFrame([0xA5, 0x5A, 0x03]);
      expect(res.error, DecodeError.tooShort);
    });

    test('corrupt CRC returns badCrc error', () {
      final f = AkFrame(target: 0, cmdType: 2, cmdId: 30);
      final bytes = Uint8List.fromList(f.encode());
      bytes[bytes.length - 1] ^= 0xFF; // flip CRC high byte
      final res = decodeFrame(bytes);
      expect(res.error, DecodeError.badCrc);
    });
  });

  group('FrameStreamDecoder', () {
    test('emits frames fed in arbitrary chunks', () {
      final f1 = AkFrame(target: 0, cmdType: 2, cmdId: 30);
      final f2 = AkFrame(
        target: 0,
        cmdType: 1,
        cmdId: 51,
        msgId: 1,
        payload: Uint8List.fromList([0x02]),
      );
      final combined = [...f1.encode(), ...f2.encode()];
      final captured = <AkFrame>[];
      final dec = FrameStreamDecoder(onFrame: captured.add);
      // Feed in tiny chunks of 3 bytes.
      for (int i = 0; i < combined.length; i += 3) {
        dec.feed(combined.sublist(i, (i + 3).clamp(0, combined.length)));
      }
      expect(captured.length, 2);
      expect(captured[0].cmdId, 30);
      expect(captured[1].cmdId, 51);
      expect(captured[1].payload, Uint8List.fromList([0x02]));
    });

    test('resyncs past garbage before a valid frame', () {
      final f = AkFrame(target: 0, cmdType: 2, cmdId: 30);
      final junk = [0x12, 0x34, 0xA5, 0xFF, 0xA5, 0x5B];
      final stream = [...junk, ...f.encode()];
      final captured = <AkFrame>[];
      FrameStreamDecoder(onFrame: captured.add).feed(stream);
      expect(captured.length, 1);
      expect(captured.single.cmdId, 30);
    });
  });
}
