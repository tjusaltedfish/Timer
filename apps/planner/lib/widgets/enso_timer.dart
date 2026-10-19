import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class EnsoTimer extends StatelessWidget {
  const EnsoTimer({
    super.key,
    required this.elapsed,
    required this.planned,
    required this.remaining,
    this.paused = false,
  });
  final int elapsed, planned, remaining;
  final bool paused;
  @override
  Widget build(BuildContext context) {
    final seconds = remaining.abs();
    final label =
        '${remaining < 0 ? '+' : ''}${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Semantics(
      label:
          '${paused
              ? '已暂停'
              : remaining < 0
              ? '超时'
              : '剩余'} $label',
      child: SizedBox(
        width: 136,
        height: 136,
        child: CustomPaint(
          painter: _Enso(
            elapsed / math.max(planned, 1),
            paused,
            context.inkPalette,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'WenKai',
                    fontSize: 28,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: context.inkPalette.inkJiao,
                  ),
                ),
                Text(
                  paused
                      ? '已暂停'
                      : remaining < 0
                      ? '已超时'
                      : '剩余',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Enso extends CustomPainter {
  _Enso(this.progress, this.paused, this.p);
  final double progress;
  final bool paused;
  final InkPalette p;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(8, 8, size.width - 16, size.height - 16);
    void arc(double fraction, Color color, double start) {
      final segments = (fraction.clamp(0, 1) * 120).round();
      for (var i = 0; i < segments; i++) {
        final t = i / 120;
        canvas.drawArc(
          rect,
          start + t * math.pi * 1.95,
          math.pi * 1.95 / 120 + .002,
          false,
          Paint()
            ..color = color.withValues(alpha: .45 + .55 * (1 - t))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5 * (.55 + .45 * math.sin(math.pi * t)),
        );
      }
    }

    arc(1, p.inkQing, -math.pi / 2 + .07);
    arc(progress, paused ? p.inkDan : p.inkJiao, -math.pi / 2 + .07);
    if (progress > 1) arc(progress - 1, p.accent, -math.pi / 2 + .07);
  }

  @override
  bool shouldRepaint(_Enso old) =>
      progress != old.progress || paused != old.paused || p != old.p;
}
