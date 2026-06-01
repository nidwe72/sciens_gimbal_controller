import 'package:fake_async/fake_async.dart';
import 'package:feiyu_gimbal/feiyu_gimbal.dart';
import 'package:test/test.dart';

void main() {
  group('GimbalSession — move guards (no hardware, no time)', () {
    test('moveByAngle while disconnected → notReady, full residual', () async {
      final s = GimbalSession();
      final r = await s.moveByAngle(courseDeg: 10, pitchDeg: -4);
      expect(r.outcome, MoveOutcome.notReady);
      expect(r.residualYawDeg, 10);
      expect(r.residualPitchDeg, -4);
      s.dispose();
    });
  });

  group('GimbalSession — connect lifecycle', () {
    test('drives phases to connected and populates orientation', () {
      fakeAsync((async) {
        final s = GimbalSession();
        final phases = <GimbalPhase>[];
        s.changes.listen((_) => phases.add(s.phase));

        bool? ok;
        s.connect(DemoGimbalTransport()).then((v) => ok = v);
        async.elapse(const Duration(milliseconds: 600));

        expect(ok, true);
        expect(s.isConnected, true);
        expect(s.phase, GimbalPhase.connected);
        expect(s.connectedName, 'Demo Gimbal');
        // Phase progression observed in order.
        expect(
          phases,
          containsAllInOrder(<GimbalPhase>[
            GimbalPhase.connecting,
            GimbalPhase.requestingMtu,
            GimbalPhase.discovering,
            GimbalPhase.enablingNotifications,
            GimbalPhase.connected,
          ]),
        );
        // First GIMBAL_STATE push decoded → orientation available at ~0°.
        expect(s.yawDeg, isNotNull);
        expect(s.pitchDeg, isNotNull);
        expect(s.yawDeg, closeTo(0.0, 0.05));

        _shutdown(s, async);
      });
    });
  });

  group('GimbalSession — moveByAngle outcomes', () {
    test('zero delta on a connected session → skipped', () {
      fakeAsync((async) {
        final s = _connected(async);
        MoveResult? r;
        s.moveByAngle().then((v) => r = v);
        async.flushMicrotasks();
        expect(r!.outcome, MoveOutcome.skipped);
        expect(r!.residualYawDeg, 0);
        expect(r!.residualPitchDeg, 0);
        _shutdown(s, async);
      });
    });

    test('sub-coast pitch nudge (<1°) → skipped, residual = request', () {
      fakeAsync((async) {
        final s = _connected(async);
        MoveResult? r;
        s.moveByAngle(pitchDeg: 0.5).then((v) => r = v);
        async.elapse(const Duration(milliseconds: 100));
        expect(r!.outcome, MoveOutcome.skipped);
        // The move never happened, so the residual is the full request.
        expect(r!.residualPitchDeg, closeTo(0.5, 0.05));
        _shutdown(s, async);
      });
    });

    test('a real course move completes and lands within margin', () {
      fakeAsync((async) {
        final s = _connected(async);
        MoveResult? r;
        s.moveByAngle(courseDeg: 5).then((v) => r = v);
        async.elapse(const Duration(seconds: 6));

        expect(r, isNotNull);
        expect(r!.outcome, MoveOutcome.completed);
        // Closed-loop stops ~one arrival-margin short; residual is small.
        expect(r!.residualYawDeg.abs(), lessThan(1.5));
        // The gimbal actually moved most of the way.
        expect(s.yawDeg!, greaterThan(3.0));
        expect(s.moving, false);
        _shutdown(s, async);
      });
    });

    test('a second move while one is running → busy', () {
      fakeAsync((async) {
        final s = _connected(async);
        s.moveByAngle(courseDeg: 20); // start, not awaited
        async.elapse(const Duration(milliseconds: 300)); // underway
        expect(s.moving, true);

        MoveResult? busy;
        s.moveByAngle(courseDeg: 5).then((v) => busy = v);
        async.flushMicrotasks();
        expect(busy!.outcome, MoveOutcome.busy);

        async.elapse(const Duration(seconds: 8)); // let the first finish
        _shutdown(s, async);
      });
    });

    test('disconnect mid-move → disconnected outcome', () {
      fakeAsync((async) {
        final s = _connected(async);
        MoveResult? r;
        s.moveByAngle(courseDeg: 30).then((v) => r = v);
        async.elapse(const Duration(milliseconds: 300)); // underway
        expect(s.moving, true);

        s.disconnect();
        async.elapse(const Duration(milliseconds: 50));

        expect(r, isNotNull);
        expect(r!.outcome, MoveOutcome.disconnected);
        expect(s.isConnected, false);
        s.dispose();
      });
    });
  });

  group('GimbalSession — log events', () {
    test('emits tx/info events the adapter can fold into a log', () {
      fakeAsync((async) {
        final s = GimbalSession();
        final kinds = <GimbalLogKind>{};
        s.logs.listen((e) => kinds.add(e.kind));
        s.connect(DemoGimbalTransport());
        async.elapse(const Duration(milliseconds: 600));
        s.moveByAngle(courseDeg: 5);
        async.elapse(const Duration(seconds: 6));

        // rx from incoming pushes, info from connect + move logging.
        expect(kinds, contains(GimbalLogKind.rx));
        expect(kinds, contains(GimbalLogKind.info));
        _shutdown(s, async);
      });
    });
  });
}

// --- Helpers.

/// A connected session, driven through the demo lifecycle + first push.
GimbalSession _connected(FakeAsync async) {
  final s = GimbalSession();
  s.connect(DemoGimbalTransport());
  async.elapse(const Duration(milliseconds: 600));
  return s;
}

/// Disconnect, drain timers, and dispose so fakeAsync sees no pending
/// periodic work.
void _shutdown(GimbalSession s, FakeAsync async) {
  s.disconnect();
  async.flushMicrotasks();
  async.elapse(const Duration(milliseconds: 20));
  s.dispose();
}
