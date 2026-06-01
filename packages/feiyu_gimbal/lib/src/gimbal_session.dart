import 'dart:async';

import 'package:clock/clock.dart';

import 'commands.dart';
import 'frame_codec.dart';
import 'transport/gimbal_transport.dart';

/// Wire cmdId for the periodic gimbal-state push (see PROTOCOL-NOTES §6).
const int cmdIdGimbalState = 30;

/// Connection lifecycle phase. The host app maps these to user-facing
/// status strings — the session owns no presentation text.
enum GimbalPhase {
  disconnected,
  connecting,
  requestingMtu,
  discovering,
  enablingNotifications,
  connected,
  connectFailed,
  serviceNotFound,
  notifyFailed,
}

/// Kind of a [GimbalLogEvent].
enum GimbalLogKind { tx, rx, info, error }

/// A structured log event emitted by [GimbalSession]. The host app folds
/// these into its own timestamped log model; the session keeps no log
/// and owns no UI strings beyond these diagnostic messages.
class GimbalLogEvent {
  final GimbalLogKind kind;
  final List<int>? bytes;
  final String? message;

  const GimbalLogEvent._(this.kind, this.bytes, this.message);

  factory GimbalLogEvent.tx(List<int> bytes) =>
      GimbalLogEvent._(GimbalLogKind.tx, List.unmodifiable(bytes), null);
  factory GimbalLogEvent.rx(List<int> bytes) =>
      GimbalLogEvent._(GimbalLogKind.rx, List.unmodifiable(bytes), null);
  factory GimbalLogEvent.info(String message) =>
      GimbalLogEvent._(GimbalLogKind.info, null, message);
  factory GimbalLogEvent.error(String message) =>
      GimbalLogEvent._(GimbalLogKind.error, null, message);
}

/// Why a [GimbalSession.moveByAngle] call ended.
enum MoveOutcome {
  /// Reached the target within tolerance.
  completed,

  /// Stopped because no active axis progressed within the stall window.
  stalled,

  /// Hit the absolute safety timeout.
  timedOut,

  /// The link dropped mid-move.
  disconnected,

  /// Nothing to do: zero requested delta, or a sub-coast pitch nudge
  /// below the compensation floor.
  skipped,

  /// Could not start: not connected, or no orientation feedback yet.
  notReady,

  /// Another move was already in progress.
  busy,
}

/// Result of a relative move. Carries the [outcome] plus the raw signed
/// residual error per axis (requested target − achieved). The session
/// bakes in no tolerance and no pass/fail flag — each caller applies its
/// own policy.
class MoveResult {
  final MoveOutcome outcome;
  final double residualYawDeg;
  final double residualPitchDeg;

  const MoveResult(this.outcome, this.residualYawDeg, this.residualPitchDeg);
}

int _signed16(int low, int high) {
  final v = (low & 0xFF) | ((high & 0xFF) << 8);
  return v >= 0x8000 ? v - 0x10000 : v;
}

/// Framework-free gimbal session: owns a [GimbalTransport], drives the
/// connect lifecycle, decodes orientation from GIMBAL_STATE pushes, and
/// runs the closed-loop relative-move controller. Emits change + log
/// events for a host adapter to surface; no Flutter, no BLE plugin.
///
/// See SPEC-flutter-app.md "Phase 3 — Gimbal motion library
/// (extraction)". All time reads go through `package:clock` so the
/// motion controller is testable under `fake_async`.
class GimbalSession {
  GimbalSession() {
    _decoder = FrameStreamDecoder(onFrame: _onFrame);
  }

  // --- Event streams consumed by the host adapter.
  final _changes = StreamController<void>.broadcast();
  final _logEvents = StreamController<GimbalLogEvent>.broadcast();

  /// Fires whenever any observable state changes (phase, orientation,
  /// move state). The adapter forwards this to `notifyListeners()`.
  Stream<void> get changes => _changes.stream;

