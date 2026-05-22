import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'jpeg_decoder.dart';
import 'lumix_camera.dart';
import 'lumix_protocol.dart';
import 'mjpeg_udp_stream.dart';

/// Connection-state machine for the Panasonic Lumix camera. Mirrors
/// the gimbal-side `GimbalConnection` shape: a `ChangeNotifier`
/// exposed via Riverpod, with a small state enum and human-readable
/// status text the UI shows.
///
/// Owns the connect lifecycle, the live-preview pipeline, and (PR 5)
/// the always-on 1 Hz polling loop that feeds the controls and keeps
/// the Lumix session alive.
enum CameraStatus {
  disconnected,
  discovering,
  registering,
  loadingCaps,
  connected,
  error,
}

class CameraConnection extends ChangeNotifier {
  CameraConnection({
    LumixCamera Function()? cameraFactory,
    Duration pollInterval = const Duration(seconds: 1),
  })  : _cameraFactory = cameraFactory ?? LumixCamera.new,
        _pollInterval = pollInterval;

  /// Builds the transport for each connect attempt. Injectable so
  /// `camera_connection_test.dart` can supply a `LumixCamera` wired to
  /// a mock `http.Client`.
  final LumixCamera Function() _cameraFactory;

  /// Gap between poll cycles — overridable so tests run fast.
  final Duration _pollInterval;

  LumixCamera? _camera;
  CameraStatus _status = CameraStatus.disconnected;
  String _statusText = 'Disconnected';
  String? _errorText;
  AllMenu? _caps;

  // Live-preview state (PR 4).
  MjpegUdpStream? _previewStream;
  StreamSubscription<Uint8List>? _previewSub;
  bool _previewActive = false;
  bool _previewPaused = false;
  String? _previewError;
  final _previewImage = ValueNotifier<ui.Image?>(null);

  // Polling state (PR 5). A self-rescheduling 1 Hz loop runs while
  // connected; it carries the session keep-alive (replacing PR 4's
  // preview-only heartbeat) and feeds the controls.
  bool _polling = false;
  int _pollFailCount = 0;
  int _pollCycle = 0;
  CameraState? _cameraState;
  String? _shutterWire;
  String? _isoWire;
  String? _focalWire;
  String? _exposureWire;
  String? _recMode;

  CameraStatus get status => _status;
  String get statusText => _statusText;
  String? get errorText => _errorText;

  /// Body-reported capabilities (allowed shutter / ISO lists). Null
  /// until `getinfo?type=allmenu` is parsed during connect.
  AllMenu? get caps => _caps;

  /// True iff a live preview stream is currently active.
  bool get previewActive => _previewActive;

  /// Last error from a live-preview start or running stream. Cleared
  /// on next successful start.
  String? get previewError => _previewError;

  /// Latest decoded frame from the live-preview stream. Widgets
  /// should subscribe to this ValueListenable directly (e.g. via
  /// `ValueListenableBuilder`) rather than rebuilding the whole tab
  /// on each frame — frames arrive at ~5 fps by default.
  ValueListenable<ui.Image?> get previewImage => _previewImage;

  bool get isConnected => _status == CameraStatus.connected;
  bool get isConnecting =>
      _status == CameraStatus.discovering ||
      _status == CameraStatus.registering ||
      _status == CameraStatus.loadingCaps;

  /// IP we ended up talking to (real or manual). Useful for the UI's
  /// connection-summary line.
  String? get cameraIp => _camera?.cameraIp;

  /// Latest parsed `getstate` from the 1 Hz poll, or null before the
  /// first cycle completes.
  CameraState? get cameraState => _cameraState;

  /// True while the camera is writing to the card (`<sd_access>on`).
  bool get isBusy => _cameraState?.sdAccess ?? false;

  /// Latest polled wire values for shutter / ISO / aperture, null
  /// until the first poll reads them.
  String? get shutterWire => _shutterWire;
  String? get isoWire => _isoWire;
  String? get focalWire => _focalWire;
  String? get exposureWire => _exposureWire;

