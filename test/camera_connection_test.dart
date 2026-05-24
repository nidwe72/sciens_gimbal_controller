import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sciens_gimbal_controller/camera/camera_connection.dart';
import 'package:sciens_gimbal_controller/camera/capture_sounds.dart';
import 'package:sciens_gimbal_controller/camera/lumix_camera.dart';

/// Counting fake — increments on each play call. Used by the PR 10
/// captureWithDelay tests to assert beep / shutter cadence.
class _CountingSounds implements CaptureSounds {
  int beepCount = 0;
  int shutterCount = 0;

  @override
  Future<void> playBeep() async {
    beepCount++;
  }

  @override
  Future<void> playShutter() async {
    shutterCount++;
  }

  @override
  Future<void> dispose() async {}
}

/// Canned camera backing a `MockClient`. Flags let a test flip it into
/// rejecting / failing states mid-session.
class _FakeCamera {
  bool failGetState = false;
  bool rejectAccctrl = false;
  bool rejectSetSetting = false;
  bool rejectCapture = false;

  /// Count of `camcmd?value=capture` requests seen by the fake.
  /// Used by the PR 10 captureWithDelay tests to assert that the
  /// underlying capture HTTP fired (or didn't, in the cancel /
  /// lifecycle-paused paths).
  int captureRequestCount = 0;

  String shutter = '1792/256';
  String iso = '400';
  String focal = '1024/256';
  String exposure = '0';

  static const _ok =
      '<?xml version="1.0"?><camrply><result>ok</result></camrply>';
  static const _err =
      '<?xml version="1.0"?><camrply><result>err_param</result></camrply>';
  static const _getstate = '<?xml version="1.0"?><camrply><result>ok</result>'
      '<state><cammode>rec</cammode><batt>3/5</batt><version>VD4.30</version>'
      '<sdcardstatus>write_enable</sdcardstatus><sd_access>off</sd_access>'
      '<remaincapacity>2438</remaincapacity></state></camrply>';
  static const _allmenu = '<?xml version="1.0"?><camrply><result>ok</result>'
      '<menuinfo>'
      '<item cmd_mode="setsetting" cmd_type="iso" cmd_value="auto"/>'
      '<item cmd_mode="setsetting" cmd_type="iso" cmd_value="400"/>'
      '</menuinfo></camrply>';
  static const _curmenu = '<?xml version="1.0"?><camrply><result>ok</result>'
      '<menuinfo>'
      '<item id="menu_item_id_recmode" enable="no" value="aperture_ae" />'
      '</menuinfo></camrply>';

  String _settingValue(String type, String value) =>
      '<?xml version="1.0"?><camrply><result>ok</result>'
      '<settingvalue $type="$value"></settingvalue></camrply>';

  Future<http.Response> handle(http.Request req) async {
    final q = req.url.queryParameters;
    switch (q['mode']) {
      case 'getstate':
        return failGetState
            ? http.Response('', 500)
            : http.Response(_getstate, 200);
      case 'accctrl':
        return http.Response(rejectAccctrl ? _err : _ok, 200);
      case 'getinfo':
        return http.Response(
            q['type'] == 'curmenu' ? _curmenu : _allmenu, 200);
      case 'getsetting':
        final type = q['type'] ?? '';
        final value = switch (type) {
          'shtrspeed' => shutter,
          'iso' => iso,
          'focal' => focal,
          'exposure' => exposure,
          _ => '0',
        };
        return http.Response(_settingValue(type, value), 200);
      case 'setsetting':
        return http.Response(rejectSetSetting ? _err : _ok, 200);
      case 'camcmd':
        if (q['value'] == 'capture') captureRequestCount++;
        final reject = q['value'] == 'capture' && rejectCapture;
        return http.Response(reject ? _err : _ok, 200);
      default:
        return http.Response(_ok, 200);
    }
  }
}