  /// Structured protocol / diagnostic log events.
  Stream<GimbalLogEvent> get logs => _logEvents.stream;

  GimbalTransport? _transport;
  int? _mtu;
  bool _connecting = false;
  bool _ready = false;
  GimbalPhase _phase = GimbalPhase.disconnected;

  // Orientation, last GIMBAL_STATE decoded.
  double? _yawDeg;
  double? _pitchDeg;
  double? _rollDeg;
  int? _followMode;
  DateTime? _orientationAt;

  late final FrameStreamDecoder _decoder;

  // Motion (closed-loop joystick) state.
  // Speed shelves, modelled on the stock app's getRightSpeed:
  //   remaining > 10°  → fast
  //   5°..10°          → medium
  //   < 5°             → slow (gentle approach so coast is minimal)
  static const int _moveSpeedFast = 60;
  static const int _moveSpeedMed = 40;
  static const int _moveSpeedSlow = 25;
  static const Duration _movePeriod = Duration(milliseconds: 50);
  /// Coarse fallback: if even a fully frozen state stream + zero motion
  /// somehow eludes stall detection, bail after this absolute cap.
  /// Comfortably above any legitimate single-pass move.
  static const Duration _moveAbsoluteTimeout = Duration(seconds: 60);
  /// Stall detection: if neither active axis moves by more than this
  /// many degrees within [_stallWindow], we assume something's stuck
  /// (endstop, lost state pushes, …) and abort the move.
  static const double _stallThresholdDeg = 0.2;
  static const Duration _stallWindow = Duration(milliseconds: 500);
  // Arrival margin: stop this many degrees before target to compensate
  // for residual motor coast. Smaller than before since speed-tapering
  // already minimises coast.
  static const double _arrivalMarginMax = 0.8;
  static const double _arrivalMarginFrac = 0.2;
  Timer? _moveTimer;
  bool _moving = false;
  Completer<MoveOutcome>? _moveCompleter;
  double? _moveStartCourse;
  double? _moveStartPitch;
  double _moveTargetCourseDelta = 0;
  double _moveTargetPitchDelta = 0;
  // Sign of intended motion per axis: -1, 0, +1. Cleared to 0 on arrival.
  int _moveDirCourse = 0;
  int _moveDirPitch = 0;
  DateTime? _moveStartTime;
  // Stall-detection bookkeeping.
  DateTime? _lastCourseProgressAt;
  DateTime? _lastPitchProgressAt;
  double? _lastProgressYaw;
  double? _lastProgressPitch;

  // Iterative refinement settings. Retries disabled because we now
  // pre-compensate for the gimbal's consistent ~1° pitch overshoot
  // (see below) — a corrective pass would just hunt around the
  // compensated target.
  static const int _moveMaxRetries = 0;
  static const double _moveTolerance = 0.3;
  static const Duration _moveSettleDelay = Duration(milliseconds: 250);
  /// SCORP-C2 motor coast bias: every pitch move overshoots its target
  /// by ~1° (course doesn't show the same bias). Subtract this from the
  /// requested pitch magnitude so the natural coast lands at the
  /// user-intended angle.
  static const double _pitchCoastCompensation = 1.0;

  static const int _levelMaxPasses = 4;
  static const double _levelTolerance = 0.5;

  StreamSubscription<List<int>>? _incomingSub;
  StreamSubscription<void>? _disconnectedSub;

  String? get connectedName => _transport?.connectedName;
  String? get connectedId => _transport?.connectedId;
  int? get mtu => _mtu;
  bool get connecting => _connecting;
  bool get isConnected => _transport != null && _ready;
  GimbalPhase get phase => _phase;

  double? get yawDeg => _yawDeg;
  double? get pitchDeg => _pitchDeg;
  double? get rollDeg => _rollDeg;
  int? get followMode => _followMode;
  DateTime? get orientationAt => _orientationAt;
  bool get moving => _moving;

  void _emitChange() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _log(GimbalLogEvent e) {
    if (!_logEvents.isClosed) _logEvents.add(e);
  }

