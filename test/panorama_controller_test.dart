import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/state/panorama_controller.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('defaults: idle, not running, sensible 4×4 grid', () {
    final pano = makeContainer().read(panoramaControllerProvider);
    expect(pano.state, PanoState.idle);
    expect(pano.running, isFalse);
    expect(pano.grid.nCols, 4);
    expect(pano.grid.nRows, 4);
    expect(pano.grid.canRun, isTrue);
  });

  test('updateSettings recomputes the preview grid + guard flags', () {
    final pano = makeContainer().read(panoramaControllerProvider);
    pano.updateSettings(focalTaking: 150, overlap: 0.6);
    expect(pano.grid.overCap, isTrue);
    expect(pano.grid.canRun, isFalse);
  });

  test('stitched focal is clamped to ≤ taking focal', () {
    final pano = makeContainer().read(panoramaControllerProvider);
    pano.updateSettings(focalTaking: 50, focalStitch: 90);
    expect(pano.focalStitch, lessThanOrEqualTo(pano.focalTaking));
    expect(pano.focalStitch, 50);
  });

  test('overlap is clamped to the 0.6 ceiling', () {
    final pano = makeContainer().read(panoramaControllerProvider);
    pano.updateSettings(overlap: 0.95);
    expect(pano.overlap, lessThanOrEqualTo(0.6));
  });

  test('canStart is false with no devices connected', () {
    final pano = makeContainer().read(panoramaControllerProvider);
    expect(pano.canStart, isFalse);
  });

  test('start() is a no-op when it cannot start (no devices)', () async {
    final pano = makeContainer().read(panoramaControllerProvider);
    await pano.start();
    expect(pano.state, PanoState.idle);
    expect(pano.running, isFalse);
  });

  test('cancel() before any run is a no-op', () {
    final pano = makeContainer().read(panoramaControllerProvider);
    pano.cancel();
    expect(pano.state, PanoState.idle);
  });
}
