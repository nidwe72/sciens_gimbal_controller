import 'dart:math' as math;

import 'package:flutter/material.dart';

/// PR 9.1 — the parallax-calibration explainer.
///
/// A self-contained, CV-free teaching animation that shows *why* the
/// no-parallax point matters: when the lens entrance pupil sits off the gimbal
/// pan axis (rail offset `e` ≠ 0), panning swings the pupil sideways, so a near
/// target drifts against a far one (parallax). On the axis (`e` = 0) the two
/// stay locked.
///
/// Two rows, each split 60% animation / 40% magnified loupe:
///   • Bird's-eye (top-down geometry)        + nodal-point loupe (rail offset)
///   • Viewfinder (the resulting image)      + chessboard-vs-figure loupe
/// plus a traffic light.
///
/// Both panels always animate (the pan sweeps continuously). Playing by default
/// also auto-cycles `e`; the three preset buttons or the `e` slider drop into
/// manual so the user sets the rail offset themselves. `e` (the rail / y-axis
/// offset) is the one degree of freedom being explored.
///
/// Pure geometry — no camera, gimbal, or OpenCV. The pixel readout is *not* a
/// calibration measurement (the real metric is the Java/OpenCV pipeline, PR
/// 9.4); on-screen offsets are exaggerated and the panels are schematic.

/// Opens the explainer as a modal bottom sheet (mirrors `header.dart`).
Future<void> showParallaxExplainer(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const ParallaxExplainerSheet(),
  );
}

class ParallaxExplainerSheet extends StatefulWidget {
  const ParallaxExplainerSheet({super.key});

  @override
  State<ParallaxExplainerSheet> createState() => _ParallaxExplainerSheetState();
}

