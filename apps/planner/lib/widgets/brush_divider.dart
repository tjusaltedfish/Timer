import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class BrushDivider extends StatelessWidget {
  const BrushDivider({super.key, this.width = 48});
  final double width;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: width,
      height: 8,
      child: CustomPaint(painter: _Brush(context.inkPalette.inkZhong)),
    ),
  );
}

class _Brush extends CustomPainter {
  _Brush(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < 48; i++) {
      final t = i / 48;
      canvas.drawLine(
        Offset(t * size.width, size.height / 2),
        Offset((i + 1) / 48 * size.width, size.height / 2),
        Paint()
          ..color = color
          ..strokeWidth = .3 + 1.2 * math.sin(math.pi * t),
      );
    }
  }

  @override
  bool shouldRepaint(_Brush old) => color != old.color;
}
