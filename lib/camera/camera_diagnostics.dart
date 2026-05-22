import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'camera_connection.dart';
import 'lumix_protocol.dart';

/// One captured camera response — or the error that replaced it.
///
/// Snapshots are **transient and in-memory**: they live only for the
/// app session and are served, never persisted. See SPEC Phase 2,
/// *Pre-PR 5 — In-app diagnostics wizard*.
class DiagnosticSnapshot {
  DiagnosticSnapshot({
    required this.step,
    required this.name,
    required this.request,
    required this.timestamp,
    this.body,
    this.error,
  });

  /// Wizard step (0-based) that produced this snapshot.
  final int step;

  /// Short identifier — also the HTTP path the server exposes it at.
  final String name;

  /// The `cam.cgi` query that produced it, for the manifest.
  final String request;

  final DateTime timestamp;

  /// Raw response body, or null when the request failed.
  final String? body;

  /// Failure message, or null on success.
  final String? error;

  bool get ok => error == null;
}

/// Drives the in-app diagnostics wizard: runs guided capture steps
/// against the live camera, holds the resulting snapshots in memory,
/// and serves them over an in-app HTTP server (advertised via mDNS)
/// so the dev machine can retrieve them without a cable.
class CameraDiagnostics extends ChangeNotifier {
  CameraDiagnostics(this._ref);

  final Ref _ref;

  /// HTTP-server port and the last wizard step index.
  static const int kPort = 8080;
  static const int kLastStep = 7;

  static const MethodChannel _nsdChannel =
      MethodChannel('at.sciens.gimbal_controller/nsd');

  /// Same channel `LumixCamera` uses. `unbind` is idempotent — the
  /// server calls it defensively so a stale process-to-network
  /// binding (camera left without a clean Disconnect) can't fail the
  /// HTTP bind.
  static const MethodChannel _wifiChannel =
      MethodChannel('at.sciens.gimbal_controller/wifi_network');

  final List<DiagnosticSnapshot> _snapshots = [];
  int _currentStep = 0;
  bool _running = false;

  HttpServer? _server;
  int _serverPort = kPort;
  String? _serverUrl;
  String? _serverError;
  bool _mdnsRegistered = false;

  // --- Public state.

  List<DiagnosticSnapshot> get snapshots => List.unmodifiable(_snapshots);

  List<DiagnosticSnapshot> snapshotsForStep(int step) =>
      _snapshots.where((s) => s.step == step).toList(growable: false);

  int get currentStep => _currentStep;

  /// True while a capture step is in flight (one runs at a time).
  bool get isRunning => _running;

  bool get serverRunning => _server != null;

  /// `http://<ip>:<port>` once the server is up, else null.
  String? get serverUrl => _serverUrl;

  /// Last server start/stop failure, cleared on next start.
  String? get serverError => _serverError;

  /// True iff the mDNS advert was accepted by the platform.
  bool get mdnsRegistered => _mdnsRegistered;

  // --- Wizard navigation.

  void goToStep(int step) {
    if (step < 0 || step > kLastStep || step == _currentStep) return;
    _currentStep = step;
    notifyListeners();
  }

  void clearSnapshots() {
    _snapshots.clear();
    notifyListeners();
  }

  // --- View lifecycle.

  /// Called when the diagnostics view is disposed (Playground exit) —
  /// stops the HTTP server so no socket is orphaned. The Lumix
  /// session is kept alive by `CameraConnection`'s polling loop; the
  /// diagnostics tool no longer runs its own keep-alive.
  void detachView() {
    stopServer();
  }

  // --- Capture steps.

