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

  // Live-preview state (PR 4).
  MjpegUdpStream? _previewStream;
  StreamSubscription<Uint8List>? _previewSub;
  Timer? _previewKeepAlive;
  bool _previewActive = false;
  bool _previewPaused = false;
  String? _previewError;
  final _previewImage = ValueNotifier<ui.Image?>(null);

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

    // Keep-alive heartbeat. Lumix bodies time out the session if no
    // cam.cgi command is sent for ~10 s, which manifests as the
    // preview pane freezing on its last frame. liblumix's protocol
    // notes call this out explicitly. We ping `getstate` at 1 Hz —
    // cheap, idempotent, and read-only. PR 5's full polling loop
    // will replace this with the same cadence carrying more reads.
    _previewKeepAlive = Timer.periodic(const Duration(seconds: 1),
        (_) async {
      final cam = _camera;
      if (cam == null || !_previewActive) return;
      try {
        await cam.getState();
      } catch (_) {
        // Best effort; missed pings will manifest as a freeze, which
        // is already the failure mode this guards against.
      }
    });

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
    _previewKeepAlive?.cancel();
    _previewKeepAlive = null;
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

  /// Disconnect: polite-goodbye sequence via the transport, plus
  /// state-machine reset.
  Future<void> disconnect() async {
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
    _previewKeepAlive?.cancel();
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
