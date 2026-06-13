import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shared `CustomPainter` glyphs for the parallax explainers (PR 9.1 + 9.1b),
/// so the "Problem" (NPP physics) and "Solution" (CV pipeline) animations draw
/// the same figure and chessboard.

/// A simple, recognizable standing person (head, torso, arms, legs), [h] tall,
/// centred on [center].
void paintPerson(Canvas canvas, Offset center, double h, Color color) {
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
void paintChessboard(Canvas canvas, Offset center, double size, Color color,
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

/// Small label text, clamped within [size]. [center] horizontally centres it.
void paintLabel(Canvas canvas, Size size, String text, Offset at, ColorScheme cs,
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

/// Italic caption pinned to the bottom-left of the panel.
void paintCaption(Canvas canvas, Size size, String text, ColorScheme cs) {
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