  /// Step 1 — passive baseline batch.
  Future<void> runBaseline() => _runStep(() async {
        await _capture(0, 'getstate', {'mode': 'getstate'});
        await _capture(
            0, 'getsetting_shtrspeed', {'mode': 'getsetting', 'type': 'shtrspeed'});
        await _capture(
            0, 'getsetting_iso', {'mode': 'getsetting', 'type': 'iso'});
        await _capture(
            0, 'getsetting_focal', {'mode': 'getsetting', 'type': 'focal'});
        await _capture(0, 'getsetting_exposure',
            {'mode': 'getsetting', 'type': 'exposure'});
        await _capture(0, 'getsetting_recmode',
            {'mode': 'getsetting', 'type': 'recmode'});
        await _capture(
            0, 'getinfo_allmenu', {'mode': 'getinfo', 'type': 'allmenu'});
        await _capture(
            0, 'getinfo_curmenu', {'mode': 'getinfo', 'type': 'curmenu'});
        await _capture(
            0, 'getsetting_lens', {'mode': 'getsetting', 'type': 'lens'});
      });

  /// Step 2 — busy-field hunt. Sets a 4 s shutter (`-512/256` →
  /// `pow(2, 2)` s) so the busy window is wide enough to catch at
  /// ~300 ms sampling, then watches `getstate` and fires a capture
  /// at a known offset inside the window.
  Future<void> runBusyWatch() => _runStep(() async {
        await _capture(1, 'busy_set_shutter',
            {'mode': 'setsetting', 'type': 'shtrspeed', 'value': '-512/256'});
        const interval = Duration(milliseconds: 300);
        const total = Duration(seconds: 15);
        final start = DateTime.now();
        var i = 0;
        var fired = false;
        while (DateTime.now().difference(start) < total) {
          await _capture(1, 'watch_getstate_${i.toString().padLeft(3, '0')}',
              {'mode': 'getstate'});
          i++;
          if (!fired &&
              DateTime.now().difference(start) >= const Duration(seconds: 3)) {
            fired = true;
            await _capture(
                1, 'busy_capture', {'mode': 'camcmd', 'value': 'capture'});
          }
          await Future<void>.delayed(interval);
        }
      });

  /// Step 3 — `setsetting` round-trip: set a known value, read it
  /// back, for shutter / ISO / aperture.
  Future<void> runRoundTrip() => _runStep(() async {
        await _capture(2, 'rt_set_shtrspeed',
            {'mode': 'setsetting', 'type': 'shtrspeed', 'value': '1792/256'});
        await _capture(2, 'rt_get_shtrspeed',
            {'mode': 'getsetting', 'type': 'shtrspeed'});
        await _capture(2, 'rt_set_iso',
            {'mode': 'setsetting', 'type': 'iso', 'value': '400'});
        await _capture(
            2, 'rt_get_iso', {'mode': 'getsetting', 'type': 'iso'});
        await _capture(2, 'rt_set_focal',
            {'mode': 'setsetting', 'type': 'focal', 'value': '1024/256'});
        await _capture(
            2, 'rt_get_focal', {'mode': 'getsetting', 'type': 'focal'});
      });

  /// Step 4 — deliberately invalid `setsetting` calls, to capture the
  /// exact `err_*` strings.
  Future<void> runInvalidSet() => _runStep(() async {
        await _capture(3, 'invalid_shtrspeed',
            {'mode': 'setsetting', 'type': 'shtrspeed', 'value': '99999/256'});
        await _capture(3, 'invalid_iso',
            {'mode': 'setsetting', 'type': 'iso', 'value': '999999'});
        await _capture(3, 'invalid_type',
            {'mode': 'setsetting', 'type': 'sciens_bogus', 'value': 'x'});
      });

  /// Step 5 — mode-dependent rejection. [dial] is the dial position
  /// the user has set on the body (`A` or `S`); the app cannot read
  /// it, so it trusts the caller.
  Future<void> runModeRejection(String dial) => _runStep(() async {
        final d = dial.toLowerCase();
        await _capture(4, 'moderej_${d}_shtrspeed',
            {'mode': 'setsetting', 'type': 'shtrspeed', 'value': '1792/256'});
        await _capture(4, 'moderej_${d}_focal',
            {'mode': 'setsetting', 'type': 'focal', 'value': '1024/256'});
      });

