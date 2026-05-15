import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../state/gimbal_connection.dart';

/// 3D visualization of the gimbal's current orientation. A wireframe
/// world-fixed sphere acts as a spatial reference; inside it sits an
/// abstract camera body (rectangular wireframe + short lens cylinder)
/// plus an RGB axis triad attached to the body frame (X=red, Y=green,
/// Z=blue, with Z pointing out of the lens).
///
/// Connection-agnostic — driven only by `GimbalConnection`'s
/// `(yawDeg, pitchDeg, rollDeg)`. Works the same for the real BLE
/// transport and the demo simulator. Identity orientation while the
/// connection state is still null (first ~100 ms after connect).
///
/// Rendering: pure-Dart `CustomPainter` + `vector_math_64`. No shading,
/// no z-sort — wireframe is enough to read the pose. The widget runs a
/// `Ticker` that exponentially smooths the displayed orientation toward
/// the latest pushed values (~100 ms time constant) so the ~10 Hz
/// GIMBAL_STATE cadence renders as smooth motion at display refresh
/// rate.
class GimbalVisualization extends ConsumerStatefulWidget {
  const GimbalVisualization({super.key});

  @override
  ConsumerState<GimbalVisualization> createState() =>
      _GimbalVisualizationState();
}

class _GimbalVisualizationState extends ConsumerState<GimbalVisualization>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  // Smoothed display orientation (degrees).
  double _smoothYaw = 0.0;
  double _smoothPitch = 0.0;
  double _smoothRoll = 0.0;

  // Latest reported orientation, updated each `build`.
  double _targetYaw = 0.0;
  double _targetPitch = 0.0;
  double _targetRoll = 0.0;

  Duration _lastTickAt = Duration.zero;

  /// Exponential-smoothing time constant in seconds.
  /// `α = 1 - exp(-dt/τ)`; with τ=50ms, smooth reaches ~95 % of target
  /// in ~150 ms — visually tight to the spec's "~100 ms" call.
  static const _smoothingTauSeconds = 0.05;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTickAt).inMicroseconds / 1e6;
    _lastTickAt = elapsed;
    if (dt <= 0 || dt > 1.0) return; // skip first tick / huge gaps

    final alpha = 1.0 - exp(-dt / _smoothingTauSeconds);
    setState(() {
      _smoothYaw += _shortestAngleDiff(_targetYaw, _smoothYaw) * alpha;
      _smoothPitch += (_targetPitch - _smoothPitch) * alpha;
      _smoothRoll += (_targetRoll - _smoothRoll) * alpha;
    });
  }

  /// Shortest signed angular distance from `b` to `a`, handling
  /// wraparound. Without this, a yaw jump from +179° → -179° would
  /// animate the long way around (358°) instead of the short way (2°).
  static double _shortestAngleDiff(double a, double b) {
    double d = a - b;
    while (d > 180) {
      d -= 360;
    }
    while (d < -180) {
      d += 360;
    }
    return d;
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(gimbalConnectionProvider);
    _targetYaw = conn.yawDeg ?? 0.0;
    _targetPitch = conn.pitchDeg ?? 0.0;
    _targetRoll = conn.rollDeg ?? 0.0;

    final theme = Theme.of(context);
    return CustomPaint(
      painter: _GimbalPainter(
        yawDeg: _smoothYaw,
        pitchDeg: _smoothPitch,
        rollDeg: _smoothRoll,
        bg: theme.colorScheme.surfaceContainerLowest,
        sphereColor:
            theme.colorScheme.onSurface.withValues(alpha: 0.18),
        bodyColor: theme.colorScheme.onSurface,
      ),
      size: Size.infinite,
    );
  }
}

class _GimbalPainter extends CustomPainter {
  _GimbalPainter({
    required this.yawDeg,
    required this.pitchDeg,
    required this.rollDeg,
    required this.bg,
    required this.sphereColor,
    required this.bodyColor,
  });

  final double yawDeg;
  final double pitchDeg;
  final double rollDeg;
  final Color bg;
  final Color sphereColor;
  final Color bodyColor;

  // --- Scene geometry (unitless, scaled to widget size at paint time).
  // Sphere radius = 1.0. Camera body fits inside; axes extend just past
  // the sphere so they read clearly.

  static const _bodyHalfX = 0.175;
  static const _bodyHalfY = 0.125;
  static const _bodyHalfZ = 0.225;

  static const _lensZNear = _bodyHalfZ;
  static const _lensZFar = 0.55;
  static const _lensRadius = 0.10;

  static const _axisLenXY = 0.55;
  static const _axisLenZ = 0.75;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    final cx = size.width / 2;
    final cy = size.height / 2;
    final scale = min(size.width, size.height) * 0.40;

    // Body rotation from gimbal Euler angles.
    final bodyRot = vm.Matrix4.identity()
      ..rotateY(_deg2rad(yawDeg))
      ..rotateX(_deg2rad(pitchDeg))
      ..rotateZ(_deg2rad(rollDeg));

    // Fixed viewing transform so the scene reads as 3D — slight pitch
    // down + slight yaw right, like looking at the gimbal from over
    // the user's right shoulder.
    final viewRot = vm.Matrix4.identity()
      ..rotateX(-0.40)
      ..rotateY(0.35);

