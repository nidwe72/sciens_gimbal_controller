import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'lumix_camera.dart';
import 'lumix_protocol.dart';

/// Connection-state machine for the Panasonic Lumix camera. Mirrors
/// the gimbal-side `GimbalConnection` shape: a `ChangeNotifier`
/// exposed via Riverpod, with a small state enum and human-readable
/// status text the UI shows.
///
/// PR 3 scope: lifecycle only — Disconnected → Discovering → Registering
/// → LoadingCaps → Connected, plus the polite-goodbye disconnect
/// sequence. The polling loop, setting writes, and capture all land
/// in PR 4.
enum CameraStatus {
  disconnected,
  discovering,
  registering,
  loadingCaps,
  connected,
  error,
}

class CameraConnection extends ChangeNotifier {
  CameraConnection();

  LumixCamera? _camera;
  CameraStatus _status = CameraStatus.disconnected;
  String _statusText = 'Disconnected';
  String? _errorText;
  AllMenu? _caps;

  CameraStatus get status => _status;
  String get statusText => _statusText;
  String? get errorText => _errorText;

  /// Body-reported capabilities (allowed shutter / ISO lists). Null
  /// until `getinfo?type=allmenu` is parsed during connect.
  AllMenu? get caps => _caps;

  bool get isConnected => _status == CameraStatus.connected;
  bool get isConnecting =>
      _status == CameraStatus.discovering ||
      _status == CameraStatus.registering ||
      _status == CameraStatus.loadingCaps;

  /// IP we ended up talking to (real or manual). Useful for the UI's
  /// connection-summary line.
  String? get cameraIp => _camera?.cameraIp;

  /// Connect lifecycle (per SPEC Phase 2 "Connect-time and
  /// disconnect-time orderings"):
  ///   1. bind()                  — WiFi + multicast lock
  ///   2. Discovery               — SSDP || 192.168.54.1 probe, OR
  ///                                useManualIp if [manualIp] given
  ///   3. accctrl                 — register app
  ///   4. recmode                 — claim record mode
  ///   5. getinfo?type=allmenu    — cache supported settings
  ///   6. → Connected
  ///
  /// Returns true on success. On any failure, the connection is torn
  /// down via [_failTo] and the method returns false; [errorText] is
  /// set so the UI can display it.
  Future<bool> connect({String? manualIp}) async {
    if (_status != CameraStatus.disconnected && _status != CameraStatus.error) {
      return false;
    }
    _errorText = null;
    final camera = LumixCamera();
    _camera = camera;

    try {
      // 1. bind().
      _setStatus(CameraStatus.discovering, 'Acquiring WiFi network...');
      await camera.bind();

      // 2. Discovery.
      String? ip;
      if (manualIp != null && manualIp.isNotEmpty) {
        _setStatus(CameraStatus.discovering, 'Probing $manualIp...');
        final ok = await camera.useManualIp(manualIp);
        if (!ok) {
          await _failTo('Camera not reachable at $manualIp');
          return false;
        }
        ip = manualIp;
      } else {
        _setStatus(CameraStatus.discovering, 'Searching for camera...');
        ip = await camera.discover();
        if (ip == null) {
          await _failTo('No camera found. '
              'Check the camera is in Smartphone WiFi mode and your '
              'phone is joined to the LUMIX-… network.');
          return false;
        }
      }

      // 3. accctrl.
      _setStatus(CameraStatus.registering,
          'Registering with camera at $ip (confirm on body if prompted)...');
      final accBody = await camera.accCtrl();
      if (!isResultOk(accBody)) {
        await _failTo('Camera rejected registration: ${resultText(accBody)}');
        return false;
      }

      // 3a. Pre-recmode prelude required by newer Lumix bodies (S5II /
      // S5IIX / S5D and recent S5). Without this, recmode returns
      // err_reject. Matches the libgphoto2 sequence.
      _setStatus(CameraStatus.registering, 'Initialising session...');

      // getstate just to confirm we're talking to the camera; we don't
      // care about the body here. Errors at this step ARE fatal because
      // they mean the camera isn't responding.
      await camera.getState();

      // Affirm our display name via setsetting. Some bodies need this
      // even though accctrl already received value2=<display name>.
      // Non-fatal: continue regardless of result so older bodies that
      // don't support setsetting?type=device_name still progress.
      try {
        await camera.setSetting('device_name', appDisplayName);
      } catch (_) {
        // Ignore — proceed to recmode and let it decide.
      }

      // 4. recmode.
      _setStatus(CameraStatus.registering, 'Claiming record mode...');
      final recBody = await camera.recMode();
      if (!isResultOk(recBody)) {
        await _failTo('Camera rejected recmode: ${resultText(recBody)}');
        return false;
      }

      // 5. getinfo?type=allmenu.
      _setStatus(CameraStatus.loadingCaps, 'Reading supported settings...');
      final allMenuBody = await camera.getInfoAllMenu();
      _caps = parseAllMenu(allMenuBody);
      // We accept null caps for now — the real S5 schema may need
      // parser refinement, but PR 3 still gets to Connected without
      // populated dropdowns. PR 4 will tighten this.

      // 6. Connected.
      _setStatus(CameraStatus.connected, 'Connected to camera at $ip');
      return true;
    } on LumixException catch (e) {
      await _failTo(e.message);
      return false;
    } catch (e) {
      await _failTo('Unexpected error: $e');
      return false;
    }
  }

  /// Disconnect: polite-goodbye sequence via the transport, plus
  /// state-machine reset.
  Future<void> disconnect() async {
    final camera = _camera;
    if (camera != null) {
      try {
        await camera.disconnect(streaming: false);
      } catch (_) {
        // Best effort — we're tearing down.
      }
    }
    _camera = null;
    _caps = null;
    _setStatus(CameraStatus.disconnected, 'Disconnected');
  }

  /// Tear down + record the error text + set state = error. Used by
  /// the connect path on any failure.
  Future<void> _failTo(String message) async {
    final camera = _camera;
    if (camera != null) {
      try {
        await camera.disconnect(streaming: false);
      } catch (_) {}
    }
    _camera = null;
    _caps = null;
    _errorText = message;
    _setStatus(CameraStatus.error, 'Disconnected');
  }

  void _setStatus(CameraStatus s, String text) {
    _status = s;
    _statusText = text;
    notifyListeners();
  }

  @override
  void dispose() {
    _camera?.disconnect(streaming: false);
    super.dispose();
  }
}

final cameraConnectionProvider =
    ChangeNotifierProvider<CameraConnection>((ref) => CameraConnection());
