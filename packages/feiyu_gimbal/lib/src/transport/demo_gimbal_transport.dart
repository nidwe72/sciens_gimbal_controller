import 'dart:async';
import 'dart:typed_data';

import '../frame_codec.dart';
import 'gimbal_transport.dart';

/// Software-only "Demo Gimbal" transport. Speaks the AK protocol
/// end-to-end (encodes outgoing GIMBAL_STATE frames byte-for-byte
/// like the real device, decodes incoming command frames the app
/// sends) so `GimbalConnection`, `FrameStreamDecoder`, and the
/// closed-loop motion controller run completely unchanged.
///
/// Intended uses (per SPEC-flutter-app.md Phase 1):
///  - Showcasing the app to a user without a SCORP C2.
///  - Development when the gimbal isn't in reach.
///  - Running on Android emulators that lack a BLE radio.
///
/// Behavior model: **observable parity**, not firmware fidelity. The
/// demo reproduces the *result* a user sees after the real device's
/// quirks have been worked around at the app layer — see Phase 1
/// spec "Behavior model".
class DemoGimbalTransport implements GimbalTransport {
  // --- Tuning constants (see Phase 1 spec).

  /// Lifecycle phase delay. ~100 ms × 4 phases ≈ 400 ms total — enough
  /// for the user to see each status string flick by.
  static const _phaseDelay = Duration(milliseconds: 100);

  /// GIMBAL_STATE emission cadence. Matches the real-device ~10 Hz
  /// push rate. Runs continuously while connected (idle pump).
  static const _pumpPeriod = Duration(milliseconds: 100);

  /// Speed → angular rate. Per Phase 1 spec: rate °/s = (|speed| / 60) × 8.
  /// At a 10 Hz pump cadence, per-tick delta = speed × 8 / 600.
  static const _speedToDegreesPerTick = 8.0 / 600.0;

  /// Real-device pitch overshoot in the direction of motion after a
  /// move ends. `GimbalConnection._pitchCoastCompensation` pre-subtracts
  /// this from every pitch delta expecting the gimbal to coast back to
  /// the user's intent. Reproduce so demo end-state matches user intent.
  static const _pitchCoastDeg = 1.0;

  /// MTU that `prepareLink` reports back. The wire MTU is meaningless
  /// here (we use an in-memory queue), but matching the BLE default
  /// keeps the UI's MTU readout honest.
  static const _virtualMtu = 512;

  // --- Identity. Hard-coded; surfaced as DemoRow in the connect screen.

  static const _name = 'Demo Gimbal';
  static const _id = '00:00:00:00:00:01';

  @override
  String get connectedName => _name;

  @override
  String get connectedId => _id;

  // --- State.

  /// Virtual orientation. Starts at level/home. Roll is always 0 — the
  /// demo doesn't expose a way to command roll (matches the app's
  /// pan/tilt-only controls).
  double _yawDeg = 0.0;
  double _pitchDeg = 0.0;
  final double _rollDeg = 0.0;

  /// Last received joystick speeds. Course == yaw axis.
  double _commandedCourseSpeed = 0.0;
  double _commandedPitchSpeed = 0.0;

  /// Sign of the most recent non-zero pitch speed. Used to know which
  /// way to apply the 1° coast on a non-zero → zero transition.
  int _lastPitchSign = 0;

  Timer? _pumpTimer;
  bool _opened = false;

  final _incomingCtrl = StreamController<List<int>>.broadcast();
  final _disconnectedCtrl = StreamController<void>.broadcast();

  @override
  Stream<List<int>> get incoming => _incomingCtrl.stream;

  @override
  Stream<void> get disconnected => _disconnectedCtrl.stream;

  // --- Lifecycle.

  @override
  Future<bool> openConnection() async {
    await Future<void>.delayed(_phaseDelay);
    _opened = true;
    return true;
  }

  @override
  Future<int?> prepareLink() async {
    await Future<void>.delayed(_phaseDelay);
    return _virtualMtu;
  }

  @override
  Future<bool> discoverEndpoints() async {
    await Future<void>.delayed(_phaseDelay);
    return true;
  }