class _ParallaxExplainerSheetState extends State<ParallaxExplainerSheet>
    with SingleTickerProviderStateMixin {
  // Tunables (illustrative; tweak freely during verification).
  static const double _panAmplitudeDeg = 8; // pan sweep half-angle
  static const int _panCyclesPerLoop = 4; // sweeps per animation loop
  static const int _eCyclesPerLoop = 2; // rail-offset auto-cycles per loop
  static const Duration _loopDuration = Duration(seconds: 24); // 3× slower
  static const double _eAutoAmpMm = 35; // auto-cycle amplitude of `e`
  static const double _presetMm = 25; // back/forward preset magnitude
  static const double _fpx = 2500; // focal length in px @ 1000-px sensor
  static const double _greenPx = 3; // traffic-light thresholds
  static const double _yellowPx = 15;
  // Real-world target sizes, so the glyphs render at their true apparent ratio.
  static const double _figureHeightM = 3.0; // statue (man on a socle)
  static const double _boardWidthM = 0.45; // 45 cm chessboard

  late final AnimationController _controller;

  bool _playing = true;
  double _eMm = -_presetMm; // user value when manual (negative = pupil behind)
  double _farM = 15; // figure distance (camera → figure)
  double _offsetM = 5; // chessboard offset *in front of* the figure

  // Derived camera→chessboard distance.
  double get _nearM => (_farM - _offsetM).clamp(1.0, _farM - 1);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _loopDuration)
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _liveEMm => _playing
      ? _eAutoAmpMm *
          math.sin(2 * math.pi * _eCyclesPerLoop * _controller.value)
      : _eMm;

  void _setManualE(double mm) => setState(() {
        _playing = false;
        _eMm = mm;
      });

  void _resumeAuto() => setState(() => _playing = true);

  // Freeze the auto-cycle at the current live offset.
  void _enterManual() => setState(() {
        _eMm = _liveEMm;
        _playing = false;
      });

  // -1 back · 0 correct · 1 forward, from the live offset.
  int _bucket(double mm) => mm < -8 ? -1 : (mm > 8 ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Why the no-parallax point matters',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                'Rotate the lens about its entrance pupil and near + far stay '
                'locked. Off the pan axis, panning swings the pupil sideways and '
                'the near chessboard drifts against the far figure — parallax. '
                'The one thing you tune is the rail offset ΔY.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 12),
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final scene = _scene();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _splitPanel(
                        theme,
                        label: "Bird's eye",
                        height: 190,
                        main: _BirdsEyePainter(scene: scene, cs: cs),
                        loupe: _NodalLoupePainter(scene: scene, cs: cs),
                      ),
                      const SizedBox(height: 8),
                      _splitPanel(
                        theme,
                        label: 'Viewfinder  (what the sensor sees)',
                        height: 160,
                        main: _ViewfinderPainter(scene: scene, cs: cs),
                        loupe: _BoardLoupePainter(scene: scene, cs: cs),
                      ),
                      const SizedBox(height: 10),
                      _readout(theme, scene),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              _controls(theme),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds the current geometric scene from the animation clock + state.
  _ParallaxScene _scene() {
    final t = _controller.value;
    final phi = _radians(_panAmplitudeDeg) *
        math.sin(2 * math.pi * _panCyclesPerLoop * t);
    return _ParallaxScene(
      phi: phi,
      panAmplitude: _radians(_panAmplitudeDeg),
      eMeters: _liveEMm / 1000,
      eMm: _liveEMm,
      nearM: _nearM,
      farM: _farM,
      fpx: _fpx,
      greenPx: _greenPx,
      yellowPx: _yellowPx,
      figureHeightM: _figureHeightM,
      boardWidthM: _boardWidthM,
    );
  }

  /// A panel split into a 60%-wide animation and a 40%-wide loupe.
  Widget _splitPanel(ThemeData theme,
      {required String label,
      required double height,
      required CustomPainter main,
      required CustomPainter loupe}) {
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
            child: Text(label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6),
                )),
          ),
          SizedBox(
            height: height,
            child: Row(
              children: [
                Expanded(
                    flex: 3,
                    child: CustomPaint(painter: main, size: Size.infinite)),
                Container(width: 1, color: cs.outlineVariant),
                Expanded(
                    flex: 2,
                    child: CustomPaint(painter: loupe, size: Size.infinite)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _readout(ThemeData theme, _ParallaxScene s) {
    final cs = theme.colorScheme;
    return Row(
      children: [
        Container(
            width: 16,
            height: 16,
            decoration:
                BoxDecoration(color: s.lightColor(), shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text('${s.residualPx.toStringAsFixed(1)} px',
            style: theme.textTheme.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
        const SizedBox(width: 10),
        Expanded(
          child: Text('${s.stateLabel} · ${s.directionLabel}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.8),
              )),
        ),
      ],
    );
  }

  Widget _controls(ThemeData theme) {
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _playing ? _enterManual : _resumeAuto,
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              label: Text(_playing ? 'Manual' : 'Auto-cycle'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _playing
                    ? 'Auto: cycling ΔY. Tap a preset to take over.'
                    : 'Manual: pick a rail-offset ΔY preset.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // The three ΔY presets are the only manual control — the bird's-eye
        // loupe shows the live value, so no fine slider is needed.
        Row(
          children: [
            Expanded(child: _preset(theme, 'Too far\nback', -_presetMm, -1)),
            const SizedBox(width: 6),
            Expanded(child: _preset(theme, 'Correct\n(NPP)', 0, 0)),
            const SizedBox(width: 6),
            Expanded(child: _preset(theme, 'Too far\nforward', _presetMm, 1)),
          ],
        ),
        const SizedBox(height: 8),
        // Secondary controls: the distances (labelled "distance" to avoid being
        // confused with the figure/board dimensions shown in the panels).
        Row(
          children: [
            Expanded(
              child: _miniSlider(theme,
                  label:
                      'chessboard offset ${_offsetM.toStringAsFixed(0)} m (ahead of figure)',
                  value: _offsetM.clamp(2, math.max(3, _farM - 1)),
                  min: 2,
                  max: math.max(3, _farM - 1),
                  onChanged: (v) =>
                      setState(() => _offsetM = v.clamp(2.0, _farM - 1))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _miniSlider(theme,
                  label: 'figure distance ${_farM.toStringAsFixed(0)} m',
                  value: _farM,
                  min: 8,
                  max: 40,
                  onChanged: (v) => setState(() {
                        _farM = v;
                        _offsetM = _offsetM.clamp(2.0, _farM - 1);
                      })),
            ),
          ],
        ),
      ],
    );
  }

  Widget _preset(ThemeData theme, String label, double mm, int bucket) {
    final active = !_playing && _bucket(_liveEMm) == bucket;
    final child = Text(label,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, height: 1.05));
    final style = ButtonStyle(
      padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 4, vertical: 6)),
    );
    return active
        ? FilledButton(
            onPressed: () => _setManualE(mm), style: style, child: child)
        : OutlinedButton(
            onPressed: () => _setManualE(mm), style: style, child: child);
  }

  Widget _miniSlider(ThemeData theme,
      {required String label,
      required double value,
      required double min,
      required double max,
      required ValueChanged<double> onChanged}) {
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.7),
            )),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 2,
            overlayShape: SliderComponentShape.noOverlay,
          ),
          child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged),
        ),
      ],
    );
  }

  static double _radians(double deg) => deg * math.pi / 180;
}