  /// Raw camera shooting mode (`shutter_ae`, `aperture_ae`, …), read
  /// from `curmenu` every ~5 s. Null until the first read.
  String? get recMode => _recMode;

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
    final camera = _cameraFactory();
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
      _startPolling();
      return true;
    } on LumixException catch (e) {
      await _failTo(e.message);
      return false;
    } catch (e) {
      await _failTo('Unexpected error: $e');
      return false;
    }
  }

  /// Start MJPEG live preview. Sends `startstream`, opens a UDP
  /// listener on [udpPort], and starts publishing decoded frames
  /// via [previewImage]. Returns true on success.
  ///
  /// Safe to call from a UI handler — failures set [previewError]
  /// and return false, the caller is expected to surface that to
  /// the user (typically by flipping the toggle back off).
  Future<bool> startLivePreview({int udpPort = 49199}) async {
    if (_status != CameraStatus.connected) {
      _previewError = 'Not connected';
      notifyListeners();
      return false;
    }
    if (_previewActive) return true;
    _previewError = null;

    final camera = _camera;
    if (camera == null) {
      _previewError = 'No active camera handle';
      notifyListeners();
      return false;
    }

    MjpegUdpStream? stream;
    try {
      stream = await MjpegUdpStream.open(udpPort);
      final body = await camera.startStream(udpPort);
      if (!isResultOk(body)) {
        await stream.close();
        _previewError = 'Camera rejected startstream: ${resultText(body)}';
        notifyListeners();
        return false;
      }
    } on LumixException catch (e) {
      await stream?.close();
      _previewError = e.message;
      notifyListeners();
      return false;
    } catch (e) {
      await stream?.close();
      _previewError = 'Could not start live preview: $e';
      notifyListeners();
      return false;
    }

    _previewStream = stream;
    _previewSub = stream.jpegFrames.listen(
      (jpeg) async {
        if (_previewPaused) return;
        try {
          final image = await decodeJpeg(jpeg);
          // Dispose the previous image so its GPU resources are freed.
          _previewImage.value?.dispose();
          _previewImage.value = image;
        } catch (_) {
          // Bad frame; skip. Next one is ~200 ms away.
        }
      },
      onError: (_) {
        // Socket-level error; the stop path will surface it.
      },
    );

    // Session keep-alive is carried by the always-on polling loop
    // (PR 5) — no preview-specific heartbeat needed.
    _previewActive = true;
    notifyListeners();
    return true;
  }

  /// Stop the MJPEG live preview. Tears down the local UDP listener
  /// and asks the camera to stop streaming. Safe to call when no
  /// preview is active (no-op in that case).
  Future<void> stopLivePreview() async {
    final wasActive = _previewActive;
    _previewActive = false;
    await _previewSub?.cancel();
    _previewSub = null;
    await _previewStream?.close();
    _previewStream = null;
    _previewImage.value?.dispose();
    _previewImage.value = null;

    if (wasActive) {
      final camera = _camera;
      if (camera != null) {
        try {
          await camera.stopStream();
        } catch (_) {
          // Best effort.
        }
      }
    }
    notifyListeners();
  }

  /// Pause/resume frame decoding while keeping the camera streaming
  /// and the UDP socket draining. Used by the UI when the camera tab
  /// is offscreen — saves CPU without renegotiating the stream.
  /// Datagrams continue to be read (so the kernel buffer doesn't
  /// fill up) and rate-limited, but the decode step is skipped.
  void setPreviewPaused(bool paused) {
    if (_previewPaused == paused) return;
    _previewPaused = paused;
  }

  /// Issue an arbitrary `cam.cgi` request on the live camera handle.
  /// Used by the diagnostics tool ([CameraDiagnostics]) so it can
  /// probe any endpoint without widening the typed transport API.
  /// Throws a [LumixException] if there is no active connection.
  Future<String> diagnosticRawGet(Map<String, String> query) {
    final camera = _camera;
    if (camera == null) {
      throw LumixException('not_connected: no active camera');
    }
    return camera.rawGet(query);
  }

  /// Apply a camera setting (`setsetting`). Returns null on success,
  /// or a short error detail (an `err_*` code, or a transport error)
  /// that the camera tab turns into a transient "Camera rejected"
  /// message.
  Future<String?> applySetting(String type, String value) async {
    final camera = _camera;
    if (camera == null) return 'not connected';
    try {
      final body = await camera.setSetting(type, value);
      return isResultOk(body) ? null : resultText(body);
    } on LumixException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// Fire a single still capture (`camcmd&value=capture`). Returns
  /// null on success, or a short error detail.
  Future<String?> capture() async {
    final camera = _camera;
    if (camera == null) return 'not connected';
    try {
      final body = await camera.capture();
      return isResultOk(body) ? null : resultText(body);
    } on LumixException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  // --- Polling loop (PR 5).

  /// Start the 1 Hz poll. Idempotent; called on reaching Connected.
  void _startPolling() {
    if (_polling) return;
    _polling = true;
    _pollFailCount = 0;
    _pollCycle = 0;
    _pollLoop();
  }

  void _stopPolling() {
    _polling = false;
  }

  /// Self-rescheduling poll — await-then-delay rather than
  /// `Timer.periodic`, so a slow cycle can't pile requests up.
  Future<void> _pollLoop() async {
    while (_polling) {
      await _pollOnce();
      if (!_polling) break;
      await Future<void>.delayed(_pollInterval);
    }
  }

  /// One poll cycle: `getstate` (the health signal) plus `getsetting`
  /// for shutter / ISO / aperture. A `getstate` failure increments
  /// the fail counter; three in a row → connection lost. The three
  /// `getsetting` reads are best-effort — a miss leaves that value
  /// stale until the next cycle.
  Future<void> _pollOnce() async {
    final camera = _camera;
    if (camera == null) return;

    CameraState? state;
    try {
      state = parseGetState(await camera.getState());
    } catch (_) {
      state = null;
    }
    if (!_polling) return;
    if (state == null) {
      _pollFailCount++;
      if (_pollFailCount >= 3) {
        await _failTo('Connection to camera lost');
      }
      return;
    }
    _cameraState = state;
    _pollFailCount = 0;

    for (final type in const ['shtrspeed', 'iso', 'focal', 'exposure']) {
      if (!_polling) return;
      try {
        final value = parseGetSetting(await camera.getSetting(type), type);
        if (value != null) {
          switch (type) {
            case 'shtrspeed':
              _shutterWire = value;
            case 'iso':
              _isoWire = value;
            case 'focal':
              _focalWire = value;
            case 'exposure':
              _exposureWire = value;
          }
        }
      } catch (_) {
        // Tolerated — the value stays stale until the next cycle.
      }
    }

    // Every 5th cycle, refresh the shooting mode from curmenu
    // (~45 KB — too heavy for 1 Hz; the dial changes rarely).
    if (_polling && _pollCycle % 5 == 0) {
      try {
        final mode = parseRecmode(
            await camera.rawGet({'mode': 'getinfo', 'type': 'curmenu'}));
        if (mode != null) _recMode = mode;
      } catch (_) {
        // Tolerated — the mode stays stale until the next cycle.
      }
    }
    _pollCycle++;
    if (_polling) notifyListeners();
  }

  /// Disconnect: polite-goodbye sequence via the transport, plus
  /// state-machine reset.
  Future<void> disconnect() async {
    _stopPolling();
    await stopLivePreview();
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
    _stopPolling();
    await stopLivePreview();
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
    // Best-effort teardown; we don't await since dispose is sync.
    _stopPolling();
    _previewSub?.cancel();
    _previewStream?.close();
    _previewImage.value?.dispose();
    _previewImage.dispose();
    _camera?.disconnect(streaming: _previewActive);
    super.dispose();
  }
}

final cameraConnectionProvider =
    ChangeNotifierProvider<CameraConnection>((ref) => CameraConnection());
