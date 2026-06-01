import 'dart:async';

import 'package:feiyu_gimbal/feiyu_gimbal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../camera/camera_connection.dart';
import '../panorama/panorama_grid.dart';
import 'gimbal_connection.dart';

/// Overall run state. `done | cancelled | aborted` are terminal.
enum PanoState { idle, running, cancelling, done, cancelled, aborted }

/// Per-tile progress, indexed by `TilePosition.index`.
enum TileState { pending, active, taken, failed }

/// Drives the Brenizer capture sequence: gimbal moves (relative,
/// closed-loop) → settle → fire → wait for the shot to finish → next,
/// in serpentine order, returning to the captured centre at the end.
///
/// Riverpod-hosted (peer to GimbalConnection / CameraConnection) so a
/// run survives sub-tab/tab navigation. See SPEC-flutter-app.md
/// "Phase 4 — Panorama sequencer".
class PanoramaController extends ChangeNotifier {
  PanoramaController(this._ref);

  final Ref _ref;

  // Completion-wait tunables (SPEC Phase 4).
  static const Duration _busyMinFloor = Duration(milliseconds: 300);
  static const Duration _busyTimeout = Duration(seconds: 10);
  static const Duration _busyPoll = Duration(milliseconds: 100);

  // --- Settings (driven by the Pano sub-tab; locked during a run).
  double _focalStitch = 24;
  double _focalTaking = 50;
  double _overlap = 0.30;
  int _settleSeconds = 3;

  double get focalStitch => _focalStitch;
  double get focalTaking => _focalTaking;
  double get overlap => _overlap;
  int get settleSeconds => _settleSeconds;

  PanoramaGrid _grid = computePanoramaGrid(
    focalStitch: 24,
    focalTaking: 50,
    overlap: 0.30,
  );
  PanoramaGrid get grid => _grid;

  PanoState _state = PanoState.idle;
  PanoState get state => _state;

  /// True while a run is active (running or cancelling). UI binds the
  /// gimbal-tab lock-out, the Pano-input lock-out, and navigation
  /// blocking to this.
  bool get running =>
      _state == PanoState.running || _state == PanoState.cancelling;

  List<TileState> _tileStates = const [];
  List<TileState> get tileStates => List.unmodifiable(_tileStates);

  int _currentIndex = -1;
  int get currentIndex => _currentIndex;

  String? _message;
  String? get message => _message;

  bool _cancelRequested = false;

  /// Update one or more settings (no-op while a run is active). Recomputes
  /// the preview grid.
  void updateSettings({
    double? focalStitch,
    double? focalTaking,
    double? overlap,
    int? settleSeconds,
  }) {
    if (running) return;
    if (focalStitch != null) _focalStitch = focalStitch;
    if (focalTaking != null) _focalTaking = focalTaking;
    if (overlap != null) _overlap = overlap.clamp(0.0, kOverlapMax);
    if (settleSeconds != null) _settleSeconds = settleSeconds.clamp(0, 60);
    // Keep the two-focal constraint sane: stitched ≤ taking.
    if (_focalStitch > _focalTaking) _focalStitch = _focalTaking;
    _recompute();
  }

  void _recompute({double centreYaw = 0, double centrePitch = 0}) {
    _grid = computePanoramaGrid(
      focalStitch: _focalStitch,
      focalTaking: _focalTaking,
      overlap: _overlap,
      centreYaw: centreYaw,
      centrePitch: centrePitch,
    );
    // Drop stale per-tile progress from any previous run; start() refills.
    _tileStates = const [];
    notifyListeners();
  }

  /// Whether Take may start right now (math gate + both devices
  /// connected). The UI also greys the button on this.
  bool get canStart {
    if (running) return false;
    if (!_grid.canRun) return false;
    final gimbal = _ref.read(gimbalConnectionProvider);
    final camera = _ref.read(cameraConnectionProvider);
    return gimbal.isConnected &&
        gimbal.yawDeg != null &&
        camera.isConnected;
  }

