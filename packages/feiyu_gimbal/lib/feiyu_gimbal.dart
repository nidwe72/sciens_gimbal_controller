/// Feiyu SCORP gimbal protocol + transport library.
///
/// Framework-free: depends only on `dart:*`. Concrete transports that
/// need platform plugins (e.g. BLE via `flutter_blue_plus`) live in the
/// host app and implement [GimbalTransport]. The pure-Dart
/// [DemoGimbalTransport] ships here for hardware-free runs and tests.
///
/// See SPEC-flutter-app.md "Phase 3 — Gimbal motion library
/// (extraction)".
library;

export 'src/crc.dart';
export 'src/frame_codec.dart';
export 'src/commands.dart';
export 'src/gimbal_session.dart';
export 'src/transport/gimbal_transport.dart';
export 'src/transport/demo_gimbal_transport.dart';