/// Immutable snapshot of the geometry for one painted frame. Holds the model
/// math so all painters and the readout share one source of truth.
class _ParallaxScene {
  _ParallaxScene({
    required this.phi,
    required this.panAmplitude,
    required this.eMeters,
    required this.eMm,
    required this.nearM,
    required this.farM,
    required this.fpx,
    required this.greenPx,
    required this.yellowPx,
    required this.figureHeightM,
    required this.boardWidthM,
  });

  final double phi; // current pan angle (rad)
  final double panAmplitude; // sweep half-angle (rad)
  final double eMeters; // rail offset (signed, m) — +ahead / −behind axis
  final double eMm;
  final double nearM; // chessboard distance
  final double farM; // figure distance
  final double fpx;
  final double greenPx;
  final double yellowPx;
  final double figureHeightM;
  final double boardWidthM;

  /// Pupil world position for a given pan angle. Pivot at origin, optical axis
  /// is +y at φ=0; rotating the rig by φ swings the offset pupil on an arc.
  ({double x, double y}) pupilAt(double a) =>
      (x: -eMeters * math.sin(a), y: eMeters * math.cos(a));

  /// Pinhole projection of a world point on the optical axis at depth [depth]
  /// to the sensor lateral coordinate (px), for the camera panned by [a].
  double sensorX(double a, double depth) {
    final p = pupilAt(a);
    final vx = 0 - p.x;
    final vy = depth - p.y;
    final dx = -math.sin(a), dy = math.cos(a); // optical axis
    final rx = math.cos(a), ry = math.sin(a); // sensor +x (right)
    final parallel = vx * dx + vy * dy;
    if (parallel.abs() < 1e-6) return 0;
    final perp = vx * rx + vy * ry;
    return fpx * perp / parallel;
  }

  /// Apparent on-sensor size (px) of a real object of [realSize] m at [depth] m.
  double apparentPx(double realSize, double depth) => fpx * realSize / depth;

  /// Illustrative sensitivity gain. At the panel's default distances the true
  /// pixel residual is small (the NPP is forgiving for a 5 m foreground), so we
  /// amplify it for a legible green→red spread across the e range. The real
  /// metric is the OpenCV pipeline (PR 9.4); this number is for teaching only.
  static const double _illustrativeGain = 8;

  double get residualPx {
    final a = panAmplitude;
    final dNear = sensorX(a, nearM) - sensorX(-a, nearM);
    final dFar = sensorX(a, farM) - sensorX(-a, farM);
    return (dNear - dFar).abs() * _illustrativeGain;
  }

  Color lightColor() {
    if (residualPx < greenPx) return const Color(0xFF2E7D32); // green
    if (residualPx < yellowPx) return const Color(0xFFF9A825); // amber
    return const Color(0xFFC62828); // red
  }

  String get stateLabel {
    if (eMm.abs() < 1) return 'EXACT — pupil on axis';
    return eMm < 0 ? 'Pupil too far BACK' : 'Pupil too far FORWARD';
  }

  String get directionLabel {
    if (eMm.abs() < 1) return 'no shift';
    return eMm < 0 ? 'slide FORWARD' : 'slide BACK';
  }
}

/// Top-down schematic (left 60%): fixed pan-axis cross, the offset pupil
/// swinging on its arc, the near/far targets sized to their true apparent ratio
/// and annotated with their *distances*. Lateral offsets are exaggerated.
class _BirdsEyePainter extends CustomPainter {
  _BirdsEyePainter({required this.scene, required this.cs});

  final _ParallaxScene scene;
  final ColorScheme cs;

  static const double _eVisualScale = 4200; // px per metre of lateral offset

