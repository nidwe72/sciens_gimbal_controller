import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'parallax_glyphs.dart';

/// PR 9.1b — the metric-pipeline explainer ("Solution" tab).
///
/// A pure-Flutter, CV-free staged animation of how the calibration metric is
/// computed from two panned photos. Two-level stepping:
///
///   main steps  = the three rail cases: Too far back, Correct, Too far forward
///   sub-steps   = the CV stages applied within each case:
///                   Capture, Detect (YOLO), Mask (GrabCut),
///                   Find points (SIFT + chessboard corners), Match + homography
///
/// It depicts the truthful asymmetry — figure: YOLO box, GrabCut mask, SIFT
/// keypoints, fit homography H; chessboard: corners found directly (no
/// YOLO/GrabCut/SIFT). Applying H to the board corners leaves a residual that
/// is large+opposite for the two wrong cases and ~0 for Correct — tying back to
/// the "Problem" tab.
///
/// Controls: Play/Pause, prev/next (sub-step), fast-back/fast-forward (main
/// step). No camera/gimbal/OpenCV — `CustomPainter` + `AnimationController`,
/// reusing the shared glyphs. YOLO is shown as the intended auto-detect even
/// though v1 wires a manual box (YOLO is deferred to Phase 9b).
class ParallaxPipelineExplainer extends StatefulWidget {
  const ParallaxPipelineExplainer({super.key});

  @override
  State<ParallaxPipelineExplainer> createState() =>
      _ParallaxPipelineExplainerState();
}

