import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/camera/jpeg_decoder.dart';
import 'package:sciens_gimbal_controller/camera/mjpeg_udp_stream.dart';

Uint8List _loadFixture(String name) =>
    File('test/fixtures/lumix/$name').readAsBytesSync();

void main() {
  // dart:ui.instantiateImageCodec needs the test binding installed
  // even for non-widget tests.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('decodeJpeg round-trips a fixture-embedded JPEG', () async {
    final dg = _loadFixture('mjpeg_frame_synth_01.bin');
    final jpegBytes = extractJpegPayload(dg);
    final image = await decodeJpeg(Uint8List.fromList(jpegBytes));
    expect(image.width, 64);
    expect(image.height, 48);

    // The synth fixture is a two-tone image: red left, blue right.
    // Verify by reading two pixels.
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(byteData, isNotNull);
    final bytes = byteData!.buffer.asUint8List();

    int pixelAt(int x, int y) {
      final i = (y * image.width + x) * 4;
      return (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    }

    // JPEG with quality=80 isn't pixel-perfect, so we sample well
    // inside each half and assert the *dominant* channel.
    final leftPixel = pixelAt(8, 24); // expected red-ish
    final rightPixel = pixelAt(56, 24); // expected blue-ish
    expect((leftPixel >> 16) & 0xFF, greaterThan(150),
        reason: 'left half should be red-dominant; got '
            '0x${leftPixel.toRadixString(16).padLeft(6, "0")}');
    expect(rightPixel & 0xFF, greaterThan(150),
        reason: 'right half should be blue-dominant; got '
            '0x${rightPixel.toRadixString(16).padLeft(6, "0")}');

    image.dispose();
  });

  test('decodeJpeg throws on non-JPEG bytes', () async {
    final garbage = Uint8List.fromList(List.filled(64, 0x42));
    await expectLater(() => decodeJpeg(garbage), throwsA(isA<Exception>()));
  });
}