  @override
  Future<bool> subscribeIncoming() async {
    await Future<void>.delayed(_phaseDelay);
    // Start the idle pump. Emits GIMBAL_STATE at ~10 Hz regardless of
    // motion — orientation freshness indicator depends on continuous
    // pushes (see Phase 1 spec "Idle pump").
    _pumpTimer = Timer.periodic(_pumpPeriod, (_) => _pumpTick());
    return true;
  }

  @override
  Future<void> disconnect() async {
    _pumpTimer?.cancel();
    _pumpTimer = null;
    _opened = false;
    if (!_incomingCtrl.isClosed) await _incomingCtrl.close();
    if (!_disconnectedCtrl.isClosed) await _disconnectedCtrl.close();
  }

  // --- Byte channel.

  @override
  Future<void> sendFrame(List<int> bytes) async {
    if (!_opened) {
      throw StateError('DemoGimbalTransport.sendFrame: not connected');
    }
    final decoded = decodeFrame(bytes);
    final frame = decoded.frame;
    if (frame == null) return; // malformed; silently drop
    _handleFrame(frame);
  }

  void _handleFrame(AkFrame frame) {
    switch (frame.cmdId) {
      case 14: // CONTROL_JOYSTICK (PROTOCOL-NOTES §6 / commands.dart)
        if (frame.payload.length >= 5) {
          final course = _signed16(frame.payload[1], frame.payload[2]);
          final pitch = _signed16(frame.payload[3], frame.payload[4]);
          _updateJoystick(course.toDouble(), pitch.toDouble());
        }
        break;
      // All other commands (SET_USE_MODE=51, TAKE_PHOTO=63,
      // ROTATE_SPECIFIED_ANGLE=93, …): silently accepted, no virtual-
      // state effect. Mirrors real-device behavior on SCORP-C2, which
      // ignores absolute-rotate, and keeps follow-mode fixed.
    }
  }

  void _updateJoystick(double course, double pitch) {
    // Pitch coast on stop: when commanded pitch transitions
    // non-zero → zero, apply a 1° impulse in the previous direction.
    // This matches the real-device overshoot the app already
    // compensates for; without it, every pitch move would land 1°
    // short of the user-intended angle.
    if (_commandedPitchSpeed != 0 && pitch == 0 && _lastPitchSign != 0) {
      _pitchDeg += _pitchCoastDeg * _lastPitchSign;
    }
    if (pitch != 0) _lastPitchSign = pitch > 0 ? 1 : -1;

    _commandedCourseSpeed = course;
    _commandedPitchSpeed = pitch;
  }

  // --- Pump.

  void _pumpTick() {
    if (_commandedCourseSpeed != 0) {
      _yawDeg += _commandedCourseSpeed * _speedToDegreesPerTick;
    }
    if (_commandedPitchSpeed != 0) {
      _pitchDeg += _commandedPitchSpeed * _speedToDegreesPerTick;
    }
    _emitState();
  }

  void _emitState() {
    // 17-byte GIMBAL_STATE payload, matching real-device size. See
    // `gimbal_connection.dart:_onFrame` for the parser layout.
    final payload = Uint8List(17);
    payload[0] = 0; // mode = PF (low 3 bits)
    _writeS16LE(payload, 1, (_pitchDeg * 100).round());
    _writeS16LE(payload, 3, (_rollDeg * 100).round());
    _writeS16LE(payload, 5, (_yawDeg * 100).round());
    // bytes [7..15] = 0 (zero-initialised)
    payload[16] = 0xFF; // no mode override; mode comes from byte [0]

    final frame = AkFrame(
      target: 0, // gimbalA — same as real device GIMBAL_STATE pushes
      cmdType: 0, // push
      cmdId: 30, // GIMBAL_STATE
      payload: payload,
    );
    if (!_incomingCtrl.isClosed) {
      _incomingCtrl.add(frame.encode());
    }
  }

  // --- Helpers.

  static void _writeS16LE(Uint8List buf, int offset, int value) {
    final v = value & 0xFFFF;
    buf[offset] = v & 0xFF;
    buf[offset + 1] = (v >> 8) & 0xFF;
  }

  static int _signed16(int low, int high) {
    final v = (low & 0xFF) | ((high & 0xFF) << 8);
    return v >= 0x8000 ? v - 0x10000 : v;
  }
}
