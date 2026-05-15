import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../ble/commands.dart';
import '../ble/frame_codec.dart';
import '../ble/transport/gimbal_transport.dart';

const _logCapacity = 500;

enum LogDirection { tx, rx, info, error }

class LogEntry {
  final DateTime time;
  final LogDirection direction;
  final List<int>? bytes;
  final String? message;

  LogEntry._(this.time, this.direction, this.bytes, this.message);

  factory LogEntry.rx(List<int> bytes) =>
      LogEntry._(DateTime.now(), LogDirection.rx, List.unmodifiable(bytes), null);
  factory LogEntry.tx(List<int> bytes) =>
      LogEntry._(DateTime.now(), LogDirection.tx, List.unmodifiable(bytes), null);
  factory LogEntry.info(String message) =>
      LogEntry._(DateTime.now(), LogDirection.info, null, message);
  factory LogEntry.error(String message) =>
      LogEntry._(DateTime.now(), LogDirection.error, null, message);
}

String formatHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

/// Wire cmdId for the periodic gimbal-state push (see PROTOCOL-NOTES §6).
const int cmdIdGimbalState = 30;

int _signed16(int low, int high) {
  final v = (low & 0xFF) | ((high & 0xFF) << 8);
  return v >= 0x8000 ? v - 0x10000 : v;
}

class GimbalConnection extends ChangeNotifier {
  GimbalConnection() {
    _decoder = FrameStreamDecoder(onFrame: _onFrame);
  }

  GimbalTransport? _transport;
  int? _mtu;
  bool _connecting = false;
  bool _ready = false;
  String _status = 'Disconnected';

  // Orientation, last GIMBAL_STATE decoded.
  double? _yawDeg;
  double? _pitchDeg;
  double? _rollDeg;
  int? _followMode;
  DateTime? _orientationAt;

  late final FrameStreamDecoder _decoder;
  final List<LogEntry> _log = [];

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
  Completer<void>? _moveCompleter;
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

  StreamSubscription<List<int>>? _incomingSub;
  StreamSubscription<void>? _disconnectedSub;

  String? get connectedName => _transport?.connectedName;
  String? get connectedId => _transport?.connectedId;
  int? get mtu => _mtu;
  bool get connecting => _connecting;
  bool get isConnected => _transport != null && _ready;
  String get status => _status;
  List<LogEntry> get log => List.unmodifiable(_log);