class _ParallaxPipelineExplainerState extends State<ParallaxPipelineExplainer>
    with SingleTickerProviderStateMixin {
  static const _cases = ['Too far back', 'Correct (NPP)', 'Too far forward'];
  static const _caseNotes = [
    'Pupil behind the axis; the board lags the figure.',
    'Pupil on the axis; the board locks to the figure.',
    'Pupil ahead of the axis; the board leads the figure.',
  ];
  static const _algos = [
    'Capture',
    'Detect figure (YOLO)',
    'Mask figure (GrabCut)',
    'Find points (SIFT + corners)',
    'Match + homography',
  ];
  static const _descs = [
    'Two frames, panned a few degrees apart.',
    'YOLO finds the figure — the far background reference.',
    'GrabCut isolates the figure from its surroundings.',
    'SIFT keypoints land on the figure; the chessboard corners are found '
        'directly — no YOLO, GrabCut or SIFT.',
    'Figure keypoints matched between A and B fit a homography; applied to the '
        'board corners, the leftover gap is the parallax residual.',
  ];

  static const _nCases = 3;
  static const _nSub = 5;

  late final AnimationController _controller;
  bool _auto = true;
  int _case = 0; // 0..2
  int _sub = 0; // 0..4

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 30))
          ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // (case 0..2, sub 0..4, local 0..1).
  (int, int, double) _frameInfo() {
    if (!_auto) return (_case, _sub, 1.0);
    final total = _nCases * _nSub;
    final f = (_controller.value * total).clamp(0.0, total - 0.0001);
    final idx = f.floor();
    return (idx ~/ _nSub, idx % _nSub, f - idx);
  }

  void _grabManual() {
    final (cc, ss, _) = _frameInfo();
    _case = cc;
    _sub = ss;
    _auto = false;
    _controller.stop();
  }

  void _togglePlay() => setState(() {
        if (_auto) {
          _grabManual();
        } else {
          _auto = true;
          _controller
            ..value = (_case * _nSub + _sub) / (_nCases * _nSub)
            ..repeat();
        }
      });

  void _stepSub(int d) => setState(() {
        _grabManual();
        _sub = (_sub + d).clamp(0, _nSub - 1);
      });

  void _stepCase(int d) => setState(() {
        _grabManual();
        _case = (_case + d).clamp(0, _nCases - 1); // keep _sub for comparison
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('How the metric is computed',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                'Two photos become one residual in pixels. The figure drives the '
                'homography; the chessboard is the ruler it is tested against.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 12),
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final (cc, ss, local) = _frameInfo();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: cs.outlineVariant),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: SizedBox(
                          height: 290,
                          child: CustomPaint(
                            painter: _PipelinePainter(
                                useCase: cc,
                                stage: ss + 1,
                                local: local,
                                cs: cs),
                            size: Size.infinite,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _caseChips(theme, cc),
                      SizedBox(
                        height: 30,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(_caseNotes[cc],
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurface.withValues(alpha: 0.7),
                              )),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _segBar(theme, ss, _nSub),
                      const SizedBox(height: 4),
                      Text('Step ${ss + 1}/$_nSub — ${_algos[ss]}',
                          style: theme.textTheme.labelLarge),
                      SizedBox(
                        height: 46,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(_descs[ss],
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurface.withValues(alpha: 0.8),
                              )),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 4),
              _controls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    final (cc, ss, _) = _frameInfo();
    final canPrev = _auto || ss > 0;
    final canNext = _auto || ss < _nSub - 1;
    final canBack = _auto || cc > 0;
    final canFwd = _auto || cc < _nCases - 1;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Previous case',
          icon: const Icon(Icons.fast_rewind),
          onPressed: canBack ? () => _stepCase(-1) : null,
        ),
        IconButton(
          tooltip: 'Previous step',
          icon: const Icon(Icons.skip_previous),
          onPressed: canPrev ? () => _stepSub(-1) : null,
        ),
        IconButton.filledTonal(
          tooltip: _auto ? 'Pause' : 'Play',
          icon: Icon(_auto ? Icons.pause : Icons.play_arrow),
          onPressed: _togglePlay,
        ),
        IconButton(
          tooltip: 'Next step',
          icon: const Icon(Icons.skip_next),
          onPressed: canNext ? () => _stepSub(1) : null,
        ),
        IconButton(
          tooltip: 'Next case',
          icon: const Icon(Icons.fast_forward),
          onPressed: canFwd ? () => _stepCase(1) : null,
        ),
      ],
    );
  }

  Widget _caseChips(ThemeData theme, int current) {
    final cs = theme.colorScheme;
    return Row(
      children: List.generate(_nCases, (i) {
        final active = i == current;
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(right: i < _nCases - 1 ? 6 : 0),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            decoration: BoxDecoration(
              color: active ? cs.primary : cs.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: active ? cs.primary : cs.outlineVariant),
            ),
            child: Text(
              _cases[i],
              textAlign: TextAlign.center,
              maxLines: 2,
              style: TextStyle(
                fontSize: 11,
                height: 1.05,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                color: active ? cs.onPrimary : cs.onSurface,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _segBar(ThemeData theme, int current, int n) {
    final cs = theme.colorScheme;
    return Row(
      children: List.generate(n, (i) {
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(right: i < n - 1 ? 6 : 0),
            height: 4,
            decoration: BoxDecoration(
              color: i <= current ? cs.primary : cs.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }
}

class _PipelinePainter extends CustomPainter {
  _PipelinePainter({
    required this.useCase,
    required this.stage,
    required this.local,
    required this.cs,
  });

  final int useCase; // 0 back · 1 correct · 2 forward
  final int stage; // 1..5 (cumulative)
  final double local; // 0..1 within the current stage
  final ColorScheme cs;

  static const Color _amber = Color(0xFFF9A825);
  static const Color _green = Color(0xFF2E7D32);

  // Figure keypoint offsets, in figure-height units (figure spans ±0.5).
  static const List<Offset> _kp = [
    Offset(0, -0.42),
    Offset(-0.16, -0.22),
    Offset(0.16, -0.22),
    Offset(0, -0.05),
    Offset(-0.12, 0.16),
    Offset(0.12, 0.16),
    Offset(-0.10, 0.40),
    Offset(0.10, 0.40),
    Offset(0, 0.28),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 22.0;
    final frameW = (size.width - gap) / 2;
    final frameH = size.height;
    final rectA = Rect.fromLTWH(0, 0, frameW, frameH);
    final rectB = Rect.fromLTWH(frameW + gap, 0, frameW, frameH);

    final s = frameW * 0.13; // pan shift (both move left in B)
    final pMag = frameW * 0.12; // extra board parallax magnitude
    final p = useCase == 0 ? pMag : (useCase == 2 ? -pMag : 0.0);

    final figH = frameH * 0.40;
    final boardSz = frameH * 0.20;
    final figY = frameH * 0.36;
    final boardY = frameH * 0.66;

    final figA = Offset(rectA.left + frameW * 0.5, figY);
    final figB = Offset(rectB.left + frameW * 0.5 - s, figY);
    final boardA = Offset(rectA.left + frameW * 0.5, boardY);
    final boardBact = Offset(rectB.left + frameW * 0.5 - s - p, boardY);
    final boardBpred = Offset(rectB.left + frameW * 0.5 - s, boardY);

    _drawFrame(canvas, size, rectA, figA, boardA, figH, boardSz, 'A · pan left');
    _drawFrame(
        canvas, size, rectB, figB, boardBact, figH, boardSz, 'B · pan right');

    if (stage >= 5) {
      _drawMatchAndResidual(
          canvas, size, figA, figB, figH, boardBact, boardBpred, boardSz);
    }
  }

  void _drawFrame(Canvas canvas, Size panel, Rect r, Offset fig, Offset board,
      double figH, double boardSz, String tag) {
    canvas.save();
    canvas.clipRect(r);
    canvas.drawRect(r, Paint()..color = cs.surface);

    paintChessboard(canvas, board, boardSz, cs.secondary, n: 5);
    paintPerson(canvas, fig, figH, cs.tertiary);

    // Stage 3 — GrabCut: fade the surroundings, keep the figure crisp.
    if (stage >= 3) {
      final a = (stage == 3 ? local : 1.0) * 0.72;
      canvas.drawRect(r, Paint()..color = cs.surface.withValues(alpha: a));
      paintPerson(canvas, fig, figH, cs.tertiary);
      final mask = Rect.fromCenter(
          center: fig, width: figH * 0.52, height: figH * 1.04);
      canvas.drawRRect(
          RRect.fromRectAndRadius(mask, const Radius.circular(6)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = cs.tertiary.withValues(alpha: 0.8));
    }

    // Stage 4 — points: board returns (its own corner finder) + keypoints.
    if (stage >= 4) {
      final reveal = stage == 4 ? local : 1.0;
      paintChessboard(canvas, board, boardSz, cs.secondary, n: 5);
      _drawBoardCorners(canvas, board, boardSz, reveal);
      _drawKeypoints(canvas, fig, figH, reveal);
    }

    // Stage 2 — YOLO box (drawn last, on top).
    if (stage >= 2) {
      final grow = stage == 2 ? local : 1.0;
      final box =
          Rect.fromCenter(center: fig, width: figH * 0.52, height: figH * 1.06);
      canvas.drawRect(
          box,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = cs.primary.withValues(alpha: 0.35 + 0.65 * grow));
      paintLabel(canvas, panel, 'figure 0.96', Offset(box.left, box.top - 12),
          cs,
          fontSize: 9, bold: true, alpha: 0.9);
    }

    canvas.drawRect(
        r.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = cs.outlineVariant);
    paintLabel(canvas, panel, tag, Offset(r.left + 6, r.top + 4), cs,
        fontSize: 9, alpha: 0.6);

    canvas.restore();
  }

  void _drawKeypoints(Canvas c, Offset fig, double figH, double reveal) {
    final n = (_kp.length * reveal).ceil().clamp(0, _kp.length);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = cs.primary;
    for (var i = 0; i < n; i++) {
      final pos = fig + Offset(_kp[i].dx * figH, _kp[i].dy * figH);
      c.drawCircle(pos, 3.2, stroke);
      final a = i * 0.8;
      c.drawLine(pos, pos + Offset(math.cos(a), math.sin(a)) * 4.5,
          Paint()
            ..color = cs.primary
            ..strokeWidth = 1.2);
    }
  }

  List<Offset> _corners(Offset center, double sz) => [
        center + Offset(-sz / 2, -sz / 2),
        center + Offset(sz / 2, -sz / 2),
        center + Offset(sz / 2, sz / 2),
        center + Offset(-sz / 2, sz / 2),
      ];

  void _drawBoardCorners(Canvas c, Offset board, double sz, double reveal) {
    final cor = _corners(board, sz);
    final n = (cor.length * reveal).ceil().clamp(0, cor.length);
    for (var i = 0; i < n; i++) {
      c.drawCircle(cor[i], 3.4, Paint()..color = cs.secondary);
      c.drawCircle(
          cor[i],
          3.4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = cs.onSurface.withValues(alpha: 0.7));
    }
  }

  void _drawMatchAndResidual(Canvas c, Size panel, Offset figA, Offset figB,
      double figH, Offset boardBact, Offset boardBpred, double boardSz) {
    final shown = (_kp.length * local).ceil().clamp(0, _kp.length);
    final mp = Paint()
      ..color = cs.primary.withValues(alpha: 0.55)
      ..strokeWidth = 1.0;
    for (var i = 0; i < shown; i++) {
      final a = figA + Offset(_kp[i].dx * figH, _kp[i].dy * figH);
      final b = figB + Offset(_kp[i].dx * figH, _kp[i].dy * figH);
      c.drawLine(a, b, mp);
    }
    if (local < 0.45) return;

    paintLabel(c, panel, 'figure aligned (H)',
        figB + Offset(-figH * 0.26, -figH * 0.66), cs,
        fontSize: 9, bold: true, alpha: 0.9);

    final locked = useCase == 1;
    if (locked) {
      // Board locks onto the figure axis — residual ~0.
      c.drawCircle(boardBact + Offset(0, boardSz * 0.85), 6,
          Paint()..color = _green);
      paintLabel(c, panel, 'residual 0 px · locked',
          boardBact + Offset(-boardSz * 0.7, boardSz * 0.95), cs,
          fontSize: 10, bold: true);
      return;
    }

    // Predicted (H applied) vs actual board corners → residual + direction.
    c.drawRect(
        Rect.fromCenter(center: boardBpred, width: boardSz, height: boardSz),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = cs.onSurface.withValues(alpha: 0.5));
    final pred = _corners(boardBpred, boardSz);
    final act = _corners(boardBact, boardSz);
    final ap = Paint()
      ..color = _amber
      ..strokeWidth = 1.8;
    for (var i = 0; i < 4; i++) {
      c.drawLine(pred[i], act[i], ap);
    }
    c.drawCircle(
        boardBact + Offset(0, boardSz * 0.85), 6, Paint()..color = _amber);
    final dir = useCase == 0 ? 'slide forward' : 'slide back';
    paintLabel(c, panel, 'residual ~14 px · $dir',
        boardBact + Offset(-boardSz * 0.9, boardSz * 0.95), cs,
        fontSize: 10, bold: true);
    paintLabel(c, panel, 'predicted vs actual',
        boardBpred + Offset(-boardSz * 0.55, -boardSz * 0.95), cs,
        fontSize: 8, alpha: 0.6);
  }

  @override
  bool shouldRepaint(covariant _PipelinePainter old) =>
      old.useCase != useCase || old.stage != stage || old.local != local;
}
