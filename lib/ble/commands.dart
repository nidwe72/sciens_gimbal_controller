import 'dart:typed_data';

import 'frame_codec.dart';

/// Wire cmdIds from `AkProtocol.CmdId`. See PROTOCOL-NOTES.md §6.
class CmdId {
  CmdId._();
  static const int controlJoystick = 14;
  static const int gimbalState = 30;
  static const int useMode = 51;
  static const int rotateSpecifiedAngle = 93;
  static const int rotateRelativeAngle = 115;
  static const int takePhoto = 63;
}

class CmdType {
  CmdType._();
  static const int push = 0;
  static const int set = 1;
  static const int get = 2;
}

class Target {
  Target._();
  static const int gimbalA = 0;
  static const int usbHub = 9;
}

/// Axis selectors used in ROTATE_SPECIFIED_ANGLE payload (from
/// `com.feiyutech.lib.gimbal.entity.Axis`).
class GimbalAxis {
  GimbalAxis._();
  static const int course = 0; // yaw
  static const int roll = 1;
  static const int pitch = 2;
}

/// Values for `USE_MODE` (wire cmdId 51). The SCORP-C2 mapping:
///   0 PF  — pan follow
///   1 PTF — pan + tilt follow
///   2 FPV — all axes follow
///   3 LK  — all axes locked (target for our motion commands)
///   4 FFC — fast follow / flash follow
class UseMode {
  UseMode._();
  static const int panFollow = 0;
  static const int panTiltFollow = 1;
  static const int fpv = 2;
  static const int lock = 3;
  static const int fastFollow = 4;
}

void _writeS16LE(Uint8List buf, int offset, int value) {
  final v = value & 0xFFFF;
  buf[offset] = v & 0xFF;
  buf[offset + 1] = (v >> 8) & 0xFF;
}

/// Build a SET USE_MODE frame (cmdId 51, cmdType SET). [mode] is a
/// value from [UseMode]. Payload is a single byte holding the mode.
AkFrame buildSetUseMode(int mode) {
  final payload = Uint8List(1);
  payload[0] = mode & 0xFF;
  return AkFrame(
    target: Target.gimbalA,
    cmdType: CmdType.set,
    cmdId: CmdId.useMode,
    payload: payload,
  );
}

/// Build a CONTROL_JOYSTICK frame (cmdId 14, cmdType PUSH).
/// Payload: [enableRoll, course_lo, course_hi, pitch_lo, pitch_hi].
/// Course/pitch are signed 16-bit LE speeds. Stock app uses ~60–100.
AkFrame buildControlJoystick({
  required int course,
  required int pitch,
  bool enableRoll = false,
}) {
  final payload = Uint8List(5);
  payload[0] = enableRoll ? 1 : 0;
  _writeS16LE(payload, 1, course);
  _writeS16LE(payload, 3, pitch);
  return AkFrame(
    target: Target.gimbalA,
    cmdType: CmdType.push,
    cmdId: CmdId.controlJoystick,
    payload: payload,
  );
}

/// Build ROTATE_SPECIFIED_ANGLE (wire cmdId 93 / 0x5D) — absolute goto on
/// a single axis. Stock-app payload format from
/// `CameraBalanceActivityViewModel.setPitchAngle` and
/// `AutoMoveControllerImpl2`: `int[] {axis, angle * 10}` where each int
/// is packed as a signed 16-bit LE (total 4-byte payload). Angle is in
/// degrees; the *10 converts to decidegrees on the wire.
AkFrame buildSetAngle({required int axis, required double degrees}) {
  final payload = Uint8List(4);
  _writeS16LE(payload, 0, axis);
  _writeS16LE(payload, 2, (degrees * 10).round());
  return AkFrame(
    target: Target.gimbalA,
    cmdType: CmdType.set,
    cmdId: CmdId.rotateSpecifiedAngle,
    payload: payload,
  );
}