  /// Step 6 — shutter sweep. Sets every entry in [defaultShutterValues]
  /// in turn and reads each back, yielding a definitive accepted /
  /// rejected table for the hardcoded list. Run with the dial on M.
  /// Restores a 1/125 s shutter at the end so the body isn't left in
  /// Bulb.
  Future<void> runShutterSweep() => _runStep(() async {
        for (final wire in defaultShutterValues) {
          final tag = wire.replaceAll('/', '_');
          await _capture(5, 'sweep_set_$tag',
              {'mode': 'setsetting', 'type': 'shtrspeed', 'value': wire});
          await _capture(5, 'sweep_get_$tag',
              {'mode': 'getsetting', 'type': 'shtrspeed'});
        }
        await _capture(5, 'sweep_restore',
            {'mode': 'setsetting', 'type': 'shtrspeed', 'value': '1792/256'});
      });

  /// Step 7 — aperture sweep. Sets every entry in [defaultApertureValues]
  /// in turn and reads each back; confirms the f-stop wire encoding and
  /// which stops the mounted lens accepts (out-of-range stops `err_*` —
  /// that is the point). Run with the dial on A or M. Restores f/4.
  Future<void> runApertureSweep() => _runStep(() async {
        for (final wire in defaultApertureValues) {
          final tag = wire.replaceAll('/', '_');
          await _capture(6, 'apsweep_set_$tag',
              {'mode': 'setsetting', 'type': 'focal', 'value': wire});
          await _capture(6, 'apsweep_get_$tag',
              {'mode': 'getsetting', 'type': 'focal'});
        }
        await _capture(6, 'apsweep_restore',
            {'mode': 'setsetting', 'type': 'focal', 'value': '1024/256'});
      });

