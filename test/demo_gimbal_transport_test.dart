import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sciens_gimbal_controller/ble/commands.dart';
import 'package:sciens_gimbal_controller/ble/frame_codec.dart';
import 'package:sciens_gimbal_controller/ble/transport/demo_gimbal_transport.dart';

void main() {
  group('DemoGimbalTransport — identity & lifecycle', () {
    test('identity getters are fixed and BLE-shaped', () {
      final t = DemoGimbalTransport();
      expect(t.connectedName, 'Demo Gimbal');
      expect(t.connectedId, '00:00:00:00:00:01');
    });

    test('lifecycle phases all succeed and prepareLink reports MTU=512',
        () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        bool? open, discovered, subscribed;
        int? mtu;
        () async {
          open = await t.openConnection();
          mtu = await t.prepareLink();
          discovered = await t.discoverEndpoints();
          subscribed = await t.subscribeIncoming();
        }();
        async.elapse(const Duration(milliseconds: 500));

        expect(open, true);
        expect(mtu, 512);
        expect(discovered, true);
        expect(subscribed, true);

        _cleanShutdown(t, async);
      });
    });

    test('sendFrame before openConnection throws StateError', () {
      final t = DemoGimbalTransport();
      expect(() => t.sendFrame([0x00]), throwsA(isA<StateError>()));
    });
  });

  group('DemoGimbalTransport — GIMBAL_STATE emission', () {
    test('emits 17-byte GIMBAL_STATE with parser-compatible layout', () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        t.incoming.listen(emitted.add);

        _connect(t);
        // Lifecycle ~400 ms then first pump tick at +100 ms.
        async.elapse(const Duration(milliseconds: 550));

        expect(emitted, isNotEmpty);
        final decoded = decodeFrame(emitted.first);
        expect(decoded.error, isNull);
        final frame = decoded.frame!;

        // cmdId 30 = GIMBAL_STATE (commands.dart / gimbal_connection.dart).
        expect(frame.cmdId, 30);
        // cmdType 0 = push.
        expect(frame.cmdType, 0);
        // 17-byte payload per Phase 1 spec.
        expect(frame.payload.length, 17);
        // Mode in byte [0] low 3 bits = 0 (PF).
        expect(frame.payload[0] & 0x07, 0);
        // pitch / roll / yaw all zero at connect time.
        expect(_s16(frame.payload, 1), 0);
        expect(_s16(frame.payload, 3), 0);
        expect(_s16(frame.payload, 5), 0);
        // Bytes [7..15] are zero filler.
        for (int i = 7; i <= 15; i++) {
          expect(frame.payload[i], 0, reason: 'byte $i should be 0');
        }
        // Mode override sentinel.
        expect(frame.payload[16], 0xFF);

        _cleanShutdown(t, async);
      });
    });

    test('idle pump emits at ~10 Hz regardless of motion', () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        t.incoming.listen(emitted.add);

        _connect(t);
        async.elapse(const Duration(milliseconds: 400)); // through lifecycle
        emitted.clear();
        async.elapse(const Duration(milliseconds: 1050)); // 10+ ticks
        // 10 ticks expected from t=500..1450; allow small tolerance.
        expect(emitted.length, inInclusiveRange(9, 11));

        _cleanShutdown(t, async);
      });
    });
  });

  group('DemoGimbalTransport — motion integration', () {
    test('course speed 60 advances yaw at ~8 °/s', () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        t.incoming.listen(emitted.add);

        () async {
          await t.openConnection();
          await t.prepareLink();
          await t.discoverEndpoints();
          await t.subscribeIncoming();
          await t.sendFrame(
            buildControlJoystick(course: 60, pitch: 0).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 950)); // 5 pump ticks

        // 5 ticks × 0.8 °/tick = 4.0°.
        expect(_lastYaw(emitted), closeTo(4.0, 0.4));
        // Pitch should not have moved.
        expect(_lastPitch(emitted), closeTo(0.0, 0.05));

        _cleanShutdown(t, async);
      });
    });

    test('course speed 25 advances yaw at the slow-shelf rate (~3.3 °/s)',
        () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        t.incoming.listen(emitted.add);

        () async {
          await t.openConnection();
          await t.prepareLink();
          await t.discoverEndpoints();
          await t.subscribeIncoming();
          await t.sendFrame(
            buildControlJoystick(course: 25, pitch: 0).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 950)); // 5 ticks

        // 5 ticks × 25/75 °/tick ≈ 1.67°.
        expect(_lastYaw(emitted), closeTo(1.67, 0.3));

        _cleanShutdown(t, async);
      });
    });

    test('negative pitch speed moves pitch the other way', () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        t.incoming.listen(emitted.add);

        () async {
          await t.openConnection();
          await t.prepareLink();
          await t.discoverEndpoints();
          await t.subscribeIncoming();
          await t.sendFrame(
            buildControlJoystick(course: 0, pitch: -60).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 950));

        expect(_lastPitch(emitted), lessThan(-2.0));
        expect(_lastYaw(emitted), closeTo(0.0, 0.05));

        _cleanShutdown(t, async);
      });
    });
  });

  group('DemoGimbalTransport — pitch coast on stop', () {
    test('applies +1° impulse when pitch transitions non-zero → 0', () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        t.incoming.listen(emitted.add);

        _connect(t);
        async.elapse(const Duration(milliseconds: 400)); // lifecycle done

        // Drive pitch with speed +60 for ~250 ms (2 ticks → ~1.6°).
        () async {
          await t.sendFrame(
            buildControlJoystick(course: 0, pitch: 60).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 250));
        final pitchInMotion = _lastPitch(emitted);
        expect(pitchInMotion, closeTo(1.6, 0.2));

        // Stop pitch → coast adds exactly 1°. Coast is applied
        // synchronously in _updateJoystick, before the next pump tick.
        () async {
          await t.sendFrame(
            buildControlJoystick(course: 0, pitch: 0).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 110)); // one more tick
        final pitchAfterCoast = _lastPitch(emitted);

        expect(pitchAfterCoast - pitchInMotion, closeTo(1.0, 0.05));

        _cleanShutdown(t, async);
      });
    });

    test('applies −1° impulse when negative pitch transitions to 0', () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        t.incoming.listen(emitted.add);

        _connect(t);
        async.elapse(const Duration(milliseconds: 400));

        () async {
          await t.sendFrame(
            buildControlJoystick(course: 0, pitch: -60).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 250));
        final pitchInMotion = _lastPitch(emitted);

        () async {
          await t.sendFrame(
            buildControlJoystick(course: 0, pitch: 0).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 110));
        final pitchAfterCoast = _lastPitch(emitted);

        expect(pitchAfterCoast - pitchInMotion, closeTo(-1.0, 0.05));

        _cleanShutdown(t, async);
      });
    });

    test('no coast when pitch was never non-zero', () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        t.incoming.listen(emitted.add);

        () async {
          await t.openConnection();
          await t.prepareLink();
          await t.discoverEndpoints();
          await t.subscribeIncoming();
          // Course-only motion, then stop.
          await t.sendFrame(
            buildControlJoystick(course: 60, pitch: 0).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 250));

        () async {
          await t.sendFrame(
            buildControlJoystick(course: 0, pitch: 0).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 250));

        expect(_lastPitch(emitted), closeTo(0.0, 0.05));

        _cleanShutdown(t, async);
      });
    });

    test('course (yaw) axis has NO coast on stop', () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        t.incoming.listen(emitted.add);

        _connect(t);
        async.elapse(const Duration(milliseconds: 400));

        () async {
          await t.sendFrame(
            buildControlJoystick(course: 60, pitch: 0).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 250));
        final yawInMotion = _lastYaw(emitted);

        () async {
          await t.sendFrame(
            buildControlJoystick(course: 0, pitch: 0).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 200));

        // Yaw must not jump (no coast on this axis).
        expect(_lastYaw(emitted) - yawInMotion, closeTo(0.0, 0.05));

        _cleanShutdown(t, async);
      });
    });
  });

  group('DemoGimbalTransport — other commands', () {
    test('SET_USE_MODE and ROTATE_SPECIFIED_ANGLE are silently accepted',
        () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        t.incoming.listen(emitted.add);

        () async {
          await t.openConnection();
          await t.prepareLink();
          await t.discoverEndpoints();
          await t.subscribeIncoming();
          await t.sendFrame(buildSetUseMode(UseMode.lock).encode());
          await t.sendFrame(
            buildSetAngle(axis: GimbalAxis.pitch, degrees: 45).encode(),
          );
          await t.sendFrame(
            buildSetAngle(axis: GimbalAxis.course, degrees: 90).encode(),
          );
        }();
        async.elapse(const Duration(milliseconds: 600));

        // No state change — orientation still (0, 0, 0).
        expect(_lastYaw(emitted), closeTo(0.0, 0.05));
        expect(_lastPitch(emitted), closeTo(0.0, 0.05));

        _cleanShutdown(t, async);
      });
    });
  });

  group('DemoGimbalTransport — disconnect', () {
    test('stops the pump and closes the incoming stream', () {
      fakeAsync((async) {
        final t = DemoGimbalTransport();
        final emitted = <List<int>>[];
        bool incomingDone = false;
        t.incoming.listen(emitted.add, onDone: () => incomingDone = true);

        _connect(t);
        async.elapse(const Duration(milliseconds: 500));
        final countBeforeDisconnect = emitted.length;
        expect(countBeforeDisconnect, greaterThan(0));

        t.disconnect();
        async.flushMicrotasks();
        // Drain anything close() schedules.
        async.elapse(const Duration(milliseconds: 50));

        expect(incomingDone, true);

        async.elapse(const Duration(milliseconds: 500));
        expect(emitted.length, countBeforeDisconnect,
            reason: 'no new frames after disconnect');
      });
    });
  });
}