    Offset project(vm.Vector3 v) {
      final viewed = viewRot.transformed3(v);
      // y is flipped because Flutter canvas has +y going down.
      return Offset(cx + viewed.x * scale, cy - viewed.y * scale);
    }

    Offset projectBody(vm.Vector3 v) =>
        project(bodyRot.transformed3(v));

    _drawSphere(canvas, project);
    _drawBody(canvas, projectBody);
    _drawLens(canvas, projectBody);
    _drawAxes(canvas, projectBody);
  }

  void _drawSphere(Canvas canvas, Offset Function(vm.Vector3) project) {
    final paint = Paint()
      ..color = sphereColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Latitude circles (constant y).
    for (final latDeg in const [-60, -30, 0, 30, 60]) {
      final lat = _deg2rad(latDeg.toDouble());
      final y = sin(lat);
      final r = cos(lat);
      _drawPolyline(canvas, paint, 64,
          (t) => vm.Vector3(r * cos(t), y, r * sin(t)), project);
    }

    // Meridians (great circles through ±Y).
    for (final lonDeg in const [0, 45, 90, 135]) {
      final lon = _deg2rad(lonDeg.toDouble());
      _drawPolyline(
        canvas,
        paint,
        64,
        (t) => vm.Vector3(cos(t) * cos(lon), sin(t), cos(t) * sin(lon)),
        project,
      );
    }
  }

  void _drawBody(Canvas canvas, Offset Function(vm.Vector3) projectBody) {
    final paint = Paint()
      ..color = bodyColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    const sx = _bodyHalfX;
    const sy = _bodyHalfY;
    const sz = _bodyHalfZ;
    final v = <vm.Vector3>[
      vm.Vector3(-sx, -sy, -sz),
      vm.Vector3(sx, -sy, -sz),
      vm.Vector3(sx, sy, -sz),
      vm.Vector3(-sx, sy, -sz),
      vm.Vector3(-sx, -sy, sz),
      vm.Vector3(sx, -sy, sz),
      vm.Vector3(sx, sy, sz),
      vm.Vector3(-sx, sy, sz),
    ];
    const edges = <List<int>>[
      [0, 1], [1, 2], [2, 3], [3, 0], // back face (−z)
      [4, 5], [5, 6], [6, 7], [7, 4], // front face (+z)
      [0, 4], [1, 5], [2, 6], [3, 7], // connectors
    ];
    for (final e in edges) {
      canvas.drawLine(projectBody(v[e[0]]), projectBody(v[e[1]]), paint);
    }
  }

  void _drawLens(Canvas canvas, Offset Function(vm.Vector3) projectBody) {
    final paint = Paint()
      ..color = bodyColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    // Two circles at the lens's near (body front face) and far (tip).
    for (final z in const [_lensZNear, _lensZFar]) {
      _drawPolyline(
        canvas,
        paint,
        32,
        (t) => vm.Vector3(_lensRadius * cos(t), _lensRadius * sin(t), z),
        projectBody,
      );
    }
    // Four longitudinal lines connecting near→far at 0°, 90°, 180°, 270°.
    for (int i = 0; i < 4; i++) {
      final t = i / 4.0 * 2 * pi;
      final c = cos(t);
      final s = sin(t);
      final near =
          vm.Vector3(_lensRadius * c, _lensRadius * s, _lensZNear);
      final far =
          vm.Vector3(_lensRadius * c, _lensRadius * s, _lensZFar);
      canvas.drawLine(projectBody(near), projectBody(far), paint);
    }
  }

  void _drawAxes(Canvas canvas, Offset Function(vm.Vector3) projectBody) {
    void drawAxis(vm.Vector3 dir, Color color, String label) {
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      final origin = projectBody(vm.Vector3.zero());
      final tip = projectBody(dir);
      canvas.drawLine(origin, tip, paint);
      // Solid disc at the tip as a simple arrowhead.
      canvas.drawCircle(tip, 3.5, Paint()..color = color);
      // Axis label just past the tip.
      _drawText(canvas, label, tip, color);
    }

    drawAxis(vm.Vector3(_axisLenXY, 0, 0), Colors.red.shade400, 'X');
    drawAxis(vm.Vector3(0, _axisLenXY, 0), Colors.green.shade500, 'Y');
    drawAxis(vm.Vector3(0, 0, _axisLenZ), Colors.blue.shade400, 'Z');
  }

  /// Helper: sample `segments+1` points on a parametric curve [0, 2π]
  /// and draw the resulting polyline. The curve closes (segment 0 and
  /// segment N coincide).
  void _drawPolyline(
    Canvas canvas,
    Paint paint,
    int segments,
    vm.Vector3 Function(double t) curve,
    Offset Function(vm.Vector3) project,
  ) {
    final path = Path();
    for (int i = 0; i <= segments; i++) {
      final t = i / segments * 2 * pi;
      final p = project(curve(t));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path, paint);
  }

  void _drawText(Canvas canvas, String text, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at + const Offset(4, -6));
  }

  static double _deg2rad(double d) => d * pi / 180.0;

  @override
  bool shouldRepaint(_GimbalPainter old) =>
      old.yawDeg != yawDeg ||
      old.pitchDeg != pitchDeg ||
      old.rollDeg != rollDeg ||
      old.bg != bg ||
      old.sphereColor != sphereColor ||
      old.bodyColor != bodyColor;
}
