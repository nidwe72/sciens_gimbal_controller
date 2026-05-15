import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// A row in the Connect screen device list. Either a real BLE device
/// from a scan, or the synthetic "Demo Gimbal" entry that wires up the
/// in-memory simulator. See SPEC-flutter-app.md Phase 1 "Device-list
/// abstraction".
///
/// Sealed so the tap handler in ConnectScreen can switch-exhaustively
/// over the two cases when picking a transport.
sealed class DeviceRow {
  String get displayName;
  String get subtitle;
  String get rssiText;
  bool get isDemo;
}

class ScannedRow extends DeviceRow {
  ScannedRow(this.scan);
  final ScanResult scan;

  @override
  String get displayName => scan.device.platformName.isNotEmpty
      ? scan.device.platformName
      : '(no name)';

  @override
  String get subtitle => scan.device.remoteId.toString();

  @override
  String get rssiText => '${scan.rssi} dBm';

  @override
  bool get isDemo => false;

  /// Rough SCORP detection from the advertised name. Used by the UI to
  /// highlight likely-compatible devices.
  bool get looksLikeScorp => displayName.startsWith('FY_SCORP_');
}

class DemoRow extends DeviceRow {
  @override
  String get displayName => 'Demo Gimbal';

  @override
  String get subtitle => '00:00:00:00:00:01';

  @override
  String get rssiText => '—';

  @override
  bool get isDemo => true;
}