// --- Test helpers.

/// Kick off the full connect sequence in fakeAsync. Caller must
/// `async.elapse` to drive it through; ≥400 ms covers the full
/// lifecycle.
void _connect(DemoGimbalTransport t) {
  () async {
    await t.openConnection();
    await t.prepareLink();
    await t.discoverEndpoints();
    await t.subscribeIncoming();
  }();
}

/// Disconnect + drain timers so fakeAsync doesn't complain about
/// pending periodic work.
void _cleanShutdown(DemoGimbalTransport t, FakeAsync async) {
  t.disconnect();
  async.flushMicrotasks();
  async.elapse(const Duration(milliseconds: 10));
}

/// Read pitch (degrees) from a GIMBAL_STATE payload.
double _lastPitch(List<List<int>> emitted) =>
    _s16(decodeFrame(emitted.last).frame!.payload, 1) / 100.0;

/// Read yaw (degrees) from a GIMBAL_STATE payload.
double _lastYaw(List<List<int>> emitted) =>
    _s16(decodeFrame(emitted.last).frame!.payload, 5) / 100.0;

/// Read a signed 16-bit little-endian integer at `offset`.
int _s16(List<int> bytes, int offset) {
  final v = (bytes[offset] & 0xFF) | ((bytes[offset + 1] & 0xFF) << 8);
  return v >= 0x8000 ? v - 0x10000 : v;
}
