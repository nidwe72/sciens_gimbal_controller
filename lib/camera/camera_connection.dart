import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../panorama/pano_tile_image.dart';
import 'camera_transport.dart';
import 'capture_sounds.dart';
import 'demo_lumix_camera.dart';
import 'jpeg_decoder.dart';
import 'lumix_camera.dart';
import 'lumix_content.dart';
import 'lumix_protocol.dart';

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
    CameraTransport Function()? cameraFactory,
    CaptureSounds Function()? captureSoundsFactory,
    Duration pollInterval = const Duration(seconds: 1),
  })  : _cameraFactory = cameraFactory ?? LumixCamera.new,
        _captureSoundsFactory =
            captureSoundsFactory ?? AudioPlayersCaptureSounds.new,
        _pollInterval = pollInterval;

  /// Builds the transport for each connect attempt. Injectable so
  /// `camera_connection_test.dart` can supply a `LumixCamera` wired to
  /// a mock `http.Client`.
  final CameraTransport Function() _cameraFactory;

  /// Builds the capture-SFX instance lazily on first
  /// `captureWithDelay` call. Injectable so tests can supply a
  /// counting fake instead of the platform-bound soundpool impl.
  final CaptureSounds Function() _captureSoundsFactory;
  CaptureSounds? _sounds;

  /// Gap between poll cycles — overridable so tests run fast.
  final Duration _pollInterval;

  CameraTransport? _camera;
  CameraStatus _status = CameraStatus.disconnected;
  String _statusText = 'Disconnected';
  String? _errorText;
  AllMenu? _caps;

  // Live-preview state (PR 4).
  StreamSubscription<Uint8List>? _previewSub;
  bool _previewActive = false;
  bool _previewPaused = false;
  int _previewPort = 49199;
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

  // Captured-image state (PR 8).
  LumixContent? _content;
  String? _lastFullImageUrl;
  final _capturedImage = ValueNotifier<ui.Image?>(null);
  bool _fetchInProgress = false;

  // Panorama per-tile thumbnail state (Phase 4 revision). The demo
  // asset is decoded once and shared across all demo tiles; the live
  // path tracks the last fetched item id as a freshness guard so a
  // lagging SD index can't mis-fill later cells.
  ui.Image? _demoTileAsset;
  int? _lastPanoTileId;
  static const int _panoFetchRetries = 4;
  static const Duration _panoFetchRetryDelay = Duration(milliseconds: 250);

  // Capture-delay state (PR 10).
  final ValueNotifier<int?> _countdownSecondsLeft = ValueNotifier(null);
  final ValueNotifier<bool> _overlayActive = ValueNotifier(false);
  final ValueNotifier<bool> _muted = ValueNotifier(false);
  int? _initialCountdownSeconds;
  Timer? _countdownTimer;
  bool _countdownCancelled = false;
  Completer<String?>? _countdownCompleter;
  _LifecycleObserver? _lifecycleObserver;

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

  /// Running integer seconds during a `captureWithDelay` countdown
  /// phase; `null` once the firing phase starts or when no capture
  /// is active. Drives the centred number of the capture-delay
  /// overlay's countdown ring.
  ValueListenable<int?> get countdownSecondsLeft => _countdownSecondsLeft;

  /// True from the moment a `captureWithDelay(seconds > 0)` begins
  /// until that capture completes (success, error, cancel, or
  /// app-paused abort). The UI binds the capture-delay overlay's
  /// visibility to this. For `captureWithDelay(0)` this stays
  /// `false` throughout.
  ValueListenable<bool> get overlayActive => _overlayActive;

  /// Mute toggle for the capture SFX (shutter + countdown beeps).
  /// Default `false` (sounds play). The camera still fires when
  /// muted; this gates audio only.
  ValueNotifier<bool> get muted => _muted;

  /// The N that the current `captureWithDelay(N)` call started
  /// with. Used by the capture-delay overlay to compute the
  /// countdown ring's drain progress
  /// (`countdownSecondsLeft / initialCountdownSeconds`). `null`
  /// when no countdown is active.
  int? get initialCountdownSeconds => _initialCountdownSeconds;

  /// IP we ended up talking to (real or manual). Useful for the UI's
  /// connection-summary line.
  String? get cameraIp => _camera?.cameraIp;

  /// True when the active transport is the simulated Demo Lumix S5.
  bool get isDemo => _camera is DemoLumixCamera;

  /// The demo transport's virtual camera body, or null on a real
  /// camera. The "Virtual Lumix S5" tab drives this.
  DemoLumixCamera? get demoCamera =>
      _camera is DemoLumixCamera ? _camera as DemoLumixCamera : null;

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

  /// Latest captured still (medium JPEG) for the camera pane, set
  /// after a capture. Null until the first shot is fetched.
  ValueListenable<ui.Image?> get capturedImage => _capturedImage;

  /// True while a post-capture image fetch (and the camera-mode
  /// restore that follows) is running. The capture button stays
  /// disabled until it clears, so a new capture can't land while the
  /// camera is briefly in playback mode.
  bool get fetchInProgress => _fetchInProgress;

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
  Future<bool> connect({String? manualIp, bool demo = false}) async {
    if (_status != CameraStatus.disconnected && _status != CameraStatus.error) {
      return false;
    }
    _errorText = null;
    final camera = demo ? DemoLumixCamera() : _cameraFactory();
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
      // Warm up ContentDirectory discovery so the first captured
      // image (PR 8) appears without the ~3 s SSDP delay.
      final content = LumixContent(camera);
      _content = content;
      content.discover();
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
    _previewPort = udpPort;
    _previewError = null;

    final camera = _camera;
    if (camera == null) {
      _previewError = 'No active camera handle';
      notifyListeners();
      return false;
    }

    try {
      final body = await camera.startStream(udpPort);
      if (!isResultOk(body)) {
        _previewError = 'Camera rejected startstream: ${resultText(body)}';
        notifyListeners();
        return false;
      }
    } on LumixException catch (e) {
      _previewError = e.message;
      notifyListeners();
      return false;
    } catch (e) {
      _previewError = 'Could not start live preview: $e';
      notifyListeners();
      return false;
    }

    _previewSub = camera.previewFrames.listen(
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

  /// Diagnostics: GET an arbitrary URL on the live camera handle.
  Future<String> diagnosticGetUrl(String url) {
    final camera = _camera;
    if (camera == null) {
      throw LumixException('not_connected: no active camera');
    }
    return camera.rawGetUrl(url);
  }

  /// Diagnostics: POST a SOAP request on the live camera handle.
  Future<String> diagnosticSoapPost(
      String url, String soapAction, String body) {
    final camera = _camera;
    if (camera == null) {
      throw LumixException('not_connected: no active camera');
    }
    return camera.soapPost(url, soapAction, body);
  }

  /// Diagnostics: SSDP M-SEARCH on the camera network; raw replies.
  Future<List<String>> diagnosticSsdpProbe() {
    final camera = _camera;
    if (camera == null) {
      throw LumixException('not_connected: no active camera');
    }
    return camera.ssdpProbe();
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

  /// Captures with an optional software-driven delay (PR 10). With
  /// [seconds] = 0 the immediate-fire path runs (no overlay, just a
  /// shutter sound + the existing [capture] call). With [seconds] > 0
  /// it drives a Nikon-style countdown via [_ensureSounds]:
  ///
  /// - **Slow phase** — one beep at the start of each remaining
  ///   second while `seconds_remaining >= 3`.
  /// - **Fast phase** — one beep every 0.5 s during the final 2 s
  ///   (T = 2.0, 1.5, 1.0, 0.5).
  /// - At T = 0 the shutter sound plays and the underlying
  ///   [capture] call fires.
  ///
  /// Drives [countdownSecondsLeft] (the integer displayed in the
  /// overlay) and [overlayActive] (the visibility of the
  /// capture-delay overlay). [cancelCountdown] aborts a countdown
  /// in progress. Returns null on capture success, or a short error
  /// detail (the string `'cancelled'` if the user cancelled).
  Future<String?> captureWithDelay(int seconds) async {
    if (seconds < 0) seconds = 0;

    if (seconds == 0) {
      // Immediate path — no countdown phase, but still flip the
      // overlay on so the iris glyph flashes during the actual
      // camera-firing window. The shutter sounds (open + close
      // bracketing the exposure) also play. A 500 ms minimum-display
      // floor keeps the iris visible long enough to register even
      // when the body fires faster.
      _overlayActive.value = true;
      if (!_muted.value) unawaited(_ensureSounds().playShutter());
      try {
        final minDisplay =
            Future<void>.delayed(const Duration(milliseconds: 500));
        final err = await capture();
        await minDisplay;
        return err;
      } finally {
        _overlayActive.value = false;
      }
    }

    if (_countdownTimer != null) {
      return 'capture-delay countdown already in progress';
    }

    _registerLifecycleObserver();
    _overlayActive.value = true;
    _countdownSecondsLeft.value = seconds;
    _initialCountdownSeconds = seconds;
    _countdownCancelled = false;

    final sounds = _ensureSounds();

    // Initial beep at countdown start (T = N). For N >= 3 this is
    // the first slow beep; for N = 1 or 2 it's the first fast beep
    // (T = 1.0 / T = 2.0). Either way the user hears the start.
    if (!_muted.value) unawaited(sounds.playBeep());

    final completer = Completer<String?>();
    _countdownCompleter = completer;
    int currentTick = 0;

    _countdownTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (t) async {
        if (_countdownCancelled) {
          t.cancel();
          _countdownTimer = null;
          if (!completer.isCompleted) completer.complete('cancelled');
          return;
        }

        currentTick++;
        final remaining = seconds - currentTick * 0.5;

        if (remaining <= 0) {
          // Fire phase. Cancel the timer first, then play the
          // shutter sounds (open + close bracketing the exposure)
          // and invoke the underlying capture. The 500 ms
          // minimum-display floor keeps the iris visible long enough
          // to register even when the body fires faster.
          t.cancel();
          _countdownTimer = null;
          _countdownSecondsLeft.value = null;
          if (!_muted.value) unawaited(sounds.playShutter());
          final minDisplay =
              Future<void>.delayed(const Duration(milliseconds: 500));
          final err = await capture();
          await minDisplay;
          if (!completer.isCompleted) completer.complete(err);
          return;
        }

        // Display update — only changes on integer-second boundaries.
        if (remaining == remaining.truncateToDouble()) {
          _countdownSecondsLeft.value = remaining.toInt();
        }

        // Beep cadence:
        //   slow phase — at integer seconds while remaining >= 3
        //   fast phase — at T = 2.0, 1.5, 1.0, 0.5
        if (remaining == remaining.truncateToDouble() && remaining >= 3) {
          if (!_muted.value) unawaited(sounds.playBeep());
        } else if (remaining == 2.0 ||
            remaining == 1.5 ||
            remaining == 1.0 ||
            remaining == 0.5) {
          if (!_muted.value) unawaited(sounds.playBeep());
        }
      },
    );

    try {
      return await completer.future;
    } finally {
      _overlayActive.value = false;
      _countdownSecondsLeft.value = null;
      _initialCountdownSeconds = null;
      _countdownTimer?.cancel();
      _countdownTimer = null;
      _countdownCompleter = null;
      _unregisterLifecycleObserver();
    }
  }

  /// Aborts a [captureWithDelay] countdown in progress. No effect
  /// once the firing phase has started — an in-flight camera shot
  /// can't be cancelled.
  void cancelCountdown() {
    if (_countdownTimer == null) return;
    _countdownCancelled = true;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    // Resolve the awaiting captureWithDelay future directly so its
    // finally-block runs immediately (dismisses the overlay, clears
    // countdown state). Without this the timer-cancelled callback
    // would never get a chance to fire, and the await would hang.
    final completer = _countdownCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete('cancelled');
    }
  }

  CaptureSounds _ensureSounds() => _sounds ??= _captureSoundsFactory();

  void _registerLifecycleObserver() {
    if (_lifecycleObserver != null) return;
    final observer = _LifecycleObserver(_onLifecyclePaused);
    _lifecycleObserver = observer;
    WidgetsBinding.instance.addObserver(observer);
  }

  void _unregisterLifecycleObserver() {
    final observer = _lifecycleObserver;
    if (observer == null) return;
    _lifecycleObserver = null;
    WidgetsBinding.instance.removeObserver(observer);
  }

  void _onLifecyclePaused() {
    cancelCountdown();
  }

  /// Fetch the most-recent captured JPEG (medium size) and publish it
  /// via [capturedImage]; also stash the full-res URL for
  /// [fetchFullImage]. Called after a successful capture. Best-effort
  /// — a failure simply leaves no still.
  Future<void> fetchLastImage() async {
    final content = _content;
    final camera = _camera;
    if (content == null || camera == null) return;
    _fetchInProgress = true;
    notifyListeners();
    try {
      final item = await content.fetchLatest();
      if (item == null) return;
      _lastFullImageUrl = item.fullUrl;
      final mediumUrl = item.mediumUrl ?? item.fullUrl;
      if (mediumUrl == null) return;
      final image = await decodeJpeg(await camera.rawGetBytes(mediumUrl));
      _capturedImage.value?.dispose();
      _capturedImage.value = image;
    } catch (_) {
      // Best effort — no still shown.
    } finally {
      await _restoreAfterContentAccess(camera);
    }
  }

  /// Fetch the full-resolution version of the last captured image,
  /// decoded at a capped width, for the full-screen viewer. Null on
  /// failure or if nothing has been captured.
  Future<ui.Image?> fetchFullImage() async {
    final content = _content;
    final camera = _camera;
    if (content == null || camera == null) return null;
    _fetchInProgress = true;
    notifyListeners();
    ui.Image? result;
    try {
      // Re-browse first: the SOAP Browse flips the camera into
      // playback mode, which the :50001 image server needs in order
      // to serve content — the same proven path fetchLastImage uses.
      // It also refreshes the URL.
      final item = await content.fetchLatest();
      final url = item?.fullUrl ?? _lastFullImageUrl;
      if (url != null) {
        result = await decodeJpeg(
          await camera.rawGetBytes(url,
              timeout: const Duration(seconds: 25)),
          targetWidth: 3000,
        );
      }
    } catch (_) {
      result = null;
    }
    // Restore in the background so the full-screen viewer isn't held
    // up by the recmode + preview-restart round trips.
    unawaited(_restoreAfterContentAccess(camera));
    return result;
  }

  /// Reset the panorama per-tile fetch state. Called by the sequencer
  /// at the start of each run so the freshness guard's id baseline
  /// doesn't carry over between runs.
  void resetPanoFetch() => _lastPanoTileId = null;

  /// Produce the image for one panorama tile (SPEC Phase 4 "Per-tile
  /// tile images"). Mode-agnostic to the caller — the demo/live branch
  /// lives here:
  ///
  /// - **Demo**: crop the bundled asset (decoded once, shared) to the
  ///   tile's **fractional window** (`srcFrac*`, from the grid math) —
  ///   overlapping windows so the stitcher has correspondences. No
  ///   transport, no `recMode`.
  /// - **Live**: fetch the SM thumbnail of the just-taken frame, with a
  ///   strictly-increasing-id freshness guard (brief retry), then
  ///   **await** the `recMode` restore so the next `capture()` lands in
  ///   record mode. Isolated from [capturedImage]. (The `srcFrac*` args
  ///   are ignored on the live path.)
  ///
  /// Returns null on failure; the caller treats null as a hard abort.
  Future<PanoTileImage?> fetchPanoTile({
    required double srcFracLeft,
    required double srcFracTop,
    required double srcFracWidth,
    required double srcFracHeight,
  }) async {
    final demo = demoCamera;
    if (demo != null) {
      try {
        final asset = _demoTileAsset ??=
            await decodeJpeg(await demo.capturedStillBytes());
        final aw = asset.width.toDouble();
        final ah = asset.height.toDouble();
        // Map the normalised window onto the asset, clamped to bounds.
        final left = (srcFracLeft * aw).clamp(0.0, aw);
        final top = (srcFracTop * ah).clamp(0.0, ah);
        final right = ((srcFracLeft + srcFracWidth) * aw).clamp(left, aw);
        final bottom = ((srcFracTop + srcFracHeight) * ah).clamp(top, ah);
        final src = ui.Rect.fromLTRB(left, top, right, bottom);
        return PanoTileImage(image: asset, src: src, ownsImage: false);
      } catch (_) {
        return null;
      }
    }
    return _fetchLivePanoTile();
  }

  Future<PanoTileImage?> _fetchLivePanoTile() async {
    final content = _content;
    final camera = _camera;
    if (content == null || camera == null) return null;
    _fetchInProgress = true;
    notifyListeners();
    try {
      // Freshness guard: the new shot's id must strictly exceed the
      // previous tile's. SD indexing can lag the isBusy→idle signal, so
      // retry briefly before giving up.
      ContentImage? fresh;
      for (var attempt = 0; attempt < _panoFetchRetries; attempt++) {
        final item = await content.fetchLatest();
        final id = item == null ? null : int.tryParse(item.id);
        if (item != null &&
            id != null &&
            (_lastPanoTileId == null || id > _lastPanoTileId!)) {
          _lastPanoTileId = id;
          fresh = item;
          break;
        }
        await Future<void>.delayed(_panoFetchRetryDelay);
      }
      if (fresh == null) return null; // never advanced → caller aborts.
      final smUrl = fresh.mediumUrl ?? fresh.fullUrl;
      if (smUrl == null) return null;
      final image =
          await decodeJpeg(await camera.rawGetBytes(smUrl), targetWidth: 480);
      return PanoTileImage(
        image: image,
        src: ui.Rect.fromLTWH(
            0, 0, image.width.toDouble(), image.height.toDouble()),
        ownsImage: true,
      );
    } catch (_) {
      return null;
    } finally {
      // Always restore record mode (awaited) — even on the failure path
      // — so the camera is left sane for the next capture / abort.
      await _restoreAfterContentAccess(camera);
    }
  }

  /// Recover the camera after touching the DLNA content server.
  /// Browsing / downloading silently flips the camera into playback
  /// mode, which drops both the shutter (`camcmd capture` is accepted
  /// but takes no photo) and the MJPEG stream. Re-assert record mode,
  /// and bounce live preview if it was running. Clears
  /// [fetchInProgress] when done. Best-effort throughout.
  Future<void> _restoreAfterContentAccess(CameraTransport camera) async {
    try {
      try {
        await camera.recMode();
      } catch (_) {
        // Best effort — the next poll's getstate keeps us honest.
      }
      // recmode does not restart the MJPEG stream; bounce the preview
      // (stopstream + fresh socket + startstream) so it keeps running.
      if (_previewActive) {
        await stopLivePreview();
        await startLivePreview(udpPort: _previewPort);
      }
    } finally {
      _fetchInProgress = false;
      notifyListeners();
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

    // Refresh the shooting mode from curmenu. The real curmenu is
    // ~45 KB — too heavy for 1 Hz, so every 5th cycle. The demo's is
    // cheap, so every cycle — the Virtual tab's dial feels instant.
    if (_polling && _pollCycle % (isDemo ? 1 : 5) == 0) {
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
    _content = null;
    _lastFullImageUrl = null;
    _capturedImage.value?.dispose();
    _capturedImage.value = null;
    // NB: don't dispose _demoTileAsset here — the pano grid may still be
    // painting tiles that reference the shared asset image. It's cached
    // for the connection's lifetime and freed in dispose().
    _lastPanoTileId = null;
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
    _content = null;
    _lastFullImageUrl = null;
    _capturedImage.value?.dispose();
    _capturedImage.value = null;
    // See disconnect(): the shared demo asset outlives a disconnect.
    _lastPanoTileId = null;
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
    _previewImage.value?.dispose();
    _previewImage.dispose();
    _capturedImage.value?.dispose();
    _capturedImage.dispose();
    _demoTileAsset?.dispose();
    _demoTileAsset = null;
    _camera?.disconnect(streaming: _previewActive);
    // PR 10 capture-delay teardown.
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _unregisterLifecycleObserver();
    _sounds?.dispose();
    _sounds = null;
    _countdownSecondsLeft.dispose();
    _overlayActive.dispose();
    _muted.dispose();
    super.dispose();
  }
}

/// Forwards Android app-lifecycle transitions to a single callback.
/// Used by [CameraConnection] to abort an in-progress capture-delay
/// countdown when the app is backgrounded (`AppLifecycleState.paused`).
class _LifecycleObserver extends WidgetsBindingObserver {
  _LifecycleObserver(this._onPaused);
  final VoidCallback _onPaused;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _onPaused();
  }
}

final cameraConnectionProvider =
    ChangeNotifierProvider<CameraConnection>((ref) => CameraConnection());