  void _setPhase(GimbalPhase p) {
    _phase = p;
    _emitChange();
  }

  void _onFrame(AkFrame frame) {
    if (frame.cmdId == cmdIdGimbalState && frame.payload.length >= 7) {
      _pitchDeg = _signed16(frame.payload[1], frame.payload[2]) / 100.0;
      _rollDeg = _signed16(frame.payload[3], frame.payload[4]) / 100.0;
      _yawDeg = _signed16(frame.payload[5], frame.payload[6]) / 100.0;
      // Follow mode: bits 0–2 of byte 0, optionally overridden by byte 16
      // if present and not 0xFF (see GimbalStateParser.parse).
      int mode = frame.payload[0] & 0x07;
      if (frame.payload.length > 16) {
        final override = frame.payload[16];
        if (override != 0xFF) mode = override;
      }
      _followMode = mode;
      _orientationAt = clock.now();
      if (_moving) _checkMoveProgress();
      _emitChange();
    }
  }

  /// Drive yaw and pitch back to zero ("home"). Uses [moveByAngle]
  /// (closed-loop joystick) since SCORP firmware doesn't declare
  /// rotateSpecifiedAngle support in the properties XML.
  ///
  /// Iterates up to [_levelMaxPasses] times, recomputing the residual
  /// to zero each pass. A single move overshoots at large angles
  /// because the coast compensation is tuned for ~10° moves; multiple
  /// passes converge cleanly because each subsequent pass is small.
  Future<void> levelHome() async {
    if (!isConnected) return;
    for (int i = 0; i < _levelMaxPasses; i++) {
      if (_yawDeg == null || _pitchDeg == null) return;
      final yawDelta = _angleDiff(0, _yawDeg!);
      final pitchDelta = -_pitchDeg!;
      if (yawDelta.abs() < _levelTolerance &&
          pitchDelta.abs() < _levelTolerance) {
        _log(GimbalLogEvent.info(
            'Level done after $i pass(es): yaw=${_yawDeg!.toStringAsFixed(2)} pitch=${_pitchDeg!.toStringAsFixed(2)}'));
        return;
      }
      await moveByAngle(courseDeg: yawDelta, pitchDeg: pitchDelta);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    _log(GimbalLogEvent.info(
        'Level finished (max passes reached): yaw=${_yawDeg!.toStringAsFixed(2)} pitch=${_pitchDeg!.toStringAsFixed(2)}'));
  }

  /// (Speculative) Drive the gimbal to an absolute orientation using
  /// `ROTATE_SPECIFIED_ANGLE`. SCORP firmware does not support this; kept
  /// here for use with other gimbal models that do.
  Future<void> gotoAngle({double? yawDeg, double? pitchDeg}) async {
    if (!isConnected) return;
    if (yawDeg == null && pitchDeg == null) return;
    _log(GimbalLogEvent.info(
        'Goto: yaw=${yawDeg?.toStringAsFixed(1) ?? "—"}° '
        'pitch=${pitchDeg?.toStringAsFixed(1) ?? "—"}°'));
    await send(buildSetUseMode(UseMode.lock), log: false);
    if (yawDeg != null) {
      await send(buildSetAngle(axis: GimbalAxis.course, degrees: yawDeg));
    }
    if (pitchDeg != null) {
      await send(buildSetAngle(axis: GimbalAxis.pitch, degrees: pitchDeg));
    }
  }

  /// Move the gimbal by [courseDeg] in yaw and [pitchDeg] in pitch using
  /// closed-loop joystick speed control. Returns a [MoveResult]: the
  /// outcome plus the raw signed residual error vs the *requested*
  /// target. No-op variants report `busy` / `notReady` / `skipped`.
  Future<MoveResult> moveByAngle({
    double courseDeg = 0,
    double pitchDeg = 0,
  }) async {
    if (_moving) return MoveResult(MoveOutcome.busy, courseDeg, pitchDeg);
    if (!isConnected) {
      return MoveResult(MoveOutcome.notReady, courseDeg, pitchDeg);
    }
    if (courseDeg == 0 && pitchDeg == 0) {
      return const MoveResult(MoveOutcome.skipped, 0, 0);
    }
    if (_yawDeg == null || _pitchDeg == null) {
      _log(GimbalLogEvent.error('No orientation feedback yet, cannot move'));
      return MoveResult(MoveOutcome.notReady, courseDeg, pitchDeg);
    }

    final startYaw = _yawDeg!;
    final startPitch = _pitchDeg!;

    // Pitch coast compensation: reduce pitch-delta magnitude by 1° in
    // the direction of motion so the gimbal's natural overshoot lands
    // at the requested final pitch. If the requested move is smaller
    // than the compensation, skip the move entirely.
    double effectivePitchDelta = pitchDeg;
    if (effectivePitchDelta.abs() >= _pitchCoastCompensation) {
      effectivePitchDelta -=
          _pitchCoastCompensation * effectivePitchDelta.sign;
    } else {
      effectivePitchDelta = 0;
    }

    final absTargetYaw = startYaw + courseDeg;
    final absTargetPitch = startPitch + effectivePitchDelta;

    _log(GimbalLogEvent.info(
        'Move start: yaw0=${startYaw.toStringAsFixed(2)} pitch0=${startPitch.toStringAsFixed(2)} '
        'req d_course=${courseDeg.toStringAsFixed(1)} d_pitch=${pitchDeg.toStringAsFixed(1)} '
        '(eff d_pitch=${effectivePitchDelta.toStringAsFixed(1)} after coast comp) '
        'absT_yaw=${absTargetYaw.toStringAsFixed(2)} absT_pitch=${absTargetPitch.toStringAsFixed(2)}'));

    // Put the gimbal in Lock mode so its follow-mode controller doesn't
    // pull the position back toward the handle pose after we stop.
    await send(buildSetUseMode(UseMode.lock), log: false);

    // No pass needed (already within tolerance, or coast-skipped) defaults
    // to `skipped`; an actual pass overwrites this with its outcome.
    MoveOutcome outcome = MoveOutcome.skipped;
    for (int attempt = 0; attempt <= _moveMaxRetries; attempt++) {
      if (_yawDeg == null || _pitchDeg == null) {
        outcome = MoveOutcome.disconnected;
        break;
      }
      final residualYaw = courseDeg == 0
          ? 0.0
          : _angleDiff(absTargetYaw, _yawDeg!);
      final residualPitch = effectivePitchDelta == 0
          ? 0.0
          : absTargetPitch - _pitchDeg!;

      if (residualYaw.abs() < _moveTolerance &&
          residualPitch.abs() < _moveTolerance) {
        break;
      }

      _log(GimbalLogEvent.info(
          'Pass $attempt: now yaw=${_yawDeg!.toStringAsFixed(2)} pitch=${_pitchDeg!.toStringAsFixed(2)}, '
          'driving d_yaw=${residualYaw.toStringAsFixed(2)} d_pitch=${residualPitch.toStringAsFixed(2)}'));

      outcome = await _runSinglePass(residualYaw, residualPitch);
      if (outcome == MoveOutcome.disconnected) break;

      // Let the gimbal settle and orientation feedback catch up.
      await Future<void>.delayed(_moveSettleDelay);
    }

    // Residual relative to the user's *requested* target (not the
    // coast-compensated internal one), so it reflects what the user
    // expected. Guard nulls: a mid-move disconnect clears orientation.
    final double residualYawErr;
    final double residualPitchErr;
    if (_yawDeg == null || _pitchDeg == null) {
      residualYawErr = courseDeg;
      residualPitchErr = pitchDeg;
      outcome = MoveOutcome.disconnected;
    } else {
      residualYawErr =
          courseDeg == 0 ? 0.0 : _angleDiff(absTargetYaw, _yawDeg!);
      final userTargetPitch = startPitch + pitchDeg;
      residualPitchErr = pitchDeg == 0 ? 0.0 : userTargetPitch - _pitchDeg!;
      _log(GimbalLogEvent.info(
          'Move done: now yaw=${_yawDeg!.toStringAsFixed(2)} pitch=${_pitchDeg!.toStringAsFixed(2)}, '
          'err yaw=${residualYawErr.toStringAsFixed(2)} pitch=${residualPitchErr.toStringAsFixed(2)} '
          'outcome=${outcome.name}'));
    }

    return MoveResult(outcome, residualYawErr, residualPitchErr);
  }

  /// One closed-loop pass. Completes with the [MoveOutcome] for this pass
  /// (arrival, stall, timeout, or disconnect).
  Future<MoveOutcome> _runSinglePass(double courseDeg, double pitchDeg) {
    _moveStartCourse = _yawDeg;
    _moveStartPitch = _pitchDeg;
    _moveTargetCourseDelta = courseDeg;
    _moveTargetPitchDelta = pitchDeg;
    _moveDirCourse = courseDeg.abs() < _moveTolerance
        ? 0
        : (courseDeg > 0 ? 1 : -1);
    _moveDirPitch = pitchDeg.abs() < _moveTolerance
        ? 0
        : (pitchDeg > 0 ? 1 : -1);
    if (_moveDirCourse == 0 && _moveDirPitch == 0) {
      return Future.value(MoveOutcome.completed);
    }
    _moveStartTime = clock.now();
    _lastCourseProgressAt = _moveStartTime;
    _lastPitchProgressAt = _moveStartTime;
    _lastProgressYaw = _yawDeg;
    _lastProgressPitch = _pitchDeg;
    _moving = true;
    _moveCompleter = Completer<MoveOutcome>();
    _moveTimer = Timer.periodic(_movePeriod, (_) => _onMoveTick());
    _onMoveTick();
    _emitChange();
    return _moveCompleter!.future;
  }

  void _onMoveTick() {
    if (!_moving) return;
    if (_moveStartTime != null &&
        clock.now().difference(_moveStartTime!) > _moveAbsoluteTimeout) {
      _log(GimbalLogEvent.error('Move absolute timeout (60s), stopping'));
      _finishMove(MoveOutcome.timedOut);
      return;
    }
    final speedCourse = _taperedSpeed(
      dir: _moveDirCourse,
      currentDelta: _yawDeg != null && _moveStartCourse != null
          ? _angleDiff(_yawDeg!, _moveStartCourse!)
          : 0,
      targetDelta: _moveTargetCourseDelta,
    );
    final speedPitch = _taperedSpeed(
      dir: _moveDirPitch,
      currentDelta: _pitchDeg != null && _moveStartPitch != null
          ? _pitchDeg! - _moveStartPitch!
          : 0,
      targetDelta: _moveTargetPitchDelta,
    );
    send(
      buildControlJoystick(course: speedCourse, pitch: speedPitch),
      log: false,
    );
  }

  /// Signed joystick speed for one axis based on remaining distance.
  /// Returns 0 if the axis has already arrived (dir == 0).
  static int _taperedSpeed({
    required int dir,
    required double currentDelta,
    required double targetDelta,
  }) {
    if (dir == 0) return 0;
    final remaining = (targetDelta - currentDelta).abs();
    final magnitude = remaining > 10.0
        ? _moveSpeedFast
        : (remaining > 5.0 ? _moveSpeedMed : _moveSpeedSlow);
    return magnitude * dir;
  }

  void _checkMoveProgress() {
    final courseDelta = _angleDiff(_yawDeg!, _moveStartCourse!);
    final pitchDelta = _pitchDeg! - _moveStartPitch!;

    final courseMargin = (_moveTargetCourseDelta.abs() * _arrivalMarginFrac)
        .clamp(0.0, _arrivalMarginMax);
    final pitchMargin = (_moveTargetPitchDelta.abs() * _arrivalMarginFrac)
        .clamp(0.0, _arrivalMarginMax);

    if (_moveDirCourse > 0 &&
        courseDelta >= _moveTargetCourseDelta - courseMargin) {
      _moveDirCourse = 0;
    } else if (_moveDirCourse < 0 &&
        courseDelta <= _moveTargetCourseDelta + courseMargin) {
      _moveDirCourse = 0;
    }
    if (_moveDirPitch > 0 &&
        pitchDelta >= _moveTargetPitchDelta - pitchMargin) {
      _moveDirPitch = 0;
    } else if (_moveDirPitch < 0 &&
        pitchDelta <= _moveTargetPitchDelta + pitchMargin) {
      _moveDirPitch = 0;
    }

    if (_moveDirCourse == 0 && _moveDirPitch == 0) {
      _finishMove(MoveOutcome.completed);
      return;
    }

    // Stall detection: update per-axis "last seen progress" each time
    // the angle moves by more than _stallThresholdDeg. If every active
    // axis has gone _stallWindow without progress, treat it as stuck.
    final now = clock.now();
    if (_moveDirCourse != 0 && _lastProgressYaw != null) {
      if ((_yawDeg! - _lastProgressYaw!).abs() > _stallThresholdDeg) {
        _lastCourseProgressAt = now;
        _lastProgressYaw = _yawDeg;
      }
    }
    if (_moveDirPitch != 0 && _lastProgressPitch != null) {
      if ((_pitchDeg! - _lastProgressPitch!).abs() > _stallThresholdDeg) {
        _lastPitchProgressAt = now;
        _lastProgressPitch = _pitchDeg;
      }
    }
    final courseActive = _moveDirCourse != 0;
    final pitchActive = _moveDirPitch != 0;
    final courseStalled = courseActive &&
        _lastCourseProgressAt != null &&
        now.difference(_lastCourseProgressAt!) > _stallWindow;
    final pitchStalled = pitchActive &&
        _lastPitchProgressAt != null &&
        now.difference(_lastPitchProgressAt!) > _stallWindow;
    if ((courseActive || pitchActive) &&
        (!courseActive || courseStalled) &&
        (!pitchActive || pitchStalled)) {
      _log(GimbalLogEvent.error('Move stalled, stopping'));
      _finishMove(MoveOutcome.stalled);
    }
  }

  void _finishMove(MoveOutcome outcome) {
    _moveTimer?.cancel();
    _moveTimer = null;
    _moving = false;
    _moveStartCourse = null;
    _moveStartPitch = null;
    _moveDirCourse = 0;
    _moveDirPitch = 0;
    _lastCourseProgressAt = null;
    _lastPitchProgressAt = null;
    _lastProgressYaw = null;
    _lastProgressPitch = null;
    // Send one final zero-speed to make sure the gimbal stops.
    send(buildControlJoystick(course: 0, pitch: 0), log: false);
    final c = _moveCompleter;
    _moveCompleter = null;
    if (c != null && !c.isCompleted) c.complete(outcome);
    _emitChange();
  }

  /// Shortest signed angular distance from b to a, handling wraparound.
  static double _angleDiff(double a, double b) {
    double d = a - b;
    while (d > 180) {
      d -= 360;
    }
    while (d < -180) {
      d += 360;
    }
    return d;
  }

  /// Drive the transport through its lifecycle phases, emitting a
  /// [GimbalPhase] before each. Returns true on success. The caller
  /// builds the appropriate transport — a BLE transport for a real
  /// device, or a demo transport for the synthetic gimbal.
  Future<bool> connect(GimbalTransport transport) async {
    if (_connecting) return false;
    _connecting = true;
    _transport = transport;
    _setPhase(GimbalPhase.connecting);

    // Subscribe to disconnected BEFORE openConnection so we don't miss
    // an early drop.
    _disconnectedSub = transport.disconnected.listen((_) {
      _log(GimbalLogEvent.error('Disconnected'));
      _teardown();
    });

    try {
      final opened = await transport.openConnection();
      if (!opened) {
        _setPhase(GimbalPhase.connectFailed);
        await _safeDisconnect();
        _connecting = false;
        _emitChange();
        return false;
      }

      _setPhase(GimbalPhase.requestingMtu);
      _mtu = await transport.prepareLink();
      if (_mtu == null) {
        _log(GimbalLogEvent.error('MTU request failed (continuing)'));
      } else {
        _log(GimbalLogEvent.info('MTU negotiated: $_mtu'));
      }

      _setPhase(GimbalPhase.discovering);
      final discovered = await transport.discoverEndpoints();
      if (!discovered) {
        _setPhase(GimbalPhase.serviceNotFound);
        _log(GimbalLogEvent.error(
            'SCORP service or characteristics not found on this device'));
        await _safeDisconnect();
        _connecting = false;
        _emitChange();
        return false;
      }

      _setPhase(GimbalPhase.enablingNotifications);
      final subscribed = await transport.subscribeIncoming();
      if (!subscribed) {
        _setPhase(GimbalPhase.notifyFailed);
        _log(GimbalLogEvent.error('Failed to subscribe to notifications'));
        await _safeDisconnect();
        _connecting = false;
        _emitChange();
        return false;
      }

      _incomingSub = transport.incoming.listen((data) {
        _log(GimbalLogEvent.rx(data));
        _decoder.feed(data);
      });

      _ready = true;
      _connecting = false;
      _setPhase(GimbalPhase.connected);
      _log(GimbalLogEvent.info('Notifications enabled'));
      _emitChange();
      return true;
    } catch (e) {
      _log(GimbalLogEvent.error('Connect failed: $e'));
      _setPhase(GimbalPhase.connectFailed);
      await _safeDisconnect();
      _connecting = false;
      _emitChange();
      return false;
    }
  }

  Future<void> disconnect() async {
    _log(GimbalLogEvent.info('User disconnect'));
    await _safeDisconnect();
  }

  /// Encode and ship a frame via the active transport. The transport
  /// throws on transport failure; we catch and emit an error log event
  /// so the existing `'Write failed: $e'` UX is preserved. Pass
  /// [log] = false to suppress the TX log event for spammy paths
  /// (the joystick stream).
  Future<void> send(AkFrame frame, {bool log = true}) async {
    final t = _transport;
    if (t == null) return;
    final bytes = frame.encode();
    try {
      await t.sendFrame(bytes);
      if (log) _log(GimbalLogEvent.tx(bytes));
    } catch (e) {
      _log(GimbalLogEvent.error('Write failed: $e'));
    }
  }

  Future<void> _safeDisconnect() async {
    try {
      await _transport?.disconnect();
    } catch (_) {}
    _teardown();
  }

  void _teardown() {
    _moveTimer?.cancel();
    _moveTimer = null;
    _moving = false;
    _moveStartCourse = null;
    _moveStartPitch = null;
    _moveDirCourse = 0;
    _moveDirPitch = 0;
    _lastCourseProgressAt = null;
    _lastPitchProgressAt = null;
    _lastProgressYaw = null;
    _lastProgressPitch = null;
    final c = _moveCompleter;
    _moveCompleter = null;
    if (c != null && !c.isCompleted) c.complete(MoveOutcome.disconnected);
    _incomingSub?.cancel();
    _incomingSub = null;
    _disconnectedSub?.cancel();
    _disconnectedSub = null;
    _transport = null;
    _ready = false;
    _mtu = null;
    _yawDeg = null;
    _pitchDeg = null;
    _rollDeg = null;
    _followMode = null;
    _orientationAt = null;
    _setPhase(GimbalPhase.disconnected);
  }

  /// Release stream controllers. Call when the owning adapter is
  /// disposed. Idempotent.
  void dispose() {
    _incomingSub?.cancel();
    _disconnectedSub?.cancel();
    _moveTimer?.cancel();
    _changes.close();
    _logEvents.close();
  }
}