  @override
  void paint(Canvas canvas, Size size) {
    // Pivot lifted off the bottom edge so the "camera" label clears the caption.
    final pivot = Offset(size.width / 2, size.height * 0.84);
    final fwdScale = (size.height * 0.70) / scene.farM;

    Offset target(double depth) =>
        Offset(pivot.dx, pivot.dy - depth * fwdScale);
    final figurePt = target(scene.farM);
    final boardPt = target(scene.nearM);

    final p = scene.pupilAt(scene.phi);
    final pupil =
        Offset(pivot.dx + p.x * _eVisualScale, pivot.dy - p.y * fwdScale);

    final line = Paint()
      ..color = cs.primary.withValues(alpha: 0.8)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    canvas.drawLine(pupil, boardPt, line);
    canvas.drawLine(pupil, figurePt, line);

    // Pan-axis cross (fixed pivot = camera).
    final axis = Paint()
      ..color = cs.onSurface.withValues(alpha: 0.3)
      ..strokeWidth = 1.2;
    canvas.drawLine(
        pivot + const Offset(-7, 0), pivot + const Offset(7, 0), axis);
    canvas.drawLine(
        pivot + const Offset(0, -7), pivot + const Offset(0, 7), axis);

    // Targets, sized to their true apparent ratio (figure taller than board).
    final figApp = scene.apparentPx(scene.figureHeightM, scene.farM);
    final boardApp = scene.apparentPx(scene.boardWidthM, scene.nearM);
    const figIcon = 38.0;
    final boardIcon = (figIcon * boardApp / figApp).clamp(14.0, figIcon);
    _paintPerson(canvas, figurePt, figIcon, cs.tertiary);
    _paintChessboard(canvas, boardPt, boardIcon, scene.lightColor(), n: 5);

    canvas.drawCircle(pupil, 5, Paint()..color = cs.primary);
    canvas.drawCircle(
        pupil,
        5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = cs.surface);

    // Distance annotations (this is the depth diagram → label distances here).
    _paintLabel(canvas, size, 'figure — ${scene.farM.toStringAsFixed(0)} m',
        figurePt + Offset(figIcon * 0.6, -4), cs,
        bold: true);
    _paintLabel(
        canvas,
        size,
        'chessboard — ${scene.nearM.toStringAsFixed(0)} m',
        boardPt + Offset(boardIcon * 0.6 + 4, -4),
        cs,
        bold: true);
    _paintLabel(canvas, size, 'camera', pivot + const Offset(10, -2), cs,
        bold: true, alpha: 0.65);
    _paintCaption(canvas, size, 'schematic — lateral offset exaggerated', cs);
  }

  @override
  bool shouldRepaint(covariant _BirdsEyePainter old) => true;
}

/// Nodal-point loupe (right 40%): magnified close-up of the pan-axis region —
/// a fixed cross, the optical-axis line rotating with the pan, and the entrance
/// pupil sliding *along* it by `e`. Pan → the pupil orbits the cross; change `e`
/// → it slides fore/aft. Both degrees of freedom made visible; on axis it sits
/// dead-centre.
class _NodalLoupePainter extends CustomPainter {
  _NodalLoupePainter({required this.scene, required this.cs});

  final _ParallaxScene scene;
  final ColorScheme cs;

  static const double _loupeEScale = 650; // px per metre, magnified

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width / 2, size.height / 2) - 22;
    final c = Offset(size.width / 2, (size.height - 26) / 2);

    canvas.drawCircle(c, r, Paint()..color = cs.surface);
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));

    final phi = scene.phi;
    final sdir = Offset(-math.sin(phi), -math.cos(phi)); // optical axis, screen

    canvas.drawLine(
        c - sdir * r,
        c + sdir * r,
        Paint()
          ..color = cs.primary.withValues(alpha: 0.45)
          ..strokeWidth = 1.2);

    final cross = Paint()
      ..color = cs.onSurface.withValues(alpha: 0.55)
      ..strokeWidth = 1.4;
    canvas.drawLine(c + const Offset(-8, 0), c + const Offset(8, 0), cross);
    canvas.drawLine(c + const Offset(0, -8), c + const Offset(0, 8), cross);

    final off = (scene.eMeters * _loupeEScale).clamp(-r + 10, r - 10);
    final pupil = c + sdir * off;
    if (off.abs() > 1) {
      final arrow = Paint()
        ..color = cs.primary
        ..strokeWidth = 1.6;
      canvas.drawLine(c, pupil, arrow);
      final back = off >= 0 ? -1.0 : 1.0;
      final n = Offset(-sdir.dy, sdir.dx);
      canvas.drawLine(pupil, pupil + sdir * back * 5 + n * 3, arrow);
      canvas.drawLine(pupil, pupil + sdir * back * 5 - n * 3, arrow);
    }
    canvas.drawCircle(pupil, 4, Paint()..color = cs.primary);
    canvas.restore();

    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = cs.outline);
    _paintLabel(canvas, size, 'ΔY = ${scene.eMm.toStringAsFixed(0)} mm',
        Offset(0, size.height - 24), cs,
        center: true, fontSize: 11, bold: true);
    _paintLabel(canvas, size, 'nodal point · rail offset',
        Offset(0, size.height - 12), cs,
        center: true, fontSize: 9, alpha: 0.6);
  }

  @override
  bool shouldRepaint(covariant _NodalLoupePainter old) => true;
}

