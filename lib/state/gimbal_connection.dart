import 'dart:async';

import 'package:feiyu_gimbal/feiyu_gimbal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

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

/// Thin Flutter/riverpod adapter around the framework-free
/// [GimbalSession] (in `package:feiyu_gimbal`). Owns only the
/// presentation concerns the session deliberately doesn't: the
/// `ChangeNotifier`, the timestamped [LogEntry] list, and the mapping
/// from [GimbalPhase] to a user-facing status string. All transport,
/// orientation and motion logic lives in the session.
///
/// See SPEC-flutter-app.md "Phase 3 — Gimbal motion library".
class GimbalConnection extends ChangeNotifier {
  GimbalConnection() {
    _changesSub = _session.changes.listen((_) => notifyListeners());
    _logsSub = _session.logs.listen(_onLogEvent);
  }

  final GimbalSession _session = GimbalSession();
  late final StreamSubscription<void> _changesSub;
  late final StreamSubscription<GimbalLogEvent> _logsSub;
  final List<LogEntry> _log = [];

  void _onLogEvent(GimbalLogEvent e) {
    switch (e.kind) {
      case GimbalLogKind.tx:
        _appendLog(LogEntry.tx(e.bytes!));
      case GimbalLogKind.rx:
        _appendLog(LogEntry.rx(e.bytes!));
      case GimbalLogKind.info:
        _appendLog(LogEntry.info(e.message!));
      case GimbalLogKind.error:
        _appendLog(LogEntry.error(e.message!));
    }
  }

  void _appendLog(LogEntry e) {
    _log.add(e);
    if (_log.length > _logCapacity) {
      _log.removeRange(0, _log.length - _logCapacity);
    }
    notifyListeners();
  }

  String? get connectedName => _session.connectedName;
  String? get connectedId => _session.connectedId;
  int? get mtu => _session.mtu;
  bool get connecting => _session.connecting;
  bool get isConnected => _session.isConnected;
  String get status => _statusFor(_session.phase);
  List<LogEntry> get log => List.unmodifiable(_log);

  double? get yawDeg => _session.yawDeg;
  double? get pitchDeg => _session.pitchDeg;
  double? get rollDeg => _session.rollDeg;
  int? get followMode => _session.followMode;
  DateTime? get orientationAt => _session.orientationAt;
  bool get moving => _session.moving;

  String _statusFor(GimbalPhase phase) {
    switch (phase) {
      case GimbalPhase.disconnected:
        return 'Disconnected';
      case GimbalPhase.connecting:
        return 'Connecting to ${_session.connectedName}...';
      case GimbalPhase.requestingMtu:
        return 'Requesting MTU...';
      case GimbalPhase.discovering:
        return 'Discovering services...';
      case GimbalPhase.enablingNotifications:
        return 'Enabling notifications...';
      case GimbalPhase.connected:
        return 'Connected to ${_session.connectedName}';
      case GimbalPhase.connectFailed:
        return 'Connect failed';
      case GimbalPhase.serviceNotFound:
        return 'SCORP service not found';
      case GimbalPhase.notifyFailed:
        return 'Notify subscription failed';
    }
  }

  /// Drive the transport through its lifecycle. The caller builds the
  /// transport — BleGimbalTransport for a tapped real device, or
  /// DemoGimbalTransport for the synthetic "Demo Gimbal" entry.
  Future<bool> connect(GimbalTransport transport) =>
      _session.connect(transport);

  Future<void> disconnect() => _session.disconnect();

  Future<MoveResult> moveByAngle({
    double courseDeg = 0,
    double pitchDeg = 0,
  }) =>
      _session.moveByAngle(courseDeg: courseDeg, pitchDeg: pitchDeg);

  Future<void> levelHome() => _session.levelHome();

  void clearLog() {
    _log.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _changesSub.cancel();
    _logsSub.cancel();
    _session.dispose();
    super.dispose();
  }
}

final gimbalConnectionProvider =
    ChangeNotifierProvider<GimbalConnection>((ref) => GimbalConnection());