  Future<void> _runStep(Future<void> Function() body) async {
    if (_running) return;
    _running = true;
    notifyListeners();
    try {
      await body();
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _capture(
      int step, String name, Map<String, String> query) async {
    final conn = _ref.read(cameraConnectionProvider);
    final ts = DateTime.now();
    final reqStr = query.entries.map((e) => '${e.key}=${e.value}').join('&');
    try {
      final body = await conn.diagnosticRawGet(query);
      _snapshots.add(DiagnosticSnapshot(
          step: step, name: name, request: reqStr, timestamp: ts, body: body));
    } catch (e) {
      _snapshots.add(DiagnosticSnapshot(
          step: step,
          name: name,
          request: reqStr,
          timestamp: ts,
          error: e.toString()));
    }
    notifyListeners();
  }

  // --- HTTP server + mDNS.

  Future<void> startServer() async {
    if (_server != null) return;
    _serverError = null;
    notifyListeners();

    // The camera connection pins the whole process to the camera's
    // WiFi via bindProcessToNetwork. Once the phone has left that
    // network, every socket bind fails with "Machine is not on the
    // network" (ENONET) until the process is unpinned. unbind() is
    // idempotent, and by the time the user exports the capture phase
    // is over — so call it unconditionally before binding. (The app's
    // `isConnected` can't be trusted here: with no polling loop yet,
    // it stays true after the WiFi is switched out from under it.)
    try {
      await _wifiChannel.invokeMethod<void>('unbind');
    } catch (_) {}

    // 8080 is a popular port — it may be taken by another app or a
    // stale socket from a hot restart. Try a small range.
    HttpServer? server;
    Object? lastError;
    for (var port = kPort; port < kPort + 10; port++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, port);
        _serverPort = port;
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (server == null) {
      _serverUrl = null;
      _serverError = 'Could not bind the server on ports '
          '$kPort–${kPort + 9}.\n$lastError';
      notifyListeners();
      return;
    }

    _server = server;
    server.listen(
      _handleRequest,
      onError: (Object _) => _onServerLost(),
      onDone: _onServerLost,
      cancelOnError: false,
    );
    final ip = await _wlanIpv4();
    _serverUrl = 'http://${ip ?? '<phone-ip>'}:$_serverPort';
    await _registerMdns();
    notifyListeners();
  }

  Future<void> stopServer() async {
    await _unregisterMdns();
    final server = _server;
    _server = null;
    _serverUrl = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
    notifyListeners();
  }

  void _onServerLost() {
    if (_server == null) return;
    _server = null;
    _serverUrl = null;
    _serverError = 'Server stopped — the network may have changed.';
    _unregisterMdns();
    notifyListeners();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final res = request.response;
    try {
      final path = request.uri.path;
      if (path == '/' || path.isEmpty) {
        res.headers.contentType = ContentType.html;
        res.write(_indexHtml());
      } else if (path == '/all.json') {
        res.headers.contentType = ContentType.json;
        res.write(_allJson());
      } else {
        final name = Uri.decodeComponent(path.substring(1));
        final snap = _snapshotByName(name);
        if (snap == null) {
          res.statusCode = HttpStatus.notFound;
          res.headers.contentType = ContentType.text;
          res.write('No capture named "$name".');
        } else {
          res.headers.contentType =
              ContentType('text', 'xml', charset: 'utf-8');
          res.write(snap.body ?? '(request failed: ${snap.error})');
        }
      }
    } catch (_) {
      // Never let a handler error take the server down.
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  DiagnosticSnapshot? _snapshotByName(String name) {
    for (var i = _snapshots.length - 1; i >= 0; i--) {
      if (_snapshots[i].name == name) return _snapshots[i];
    }
    return null;
  }

  String _indexHtml() {
    final rows = _snapshots
        .map((s) => '<li><a href="/${Uri.encodeComponent(s.name)}">'
            '${s.name}</a> — ${s.ok ? 'ok' : 'ERROR'}, '
            '${s.timestamp.toIso8601String()}</li>')
        .join('\n');
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<title>Sciens diagnostics</title></head><body>'
        '<h1>Sciens camera diagnostics</h1>'
        '<p>${_snapshots.length} captures &middot; '
        '<a href="/all.json">download all.json</a></p>'
        '<ul>\n$rows\n</ul></body></html>';
  }

  String _allJson() => const JsonEncoder.withIndent('  ').convert({
        'generatedAt': DateTime.now().toIso8601String(),
        'count': _snapshots.length,
        'captures': [
          for (final s in _snapshots)
            {
              'step': s.step,
              'name': s.name,
              'request': s.request,
              'timestamp': s.timestamp.toIso8601String(),
              if (s.body != null) 'body': s.body,
              if (s.error != null) 'error': s.error,
            },
        ],
      });

  Future<String?> _wlanIpv4() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // Prefer an interface that looks like WiFi.
      for (final iface in ifaces) {
        final n = iface.name.toLowerCase();
        if ((n.contains('wlan') || n.contains('wifi')) &&
            iface.addresses.isNotEmpty) {
          return iface.addresses.first.address;
        }
      }
      // Fallback: first non-loopback IPv4.
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _registerMdns() async {
    try {
      await _nsdChannel.invokeMethod<void>('register', <String, dynamic>{
        'name': 'sciens-diag',
        'type': '_http._tcp',
        'port': _serverPort,
      });
      _mdnsRegistered = true;
    } catch (_) {
      // Non-fatal — the on-screen IP is the fallback.
      _mdnsRegistered = false;
    }
  }

  Future<void> _unregisterMdns() async {
    if (!_mdnsRegistered) return;
    _mdnsRegistered = false;
    try {
      await _nsdChannel.invokeMethod<void>('unregister');
    } catch (_) {}
  }

  @override
  void dispose() {
    _unregisterMdns();
    _server?.close(force: true);
    _server = null;
    super.dispose();
  }
}

final cameraDiagnosticsProvider =
    ChangeNotifierProvider<CameraDiagnostics>((ref) => CameraDiagnostics(ref));