/// The resulting frame (left 60%): far figure + near chessboard, each sized to
/// its true apparent dimension, with the **figure axis** drawn as a fat black
/// reference line. Both shift with the pan; the chessboard's *relative* drift is
/// amplified. Locked (green) when the pupil is on axis.
class _ViewfinderPainter extends CustomPainter {
  _ViewfinderPainter({required this.scene, required this.cs});

  final _ParallaxScene scene;
  final ColorScheme cs;

  static const double _panScale = 0.42; // sensor-px → screen-px for shared pan
  static const double _driftExaggeration = 7;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;

    final figApp = scene.apparentPx(scene.figureHeightM, scene.farM);
    final boardApp = scene.apparentPx(scene.boardWidthM, scene.nearM);
    final fit = (size.height * 0.56) / figApp;
    final figH = figApp * fit;
    final boardW = boardApp * fit;

    final yFig = size.height * 0.44;
    final yBoard = size.height * 0.68;

    final sFar = scene.sensorX(scene.phi, scene.farM);
    final sNear = scene.sensorX(scene.phi, scene.nearM);
    final baseX =
        (sFar * _panScale).clamp(-size.width / 2 + 28, size.width / 2 - 28);
    final relPx = (sNear - sFar) * _panScale * _driftExaggeration;

    final figX = center + baseX;
    final boardX = (center + baseX + relPx).clamp(22.0, size.width - 22);
    final light = scene.lightColor();

    // The figure axis — a fat, high-contrast reference line (the background the
    // homography aligns to). onSurface = black on a light theme.
    canvas.drawLine(
        Offset(figX, 6),
        Offset(figX, size.height - 16),
        Paint()
          ..color = cs.onSurface
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
    _paintLabel(canvas, size, 'figure axis', Offset(figX + 5, 4), cs,
        fontSize: 9);

    // Residual arrow figure-axis → drifted chessboard.
    if ((boardX - figX).abs() > 1.5) {
      final arrow = Paint()
        ..color = light
        ..strokeWidth = 1.6;
      canvas.drawLine(Offset(figX, yBoard), Offset(boardX, yBoard), arrow);
      final dir = boardX >= figX ? 1 : -1;
      canvas.drawLine(Offset(boardX, yBoard),
          Offset(boardX - dir * 5, yBoard - 3), arrow);
      canvas.drawLine(Offset(boardX, yBoard),
          Offset(boardX - dir * 5, yBoard + 3), arrow);
    }

    _paintPerson(canvas, Offset(figX, yFig), figH, cs.tertiary);
    _paintChessboard(canvas, Offset(boardX, yBoard), boardW, light, n: 5);

    // Dimension annotations (apparent-size view → label sizes, not distances).
    _paintLabel(
        canvas,
        size,
        '${scene.figureHeightM.toStringAsFixed(0)} m tall',
        Offset(figX - figH * 0.5 - 2, yFig - figH * 0.5),
        cs,
        fontSize: 9);
    _paintLabel(
        canvas,
        size,
        '${(scene.boardWidthM * 100).toStringAsFixed(0)} cm wide',
        Offset(boardX + boardW * 0.5 + 2, yBoard - 6),
        cs,
        fontSize: 9);

    _paintCaption(
        canvas,
        size,
        scene.residualPx < scene.greenPx
            ? 'chessboard locked on figure axis'
            : 'chessboard drifts — relative motion exaggerated',
        cs);
  }

  @override
  bool shouldRepaint(covariant _ViewfinderPainter old) => true;
}

