import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/camera/mjpeg_udp_stream.dart';

Uint8List _loadFixture(String name) =>
    File('test/fixtures/lumix/$name').readAsBytesSync();

void main() {
  group('extractJpegPayload — synthesized Panasonic datagrams', () {
    // Fixture 01: N=0; SOI lands at offset 32 exactly.
    test('fixture 01 (N=0) returns a valid JPEG payload', () {
      final dg = _loadFixture('mjpeg_frame_synth_01.bin');
      final jpeg = extractJpegPayload(dg);
      expect(jpeg[0], 0xFF);
      expect(jpeg[1], 0xD8);
      expect(jpeg[jpeg.length - 2], 0xFF);
      expect(jpeg[jpeg.length - 1], 0xD9);
      // The JPEG is everything from offset 32 onwards.
      expect(jpeg.length, dg.length - 32);
    });

    test('fixture 02 (N=16, all-zero metadata) parses correctly', () {
      final dg = _loadFixture('mjpeg_frame_synth_02.bin');
      final jpeg = extractJpegPayload(dg);
      expect(jpeg[0], 0xFF);
      expect(jpeg[1], 0xD8);
      // SOI offset = 32 + 16 = 48.
      expect(jpeg.length, dg.length - 48);
    });

    test(
      'fixture 03 (N=32, metadata holds spurious FF D8 / FF D9) — '
      'parser must use the length field, NOT scan for markers',
      () {
        final dg = _loadFixture('mjpeg_frame_synth_03.bin');
        // Sanity-check the fixture itself: there really are decoys in
        // the metadata region. If this assertion fails, regenerate the
        // fixture with `scripts/synth_mjpeg_fixture.py`.
        expect(dg[40], 0xFF);
        expect(dg[41], 0xD8);
        expect(dg[50], 0xFF);
        expect(dg[51], 0xD9);
        // A correctly-implemented parser ignores the decoys and finds
        // SOI at 32 + 32 = 64.
        final jpeg = extractJpegPayload(dg);
        expect(jpeg.length, dg.length - 64);
        expect(jpeg[0], 0xFF);
        expect(jpeg[1], 0xD8);
        // The first JPEG marker after SOI on a baseline image written
        // by Pillow is APP0 (FF E0) carrying the JFIF identifier.
        expect(jpeg[2], 0xFF);
        expect(jpeg[3], 0xE0);
      },
    );
  });

  group('extractJpegPayload — malformed input', () {
    test('throws when the datagram is shorter than 32 bytes', () {
      final dg = Uint8List.fromList(List.filled(20, 0));
      expect(() => extractJpegPayload(dg),
          throwsA(isA<FrameDecodeException>()));
    });

    test('throws when the computed SOI offset is past the end', () {
      final dg = Uint8List(40);
      // BE-16 at offset 30 = 100; computed SOI offset 132, way past end.
      dg[30] = 0x00;
      dg[31] = 0x64;
      expect(() => extractJpegPayload(dg),
          throwsA(isA<FrameDecodeException>()));
    });

    test('throws when the computed SOI offset does not point at FF D8', () {
      final dg = Uint8List(40);
      // BE-16 at offset 30 = 0; SOI offset = 32. Put non-FF-D8 there.
      dg[30] = 0x00;
      dg[31] = 0x00;
      dg[32] = 0xAA;
      dg[33] = 0xBB;
      dg[dg.length - 2] = 0xFF;
      dg[dg.length - 1] = 0xD9;
      expect(() => extractJpegPayload(dg),
          throwsA(isA<FrameDecodeException>()));
    });

    test('throws when the trailing bytes are not FF D9', () {
      final dg = Uint8List(40);
      dg[30] = 0x00;
      dg[31] = 0x00;
      dg[32] = 0xFF;
      dg[33] = 0xD8;
      // tail intentionally NOT FF D9
      dg[dg.length - 2] = 0xAA;
      dg[dg.length - 1] = 0xBB;
      expect(() => extractJpegPayload(dg),
          throwsA(isA<FrameDecodeException>()));
    });
  });
}
