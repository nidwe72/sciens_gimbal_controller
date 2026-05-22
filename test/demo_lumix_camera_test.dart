import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/camera/demo_lumix_camera.dart';
import 'package:sciens_gimbal_controller/camera/lumix_content.dart';
import 'package:sciens_gimbal_controller/camera/lumix_protocol.dart';

/// PR 9 Step 7 — the Demo Lumix S5's "retain the traffic" guarantee.
///
/// Every wire format the demo emits is round-tripped here through the
/// **real** parsers (`lumix_protocol.dart` + `lumix_content.dart`).
/// If a parser would accept the demo's output, `CameraConnection` and
/// `LumixContent` accept it too — that is exactly the seam that lets
/// the rest of the app run unchanged against the simulator.
void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  group('DemoLumixCamera — connect-time responses', () {
    test('accCtrl returns a CSV ok the real isResultOk accepts', () async {
      final cam = DemoLumixCamera();
      final body = await cam.accCtrl();
      expect(isResultOk(body), isTrue);
      expect(body, startsWith('ok_'));
      await cam.disconnect();
    });

    test('recMode + getInfoAllMenu parse cleanly', () async {
      final cam = DemoLumixCamera();
      expect(isResultOk(await cam.recMode()), isTrue);

      final caps = parseAllMenu(await cam.getInfoAllMenu());
      expect(caps, isNotNull);
      expect(caps!.isoValues, contains('auto'));
      expect(caps.isoValues, contains('400'));
      // Sorted by evThirds: most-negative first, most-positive last.
      expect(evThirds(caps.exposureValues.first), lessThan(0));
      expect(evThirds(caps.exposureValues.last), greaterThan(0));
      // Shutter list ships from the protocol's hardcoded defaults.
      expect(caps.shutterValues, equals(defaultShutterValues));
      await cam.disconnect();
    });
  });

  group('DemoLumixCamera — poll', () {
    test('getState reflects the virtual battery + capacity', () async {
      final cam = DemoLumixCamera()..batteryBars = 3;
      final state = parseGetState(await cam.getState());
      expect(state, isNotNull);
      expect(state!.cammode, 'rec');
      expect(state.battery, '3/5');
      expect(batteryBars(state.battery), 3);
      expect(state.remainCapacity, isNotNull);
      expect(state.remainCapacity!, greaterThan(0));
      expect(state.sdAccess, isFalse);
      await cam.disconnect();
    });

    test('getSetting returns parseable values for every polled type',
        () async {
      final cam = DemoLumixCamera();
      for (final type in const ['shtrspeed', 'iso', 'focal', 'exposure']) {
        final body = await cam.getSetting(type);
        expect(parseGetSetting(body, type), isNotNull,
            reason: 'parseGetSetting failed for type=$type');
      }
      await cam.disconnect();
    });

    test('rawGet curmenu carries the current dial mode', () async {
      final cam = DemoLumixCamera();
      const q = {'mode': 'getinfo', 'type': 'curmenu'};
      expect(parseRecmode(await cam.rawGet(q)), 'program_ae');

      cam.dialMode = 'aperture_ae';
      expect(parseRecmode(await cam.rawGet(q)), 'aperture_ae');
      await cam.disconnect();
    });
  });

  group('DemoLumixCamera — controls + capture', () {
    test('setSetting persists; getSetting echoes it back', () async {
      final cam = DemoLumixCamera();
      expect(isResultOk(await cam.setSetting('iso', '1600')), isTrue);
      expect(parseGetSetting(await cam.getSetting('iso'), 'iso'), '1600');

      expect(isResultOk(await cam.setSetting('shtrspeed', '2048/256')),
          isTrue);
      expect(
          parseGetSetting(
              await cam.getSetting('shtrspeed'), 'shtrspeed'),
          '2048/256');
      await cam.disconnect();
    });

    test('capture decrements remainCapacity', () async {
      final cam = DemoLumixCamera();
      final before = parseGetState(await cam.getState())!.remainCapacity!;
      expect(isResultOk(await cam.capture()), isTrue);
      final after = parseGetState(await cam.getState())!.remainCapacity!;
      expect(after, before - 1);
      await cam.disconnect();
    });
  });

  group('DemoLumixCamera — image pipeline', () {
    test('ssdpProbe -> descriptor -> Browse round-trip', () async {
      final cam = DemoLumixCamera();
      await cam.capture();
      await cam.capture();

      final replies = await cam.ssdpProbe();
      expect(replies, isNotEmpty);
      final loc = extractSsdpLocation(replies.first);
      expect(loc, isNotNull);

      final cd = findContentDirectory(await cam.rawGetUrl(loc!), loc);
      expect(cd, isNotNull);
      expect(cd!.serviceType, contains('ContentDirectory'));

      final body = browseSoapEnvelope(cd.serviceType, '0', 0, 10);
      final r = parseBrowseResult(await cam.soapPost(
          cd.controlUrl, '${cd.serviceType}#Browse', body));
      expect(r.totalMatches, 2);
      expect(r.items.length, 2);
      expect(r.items.first.mediumUrl, contains('.JPG'));
      expect(r.items.first.fullUrl, contains('.JPG'));
      await cam.disconnect();
    });

    test('LumixContent.fetchLatest returns the most recent shot', () async {
      final cam = DemoLumixCamera();
      await cam.capture();
      await cam.capture();
      await cam.capture();
      final content = LumixContent(cam);
      final item = await content.fetchLatest();
      expect(item, isNotNull);
      expect(item!.id, '3');
      expect(item.mediumUrl, isNotNull);
      expect(item.fullUrl, isNotNull);
      await cam.disconnect();
    });

    test('rawGetBytes serves a real JPEG from the bundled asset',
        () async {
      final cam = DemoLumixCamera();
      final bytes = await cam.rawGetBytes('any-url');
      expect(bytes, isNotEmpty);
      // JPEG SOI marker (0xFF 0xD8).
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8);
      await cam.disconnect();
    });
  });

  group('DemoLumixCamera — live preview', () {
    test('startStream emits alternating frames at ~5 Hz', () async {
      final cam = DemoLumixCamera();
      expect(isResultOk(await cam.startStream(49199)), isTrue);

      final frames = <Uint8List>[];
      final sub = cam.previewFrames.listen(frames.add);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await sub.cancel();
      await cam.stopStream();

      // ~3-4 ticks in 700 ms.
      expect(frames.length, greaterThanOrEqualTo(2));
      // At least two distinct frame variants — the A/B flicker.
      expect(frames.toSet().length, greaterThanOrEqualTo(2));

      await cam.disconnect();
    });
  });
}