/// Chessboard-vs-figure loupe (right 40%): the fat black **figure axis** as a
/// fixed reference, with a magnified chessboard patch sliding across it by the
/// parallax shift. Centred on the axis at e = 0 (locked); off it when wrong.
class _BoardLoupePainter extends CustomPainter {
  _BoardLoupePainter({required this.scene, required this.cs});

  final _ParallaxScene scene;
  final ColorScheme cs;

  static const double _boardLoupeMag = 20;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width / 2, size.height / 2) - 16;
    final c = Offset(size.width / 2, (size.height - 14) / 2);
    final light = scene.lightColor();

    canvas.drawCircle(c, r, Paint()..color = cs.surface);
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));

    // Figure axis — fat black reference line.
    canvas.drawLine(
        Offset(c.dx, c.dy - r),
        Offset(c.dx, c.dy + r),
        Paint()
          ..color = cs.onSurface
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);

    final rel = scene.sensorX(scene.phi, scene.nearM) -
        scene.sensorX(scene.phi, scene.farM);
    final board = r * 0.7;
    final shift = (rel * _boardLoupeMag).clamp(-r + board / 2, r - board / 2);
    _paintChessboard(canvas, Offset(c.dx + shift, c.dy), board, light, n: 5);
    canvas.restore();

    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = cs.outline);
    _paintLabel(canvas, size, 'chessboard vs figure axis',
        Offset(0, size.height - 12), cs,
        center: true, fontSize: 9);
  }

  @override
  bool shouldRepaint(covariant _BoardLoupePainter old) => true;
}

// ── Shared painters ──────────────────────────────────────────────────────────

/// A simple, recognizable standing person (head, torso, arms, legs), [h] tall,
/// centred on [center].
void _paintPerson(Canvas canvas, Offset center, double h, Color color) {
  final cx = center.dx;
  final top = center.dy - h / 2;
  final bottom = center.dy + h / 2;
  final headR = h * 0.11;
  final stroke = Paint()
    ..color = color
    ..strokeWidth = math.max(2, h * 0.06)
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;

  canvas.drawCircle(Offset(cx, top + headR), headR, Paint()..color = color);
  final neckY = top + 2 * headR;
  final hipY = top + h * 0.60;
  canvas.drawLine(Offset(cx, neckY), Offset(cx, hipY), stroke); // torso
  final shoulderY = neckY + h * 0.05;
  canvas.drawLine(Offset(cx, shoulderY),
      Offset(cx - h * 0.20, hipY - h * 0.05), stroke); // arms
  canvas.drawLine(
      Offset(cx, shoulderY), Offset(cx + h * 0.20, hipY - h * 0.05), stroke);
  canvas.drawLine(
      Offset(cx, hipY), Offset(cx - h * 0.14, bottom), stroke); // legs
  canvas.drawLine(Offset(cx, hipY), Offset(cx + h * 0.14, bottom), stroke);
}

/// An [n]×[n] checker square of side [size], centred on [center].
void _paintChessboard(Canvas canvas, Offset center, double size, Color color,
    {int n = 6}) {
  final left = center.dx - size / 2;
  final top = center.dy - size / 2;
  final cell = size / n;
  final fill = Paint()..color = color;
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if ((r + c).isEven) {
        canvas.drawRect(
            Rect.fromLTWH(left + c * cell, top + r * cell, cell, cell), fill);
      }
    }
  }
  canvas.drawRect(
      Rect.fromLTWH(left, top, size, size),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color);
}

void _paintLabel(Canvas canvas, Size size, String text, Offset at, ColorScheme cs,
    {double fontSize = 10,
    bool center = false,
    bool bold = false,
    double alpha = 0.72}) {
  final tp = TextPainter(
    text: TextSpan(
        text: text,
        style: TextStyle(
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            color: cs.onSurface.withValues(alpha: alpha))),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: size.width);
  var dx = center ? (size.width - tp.width) / 2 : at.dx;
  if (dx + tp.width > size.width) dx = size.width - tp.width - 2;
  if (dx < 2) dx = 2;
  tp.paint(canvas, Offset(dx, at.dy));
}

void _paintCaption(Canvas canvas, Size size, String text, ColorScheme cs) {
  final tp = TextPainter(
    text: TextSpan(
        text: text,
        style: TextStyle(
            fontSize: 9,
            fontStyle: FontStyle.italic,
            color: cs.onSurface.withValues(alpha: 0.45))),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: size.width);
  tp.paint(canvas, Offset(8, size.height - tp.height - 4));
}