  Future<void> start() async {
    if (!canStart) return;
    final gimbal = _ref.read(gimbalConnectionProvider);
    final camera = _ref.read(cameraConnectionProvider);

    final centreYaw = gimbal.yawDeg;
    final centrePitch = gimbal.pitchDeg;
    if (centreYaw == null || centrePitch == null) {
      _finish(PanoState.aborted, 'No gimbal orientation');
      return;
    }

    // Rebuild the grid anchored at the captured centre.
    _recompute(centreYaw: centreYaw, centrePitch: centrePitch);
    _tileStates = List<TileState>.filled(_grid.totalShots, TileState.pending);
    _cancelRequested = false;
    _currentIndex = -1;
    _message = null;
    _state = PanoState.running;
    notifyListeners();

    // Live preview competes with rapid stills capture — stop it.
    await camera.stopLivePreview();

    for (final tile in _grid.tiles) {
      if (_cancelRequested) break;
      if (!gimbal.isConnected || !camera.isConnected) {
        _finish(PanoState.aborted, 'Device disconnected mid-run');
        return;
      }

      _currentIndex = tile.index;
      _setTile(tile.index, TileState.active);

      // Relative delta from the *measured* angle so closed-loop error
      // doesn't compound across the grid.
      final dYaw = _angleDiff(tile.yawDeg, gimbal.yawDeg ?? tile.yawDeg);
      final dPitch = tile.pitchDeg - (gimbal.pitchDeg ?? tile.pitchDeg);
      final move = await gimbal.moveByAngle(courseDeg: dYaw, pitchDeg: dPitch);
      if (move.outcome == MoveOutcome.disconnected) {
        _finish(PanoState.aborted, 'Gimbal disconnected mid-move');
        return;
      }
      // residual is logged by the session; nothing to gate on here for a
      // completed/stalled/timedOut move — best-effort, continue.

      if (_cancelRequested) break;
      await Future<void>.delayed(Duration(seconds: _settleSeconds));
      if (_cancelRequested) break;
      if (!camera.isConnected) {
        _finish(PanoState.aborted, 'Camera disconnected before capture');
        return;
      }

      final err = await camera.capture();
      if (err != null) {
        _setTile(tile.index, TileState.failed);
        _finish(PanoState.aborted, 'Capture failed at tile ${tile.index}: $err');
        return;
      }

      await _awaitShotComplete(camera);
      _setTile(tile.index, TileState.taken);
    }

    // Done or cancelled — both return to the captured centre (link alive).
    _currentIndex = -1;
    await _returnToCentre(gimbal, centreYaw, centrePitch);
    _finish(
      _cancelRequested ? PanoState.cancelled : PanoState.done,
      _cancelRequested ? 'Cancelled' : 'Panorama complete',
    );
  }

  /// Request cancellation. Cooperative: the run stops after the current
  /// tile, then returns to centre.
  void cancel() {
    if (!running) return;
    _cancelRequested = true;
    _state = PanoState.cancelling;
    notifyListeners();
  }

  /// Fire-and-wait: `capture()` returns on command-ack, not when the
  /// exposure/SD-write finishes. Wait a min floor, then poll the camera's
  /// busy flag until idle (or timeout) so a long exposure isn't smeared
  /// by an early move.
  Future<void> _awaitShotComplete(CameraConnection camera) async {
    await Future<void>.delayed(_busyMinFloor);
    final start = DateTime.now();
    while (camera.isBusy &&
        DateTime.now().difference(start) < _busyTimeout) {
      await Future<void>.delayed(_busyPoll);
    }
  }

  Future<void> _returnToCentre(
    GimbalConnection gimbal,
    double centreYaw,
    double centrePitch,
  ) async {
    if (!gimbal.isConnected) return;
    final dYaw = _angleDiff(centreYaw, gimbal.yawDeg ?? centreYaw);
    final dPitch = centrePitch - (gimbal.pitchDeg ?? centrePitch);
    await gimbal.moveByAngle(courseDeg: dYaw, pitchDeg: dPitch);
  }

  void _setTile(int index, TileState s) {
    if (index < 0 || index >= _tileStates.length) return;
    _tileStates[index] = s;
    notifyListeners();
  }

  void _finish(PanoState terminal, String message) {
    _state = terminal;
    _message = message;
    _currentIndex = -1;
    _cancelRequested = false;
    notifyListeners();
  }

  static double _angleDiff(double a, double b) {
    double d = a - b;
    while (d > 180) {
      d -= 360;
    }
    while (d < -180) {
      d += 360;
    }
    return d;
  }
}

final panoramaControllerProvider =
    ChangeNotifierProvider<PanoramaController>(
  (ref) => PanoramaController(ref),
);