  double? get yawDeg => _yawDeg;
  double? get pitchDeg => _pitchDeg;
  double? get rollDeg => _rollDeg;
  int? get followMode => _followMode;
  DateTime? get orientationAt => _orientationAt;
  bool get moving => _moving;

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
      _orientationAt = DateTime.now();
      if (_moving) _checkMoveProgress();
      notifyListeners();
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
        appendLog(LogEntry.info(
            'Level done after $i pass(es): yaw=${_yawDeg!.toStringAsFixed(2)} pitch=${_pitchDeg!.toStringAsFixed(2)}'));
        return;
      }
      await moveByAngle(courseDeg: yawDelta, pitchDeg: pitchDelta);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    appendLog(LogEntry.info(
        'Level finished (max passes reached): yaw=${_yawDeg!.toStringAsFixed(2)} pitch=${_pitchDeg!.toStringAsFixed(2)}'));
  }

  static const int _levelMaxPasses = 4;
  static const double _levelTolerance = 0.5;

  /// (Speculative) Drive the gimbal to an absolute orientation using
  /// `ROTATE_SPECIFIED_ANGLE`. SCORP firmware does not support this; kept
  /// here for use with other gimbal models that do.
  Future<void> gotoAngle({double? yawDeg, double? pitchDeg}) async {
    if (!isConnected) return;
    if (yawDeg == null && pitchDeg == null) return;
    appendLog(LogEntry.info(
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
  /// closed-loop joystick speed control. Runs a primary move, then up to
  /// [_moveMaxRetries] corrective passes if the residual error exceeds
  /// [_moveTolerance]. No-op if already moving, not connected, or
  /// orientation feedback is unavailable.
  Future<void> moveByAngle({
    double courseDeg = 0,
    double pitchDeg = 0,
  }) async {
    if (_moving) return;
    if (!isConnected) return;
    if (courseDeg == 0 && pitchDeg == 0) return;
    if (_yawDeg == null || _pitchDeg == null) {
      appendLog(LogEntry.error('No orientation feedback yet, cannot move'));
      return;
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

    appendLog(LogEntry.info(
        'Move start: yaw0=${startYaw.toStringAsFixed(2)} pitch0=${startPitch.toStringAsFixed(2)} '
        'req d_course=${courseDeg.toStringAsFixed(1)} d_pitch=${pitchDeg.toStringAsFixed(1)} '
        '(eff d_pitch=${effectivePitchDelta.toStringAsFixed(1)} after coast comp) '
        'absT_yaw=${absTargetYaw.toStringAsFixed(2)} absT_pitch=${absTargetPitch.toStringAsFixed(2)}'));

    // Put the gimbal in Lock mode so its follow-mode controller doesn't
    // pull the position back toward the handle pose after we stop.
    await send(buildSetUseMode(UseMode.lock), log: false);

    for (int attempt = 0; attempt <= _moveMaxRetries; attempt++) {
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

      appendLog(LogEntry.info(
          'Pass $attempt: now yaw=${_yawDeg!.toStringAsFixed(2)} pitch=${_pitchDeg!.toStringAsFixed(2)}, '
          'driving d_yaw=${residualYaw.toStringAsFixed(2)} d_pitch=${residualPitch.toStringAsFixed(2)}'));

      await _runSinglePass(residualYaw, residualPitch);

      // Let the gimbal settle and orientation feedback catch up.
      await Future.delayed(_moveSettleDelay);
    }

    final finalYawErr = courseDeg == 0
        ? 0.0
        : _angleDiff(absTargetYaw, _yawDeg!);
    // Report err relative to the user's *requested* pitch so the log
    // reflects what the user expected, not the compensated internal
    // target.
    final userTargetPitch = startPitch + pitchDeg;
    final finalPitchErr =
        pitchDeg == 0 ? 0.0 : userTargetPitch - _pitchDeg!;
    appendLog(LogEntry.info(
        'Move done: now yaw=${_yawDeg!.toStringAsFixed(2)} pitch=${_pitchDeg!.toStringAsFixed(2)}, '
        'err yaw=${finalYawErr.toStringAsFixed(2)} pitch=${finalPitchErr.toStringAsFixed(2)}'));
  }

  /// One closed-loop pass. Returns a Future that completes when this
  /// pass finishes (arrival, timeout, or disconnect).
  Future<void> _runSinglePass(double courseDeg, double pitchDeg) {
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
      return Future.value();
    }
    _moveStartTime = DateTime.now();
    _lastCourseProgressAt = _moveStartTime;
    _lastPitchProgressAt = _moveStartTime;
    _lastProgressYaw = _yawDeg;
    _lastProgressPitch = _pitchDeg;
    _moving = true;
    _moveCompleter = Completer<void>();
    _moveTimer = Timer.periodic(_movePeriod, (_) => _onMoveTick());
    _onMoveTick();
    notifyListeners();
    return _moveCompleter!.future;
  }

  void _onMoveTick() {
    if (!_moving) return;
    if (_moveStartTime != null &&
        DateTime.now().difference(_moveStartTime!) > _moveAbsoluteTimeout) {
      appendLog(LogEntry.error('Move absolute timeout (60s), stopping'));
      _finishMove();
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
      _finishMove();
      return;
    }

    // Stall detection: update per-axis "last seen progress" each time
    // the angle moves by more than _stallThresholdDeg. If every active
    // axis has gone _stallWindow without progress, treat it as stuck.
    final now = DateTime.now();
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
      appendLog(LogEntry.error('Move stalled, stopping'));
      _finishMove();
    }
  }

  void _finishMove() {
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
    if (c != null && !c.isCompleted) c.complete();
    notifyListeners();
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

  void _setStatus(String s) {
    _status = s;
    notifyListeners();
  }

  void appendLog(LogEntry e) {
    _log.add(e);
    if (_log.length > _logCapacity) {
      _log.removeRange(0, _log.length - _logCapacity);
    }
    notifyListeners();
  }

  void clearLog() {
    _log.clear();
    notifyListeners();
  }

  /// Drive the transport through its lifecycle phases, emitting the
  /// same user-facing status strings between phases. Returns true on
  /// success. The caller (ConnectScreen) builds the appropriate
  /// transport — BleGimbalTransport for a tapped real device, or
  /// DemoGimbalTransport for the synthetic "Demo Gimbal" entry.
  Future<bool> connect(GimbalTransport transport) async {
    if (_connecting) return false;
    _connecting = true;
    _transport = transport;
    _setStatus('Connecting to ${transport.connectedName}...');

    // Subscribe to disconnected BEFORE openConnection so we don't miss
    // an early drop.
    _disconnectedSub = transport.disconnected.listen((_) {
      appendLog(LogEntry.error('Disconnected'));
      _teardown();
    });

    try {
      final opened = await transport.openConnection();
      if (!opened) {
        _setStatus('Connect failed');
        await _safeDisconnect();
        _connecting = false;
        notifyListeners();
        return false;
      }

      _setStatus('Requesting MTU...');
      _mtu = await transport.prepareLink();
      if (_mtu == null) {
        appendLog(LogEntry.error('MTU request failed (continuing)'));
      } else {
        appendLog(LogEntry.info('MTU negotiated: $_mtu'));
      }

      _setStatus('Discovering services...');
      final discovered = await transport.discoverEndpoints();
      if (!discovered) {
        _setStatus('SCORP service not found');
        appendLog(LogEntry.error(
            'SCORP service or characteristics not found on this device'));
        await _safeDisconnect();
        _connecting = false;
        notifyListeners();
        return false;
      }

      _setStatus('Enabling notifications...');
      final subscribed = await transport.subscribeIncoming();
      if (!subscribed) {
        _setStatus('Notify subscription failed');
        appendLog(LogEntry.error('Failed to subscribe to notifications'));
        await _safeDisconnect();
        _connecting = false;
        notifyListeners();
        return false;
      }

      _incomingSub = transport.incoming.listen((data) {
        appendLog(LogEntry.rx(data));
        _decoder.feed(data);
      });

      _ready = true;
      _connecting = false;
      _setStatus('Connected to ${transport.connectedName}');
      appendLog(LogEntry.info('Notifications enabled'));
      notifyListeners();
      return true;
    } catch (e) {
      appendLog(LogEntry.error('Connect failed: $e'));
      _setStatus('Connect failed');
      await _safeDisconnect();
      _connecting = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> disconnect() async {
    appendLog(LogEntry.info('User disconnect'));
    await _safeDisconnect();
  }

  /// Encode and ship a frame via the active transport. The transport
  /// throws on transport failure; we catch and log so the existing
  /// `'Write failed: $e'` UX is preserved. Pass [log] = false to
  /// suppress the TX log entry for spammy paths (joystick stream).
  Future<void> send(AkFrame frame, {bool log = true}) async {
    final t = _transport;
    if (t == null) return;
    final bytes = frame.encode();
    try {
      await t.sendFrame(bytes);
      if (log) appendLog(LogEntry.tx(bytes));
    } catch (e) {
      appendLog(LogEntry.error('Write failed: $e'));
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
    if (c != null && !c.isCompleted) c.complete();
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
    _setStatus('Disconnected');
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _disconnectedSub?.cancel();
    super.dispose();
  }
}

final gimbalConnectionProvider =
    ChangeNotifierProvider<GimbalConnection>((ref) => GimbalConnection());
