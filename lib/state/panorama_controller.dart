import 'dart:async';
import 'dart:ui' as ui;

import 'package:feiyu_gimbal/feiyu_gimbal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../camera/camera_connection.dart';
import '../panorama/geometric_stitcher.dart';
import '../panorama/panorama_grid.dart';
import '../panorama/pano_tile_image.dart';
import '../panorama/server_stitcher.dart';
import 'gimbal_connection.dart';

/// How the preview panorama is assembled.
enum StitchMode {
  /// Flat geometric placement at the known grid positions — pure-Dart, instant.
  simple,

  /// Feature-stitch via the in-process Python server (Chaquopy). The projection
  /// (affine / rectilinear / spherical) is derived from demo-vs-live + focal.
  /// Default.
  advanced,
}

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

  /// Per-tile thumbnail/crop, indexed by `TilePosition.index`. Null
  /// until that tile is shot. Demo tiles share one asset image (not
  /// owned); live tiles each own their SM thumbnail.
  List<PanoTileImage?> _tileImages = const [];
  List<PanoTileImage?> get tileImages => List.unmodifiable(_tileImages);

  int _currentIndex = -1;
  int get currentIndex => _currentIndex;

  String? _message;
  String? get message => _message;

  bool _cancelRequested = false;

  // --- Stitch-preview state (Phase 6 enhancement).
  final ServerStitcher _serverStitcher = ServerStitcher();

  /// Selected assembly mode (GUI-selectable). Default = advanced.
  StitchMode _stitchMode = StitchMode.advanced;
  StitchMode get stitchMode => _stitchMode;
  void setStitchMode(StitchMode mode) {
    if (_stitchMode == mode || _stitching) return;
    _stitchMode = mode;
    notifyListeners();
  }

  /// Projection for the `advanced` server stitch (GraphQL `Projection` enum):
  /// - demo → AFFINE (tiles are flat crops of one asset);
  /// - live → rotational: RECTILINEAR for focalStitch ≥ 18 mm (≤~90° FOV, looks
  ///   like one wide-angle lens), else SPHERICAL (15–18 mm, >90°).
  String _projection() {
    final isDemo = _ref.read(cameraConnectionProvider).isDemo;
    if (isDemo) return 'AFFINE';
    return _focalStitch >= 18 ? 'RECTILINEAR' : 'SPHERICAL';
  }

  bool _stitching = false;
  bool get stitching => _stitching;

  /// Coarse stage label shown in the progress overlay while stitching.
  String? _stitchStage;
  String? get stitchStage => _stitchStage;

  /// Stitch progress 0–1 (determinate ring), or null for indeterminate.
  double? _stitchProgress;
  double? get stitchProgress => _stitchProgress;

  /// Cached stitched panorama (in memory, invalidated by a new run).
  ui.Image? _stitchedPano;
  ui.Image? get stitchedPano => _stitchedPano;
  bool get hasStitchedPano => _stitchedPano != null;

  String? _stitchError;
  String? get stitchError => _stitchError;

  /// Generation counter for soft-cancel: a stitch whose generation has
  /// been superseded (by Cancel or a new run) discards its result.
  int _stitchGen = 0;

  /// Whether "Stitch pano" may run now: a completed run, ≥2 tiles, and
  /// not already stitching.
  bool get canStitch =>
      _state == PanoState.done &&
      !_stitching &&
      _tileImages.where((t) => t != null).length >= 2;

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
    _disposeTileImages();
    notifyListeners();
  }

  /// Dispose owned (live) tile images and clear the list. The demo's
  /// shared asset is owned by CameraConnection, so its tiles
  /// (`ownsImage == false`) are left alone.
  void _disposeTileImages() {
    for (final t in _tileImages) {
      if (t != null && t.ownsImage) t.image.dispose();
    }
    _tileImages = const [];
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
    _tileImages = List<PanoTileImage?>.filled(_grid.totalShots, null);
    _clearStitchedPano(); // "Take panorama" invalidates the cached preview
    camera.resetPanoFetch();
    _cancelRequested = false;
    _currentIndex = -1;
    _message = null;
    _state = PanoState.running;
    notifyListeners();

    // Live preview competes with rapid stills capture — stop it.
    await camera.stopLivePreview();

    for (final tile in _grid.tiles) {
      if (_cancelRequested) break;
      // Gimbal link down → can't drive home, leave in place. Camera link
      // down → gimbal healthy, so return to centre (see SPEC return-to-
      // centre rule).
      if (!gimbal.isConnected) {
        _finish(PanoState.aborted, 'Gimbal disconnected mid-run');
        return;
      }
      if (!camera.isConnected) {
        await _returnToCentre(gimbal, centreYaw, centrePitch);
        _finish(PanoState.aborted, 'Camera disconnected mid-run');
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
        await _returnToCentre(gimbal, centreYaw, centrePitch);
        _finish(PanoState.aborted, 'Camera disconnected before capture');
        return;
      }

      final err = await camera.capture();
      if (err != null) {
        // Camera-side failure, gimbal healthy → return to centre.
        _setTile(tile.index, TileState.failed);
        await _returnToCentre(gimbal, centreYaw, centrePitch);
        _finish(PanoState.aborted, 'Capture failed at tile ${tile.index}: $err');
        return;
      }

      await _awaitShotComplete(camera);

      // Mandatory per-tile image (demo crop / live SM thumbnail). A
      // failure here aborts the whole run — there is no thumbnail-less
      // "taken" state. Camera-side failure → return to centre.
      final tileImage = await camera.fetchPanoTile(
        srcFracLeft: tile.srcFracLeft,
        srcFracTop: tile.srcFracTop,
        srcFracWidth: tile.srcFracWidth,
        srcFracHeight: tile.srcFracHeight,
      );
      if (tileImage == null) {
        _setTile(tile.index, TileState.failed);
        await _returnToCentre(gimbal, centreYaw, centrePitch);
        _finish(PanoState.aborted, 'Image fetch failed at tile ${tile.index}');
        return;
      }
      _setTileImage(tile.index, tileImage);
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

  void _setTileImage(int index, PanoTileImage image) {
    if (index < 0 || index >= _tileImages.length) return;
    _tileImages[index] = image;
    notifyListeners();
  }

  // --- Stitch preview (Phase 6).

  /// Assemble the captured tiles into a preview panorama (via the
  /// selected [stitchMode]) and cache it. No-op unless [canStitch].
  /// Soft-cancellable via [cancelStitch].
  Future<void> stitchPano() async {
    if (!canStitch) return;

    final gen = ++_stitchGen;
    _stitching = true;
    _stitchError = null;
    _stitchProgress = null;
    _stitchStage =
        _stitchMode == StitchMode.simple ? 'Placing tiles…' : 'Preparing tiles…';
    notifyListeners();

    ui.Image? image;
    String? error;
    if (_stitchMode == StitchMode.simple) {
      // Flat, deterministic, near-instant — pure Dart.
      try {
        image = await geometricStitch(_grid, _tileImages);
      } catch (e) {
        error = '$e';
      }
    } else {
      final ordered = _orderedTiles();
      void onStage(String s, double? p) {
        if (gen == _stitchGen) {
          _stitchStage = s;
          _stitchProgress = p;
          notifyListeners();
        }
      }

      final result = await _serverStitcher.stitch(
        ordered,
        nCols: _grid.nCols,
        projection: _projection(),
        onStage: onStage,
      );
      image = result.image;
      error = result.ok ? null : result.error;
    }

    // Superseded by Cancel or a new run → discard this result.
    if (gen != _stitchGen) {
      image?.dispose();
      return;
    }

    _stitching = false;
    _stitchStage = null;
    _stitchProgress = null;
    if (image != null) {
      _stitchedPano?.dispose();
      _stitchedPano = image;
    } else {
      _stitchError = error ?? 'Stitch failed.';
    }
    notifyListeners();
  }

  /// Soft-cancel an in-flight stitch: the overlay closes immediately; the
  /// orphaned native call finishes in the background and its result is
  /// dropped (the generation no longer matches).
  void cancelStitch() {
    if (!_stitching) return;
    _stitchGen++;
    _stitching = false;
    _stitchStage = null;
    _stitchProgress = null;
    notifyListeners();
  }

  /// Tiles in spatial row-major order (the stitcher's preferred input).
  List<PanoTileImage> _orderedTiles() {
    final indexByRowCol = <int, int>{};
    for (final t in _grid.tiles) {
      indexByRowCol[t.row * _grid.nCols + t.col] = t.index;
    }
    final ordered = <PanoTileImage>[];
    for (var r = 0; r < _grid.nRows; r++) {
      for (var c = 0; c < _grid.nCols; c++) {
        final idx = indexByRowCol[r * _grid.nCols + c];
        if (idx != null && idx < _tileImages.length && _tileImages[idx] != null) {
          ordered.add(_tileImages[idx]!);
        }
      }
    }
    return ordered;
  }

  /// Drop the cached pano and supersede any in-flight stitch. Called when
  /// a new run starts ("Take panorama" is the sole cache invalidator).
  void _clearStitchedPano() {
    _stitchGen++;
    _stitching = false;
    _stitchStage = null;
    _stitchProgress = null;
    _stitchError = null;
    _stitchedPano?.dispose();
    _stitchedPano = null;
  }

  @override
  void dispose() {
    _disposeTileImages();
    _stitchedPano?.dispose();
    super.dispose();
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