void main() {
  const wifiChannel =
      MethodChannel('at.sciens.gimbal_controller/wifi_network');

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // bind() / unbind() must succeed without a real platform.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wifiChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wifiChannel, null);
  });

  CameraConnection makeConn(
    _FakeCamera fake, {
    CaptureSounds? sounds,
    Duration pollInterval = const Duration(milliseconds: 10),
  }) =>
      CameraConnection(
        cameraFactory: () =>
            LumixCamera(httpClient: MockClient(fake.handle)),
        captureSoundsFactory: sounds == null ? null : () => sounds,
        pollInterval: pollInterval,
      );

  group('CameraConnection — connect lifecycle', () {
    test('manual-IP connect reaches Connected and caches caps', () async {
      final conn = makeConn(_FakeCamera());
      final result = await conn.connect(manualIp: '192.168.54.1');

      expect(result, isTrue);
      expect(conn.status, CameraStatus.connected);
      expect(conn.caps?.isoValues, contains('400'));

      await conn.disconnect();
      expect(conn.status, CameraStatus.disconnected);
    });

    test('a rejected accctrl fails the connect', () async {
      final conn = makeConn(_FakeCamera()..rejectAccctrl = true);
      final result = await conn.connect(manualIp: '192.168.54.1');

      expect(result, isFalse);
      expect(conn.status, CameraStatus.error);
      expect(conn.errorText, isNotNull);
    });
  });

  group('CameraConnection — polling', () {
    test('the poll populates shutter / ISO / aperture + remainCapacity',
        () async {
      final conn = makeConn(_FakeCamera());
      await conn.connect(manualIp: '192.168.54.1');
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(conn.shutterWire, '1792/256');
      expect(conn.isoWire, '400');
      expect(conn.focalWire, '1024/256');
      expect(conn.cameraState?.remainCapacity, 2438);
      expect(conn.exposureWire, '0');

      await conn.disconnect();
    });

    test('the poll reads the shooting mode from curmenu', () async {
      final conn = makeConn(_FakeCamera());
      await conn.connect(manualIp: '192.168.54.1');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(conn.recMode, 'aperture_ae');
      await conn.disconnect();
    });

    test('three consecutive getstate failures drop the connection',
        () async {
      final fake = _FakeCamera();
      final conn = makeConn(fake);
      await conn.connect(manualIp: '192.168.54.1');
      expect(conn.status, CameraStatus.connected);

      fake.failGetState = true;
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(conn.status, CameraStatus.error);
      expect(conn.errorText, contains('lost'));
    });
  });

  group('CameraConnection — settings & capture', () {
    test('applySetting: null on ok, error string on err_*', () async {
      final fake = _FakeCamera();
      final conn = makeConn(fake);
      await conn.connect(manualIp: '192.168.54.1');

      expect(await conn.applySetting('iso', '400'), isNull);

      fake.rejectSetSetting = true;
      expect(await conn.applySetting('iso', '999999'), isNotNull);

      await conn.disconnect();
    });

    test('capture: null on ok, error string on err_*', () async {
      final fake = _FakeCamera();
      final conn = makeConn(fake);
      await conn.connect(manualIp: '192.168.54.1');

      expect(await conn.capture(), isNull);

      fake.rejectCapture = true;
      expect(await conn.capture(), isNotNull);

      await conn.disconnect();
    });
  });

  group('CameraConnection — captureWithDelay (PR 10)', () {
    test('delay=0: 1 shutter, 0 beeps, overlay stays false', () async {
      final fake = _FakeCamera();
      final sounds = _CountingSounds();
      final conn = makeConn(fake, sounds: sounds);
      await conn.connect(manualIp: '192.168.54.1');

      expect(conn.overlayActive.value, isFalse);
      final err = await conn.captureWithDelay(0);

      expect(err, isNull);
      expect(sounds.shutterCount, 1);
      expect(sounds.beepCount, 0);
      // overlayActive flips true during the 500 ms min-display + the
      // capture HTTP, then back to false. After await it's false.
      expect(conn.overlayActive.value, isFalse);

      await conn.disconnect();
    });

    test('delay=5: slow + fast cadence, shutter at T=0, capture once', () {
      fakeAsync((async) {
        final fake = _FakeCamera();
        final sounds = _CountingSounds();
        // Long poll interval so the poll loop doesn't crowd the
        // timeline we're verifying.
        final conn = makeConn(fake,
            sounds: sounds, pollInterval: const Duration(hours: 1));
        conn.connect(manualIp: '192.168.54.1').ignore();
        async.elapse(const Duration(milliseconds: 50));
        expect(conn.status, CameraStatus.connected);

        conn.captureWithDelay(5).ignore();
        async.flushMicrotasks();

        // T=5: countdown started, initial slow beep, no shutter yet.
        expect(sounds.beepCount, 1);
        expect(conn.countdownSecondsLeft.value, 5);
        expect(conn.overlayActive.value, isTrue);

        // T=4 (slow), then T=3 (slow). One slow beep per second.
        async.elapse(const Duration(seconds: 1));
        expect(sounds.beepCount, 2);
        expect(conn.countdownSecondsLeft.value, 4);

        async.elapse(const Duration(seconds: 1));
        expect(sounds.beepCount, 3);
        expect(conn.countdownSecondsLeft.value, 3);

        // T=2.0 fast beep (4th total: 3 slow + 1 fast).
        async.elapse(const Duration(seconds: 1));
        expect(sounds.beepCount, 4);
        expect(conn.countdownSecondsLeft.value, 2);

        // T=1.5 fast beep.
        async.elapse(const Duration(milliseconds: 500));
        expect(sounds.beepCount, 5);

        // T=1.0 fast beep.
        async.elapse(const Duration(milliseconds: 500));
        expect(sounds.beepCount, 6);
        expect(conn.countdownSecondsLeft.value, 1);

        // T=0.5 fast beep.
        async.elapse(const Duration(milliseconds: 500));
        expect(sounds.beepCount, 7);

        // T=0 — shutter fires; countdownSecondsLeft goes null;
        // capture() is invoked.
        async.elapse(const Duration(milliseconds: 500));
        expect(sounds.shutterCount, 1);
        expect(conn.countdownSecondsLeft.value, isNull);
        expect(fake.captureRequestCount, 1);

        // After the 500 ms min-display floor, overlay flips off.
        async.elapse(const Duration(milliseconds: 600));
        expect(conn.overlayActive.value, isFalse);

        // Final beep count: 3 slow (T=5,4,3) + 4 fast (T=2,1.5,1,0.5).
        expect(sounds.beepCount, 7);
      });
    });

    test('delay=1: only 2 fast beeps + shutter (no slow phase)', () {
      fakeAsync((async) {
        final fake = _FakeCamera();
        final sounds = _CountingSounds();
        final conn = makeConn(fake,
            sounds: sounds, pollInterval: const Duration(hours: 1));
        conn.connect(manualIp: '192.168.54.1').ignore();
        async.elapse(const Duration(milliseconds: 50));

        conn.captureWithDelay(1).ignore();
        async.flushMicrotasks();

        // T=1.0 initial (fast) beep.
        expect(sounds.beepCount, 1);

        // T=0.5 fast beep.
        async.elapse(const Duration(milliseconds: 500));
        expect(sounds.beepCount, 2);

        // T=0 — shutter, capture called.
        async.elapse(const Duration(milliseconds: 500));
        expect(sounds.shutterCount, 1);
        expect(fake.captureRequestCount, 1);

        async.elapse(const Duration(milliseconds: 600));
        expect(conn.overlayActive.value, isFalse);
      });
    });

    test('cancelCountdown mid-flight: no shutter, no capture, overlay off',
        () {
      fakeAsync((async) {
        final fake = _FakeCamera();
        final sounds = _CountingSounds();
        final conn = makeConn(fake,
            sounds: sounds, pollInterval: const Duration(hours: 1));
        conn.connect(manualIp: '192.168.54.1').ignore();
        async.elapse(const Duration(milliseconds: 50));

        conn.captureWithDelay(5).ignore();
        async.flushMicrotasks();

        // Run forward 2 s (to T=3) so a couple of slow beeps fire.
        async.elapse(const Duration(seconds: 2));
        expect(sounds.beepCount, 3); // T=5,4,3
        expect(conn.countdownSecondsLeft.value, 3);

        // Cancel — overlay should dismiss immediately, no further
        // beeps, no shutter, no capture HTTP call.
        conn.cancelCountdown();
        async.flushMicrotasks();
        expect(conn.overlayActive.value, isFalse);

        // Let plenty of time pass; nothing else should fire.
        async.elapse(const Duration(seconds: 10));
        expect(sounds.beepCount, 3);
        expect(sounds.shutterCount, 0);
        expect(fake.captureRequestCount, 0);
      });
    });

    test('muted=true: 0 beeps, 0 shutter, capture still fires', () async {
      final fake = _FakeCamera();
      final sounds = _CountingSounds();
      final conn = makeConn(fake, sounds: sounds);
      conn.muted.value = true;
      await conn.connect(manualIp: '192.168.54.1');

      final err = await conn.captureWithDelay(0);

      expect(err, isNull);
      expect(sounds.shutterCount, 0);
      expect(sounds.beepCount, 0);
      expect(fake.captureRequestCount, 1);

      await conn.disconnect();
    });

    test('AppLifecycleState.paused mid-countdown aborts capture', () {
      fakeAsync((async) {
        final fake = _FakeCamera();
        final sounds = _CountingSounds();
        final conn = makeConn(fake,
            sounds: sounds, pollInterval: const Duration(hours: 1));
        conn.connect(manualIp: '192.168.54.1').ignore();
        async.elapse(const Duration(milliseconds: 50));

        conn.captureWithDelay(5).ignore();
        async.flushMicrotasks();
        expect(conn.overlayActive.value, isTrue);

        // Simulate the app going to background. CameraConnection's
        // registered lifecycle observer should fire cancelCountdown.
        WidgetsBinding.instance
            .handleAppLifecycleStateChanged(AppLifecycleState.paused);
        async.flushMicrotasks();

        expect(conn.overlayActive.value, isFalse);

        // No further activity even if more time passes.
        async.elapse(const Duration(seconds: 10));
        expect(sounds.shutterCount, 0);
        expect(fake.captureRequestCount, 0);
      });
    });
  });
}
