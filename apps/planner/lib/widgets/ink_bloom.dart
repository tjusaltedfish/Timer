import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One drop of ink that has spread into the paper.
@immutable
class BloomSpot {
  const BloomSpot(this.center, this.radius, this.alpha, {this.seed = 7});

  /// Center in fractions of the painted size (may lie outside 0..1).
  final Offset center;

  /// Radius in fractions of the painted width.
  final double radius;
  final double alpha;
  final int seed;
}

/// Paints soft, irregular ink washes with a faint darker "tide line", the way
/// sumi ink dries on absorbent paper. Purely decorative; never hit-tested.
class InkBloom extends StatelessWidget {
  const InkBloom({
    super.key,
    required this.spots,
    required this.color,
    this.spread = 1,
    this.maxRadius = 520,
  });
  final List<BloomSpot> spots;
  final Color color;
  final double spread, maxRadius;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: CustomPaint(
        painter: InkBloomPainter(
          spots: spots,
          color: color,
          spread: spread,
          maxRadius: maxRadius,
        ),
        size: Size.infinite,
      ),
    ),
  );
}

class InkBloomPainter extends CustomPainter {
  InkBloomPainter({
    required this.spots,
    required this.color,
    this.spread = 1,
    this.maxRadius = 520,
  });
  final List<BloomSpot> spots;
  final Color color;
  final double spread, maxRadius;

  Path _blob(Offset c, double r, math.Random random, double roughness) {
    final waves = [
      for (var i = 0; i < 4; i++)
        (
          k: 2 + random.nextInt(7),
          a: (.025 + random.nextDouble() * .05) * roughness,
          phase: random.nextDouble() * math.pi * 2,
        ),
    ];
    final path = Path();
    const steps = 96;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps * math.pi * 2;
      var scale = 1.0;
      for (final w in waves) {
        scale += w.a * math.sin(w.k * t + w.phase);
      }
      final point = c + Offset(math.cos(t), math.sin(t)) * (r * scale);
      i == 0
          ? path.moveTo(point.dx, point.dy)
          : path.lineTo(point.dx, point.dy);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || spread <= 0) return;
    for (final spot in spots) {
      final random = math.Random(spot.seed);
      final center = Offset(
        spot.center.dx * size.width,
        spot.center.dy * size.height,
      );
      final radius = math.min(spot.radius * size.width, maxRadius) * spread;
      if (radius < 2) continue;
      final alpha = spot.alpha * (.35 + .65 * spread.clamp(0.0, 1.0));
      // Body: several offset layers, densest near the drop point.
      for (var layer = 0; layer < 4; layer++) {
        final r = radius * (.42 + .2 * layer);
        final drift = Offset(
          (random.nextDouble() - .5) * r * .22,
          (random.nextDouble() - .5) * r * .22,
        );
        final path = _blob(center + drift, r, random, 1);
        canvas.drawPath(
          path,
          Paint()
            ..shader = RadialGradient(
              colors: [
                color.withValues(alpha: alpha * (.9 - layer * .15)),
                color.withValues(alpha: alpha * (.45 - layer * .07)),
                color.withValues(alpha: 0),
              ],
              stops: const [0, .55, 1],
            ).createShader(Rect.fromCircle(center: center + drift, radius: r))
            ..maskFilter = MaskFilter.blur(
              BlurStyle.normal,
              math.min(r * .16, 36),
            ),
        );
      }
      // Tide line: ink pigment gathers at the drying edge.
      final edge = _blob(center, radius * .93, random, 1.4);
      canvas.drawPath(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.2, radius * .035)
          ..color = color.withValues(alpha: alpha * .55)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            math.min(radius * .03, 10),
          ),
      );
      // A few feathered tendrils where the wash crept along paper fibres.
      for (var i = 0; i < 5; i++) {
        final angle = random.nextDouble() * math.pi * 2;
        final at =
            center +
            Offset(math.cos(angle), math.sin(angle)) *
                (radius * (.82 + random.nextDouble() * .2));
        final r = radius * (.08 + random.nextDouble() * .1);
        canvas.drawPath(
          _blob(at, r, random, 2),
          Paint()
            ..color = color.withValues(alpha: alpha * .5)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .45),
        );
      }
    }
  }

  @override
  bool shouldRepaint(InkBloomPainter old) =>
      old.spread != spread ||
      old.color != color ||
      old.maxRadius != maxRadius ||
      !identical(old.spots, spots);
}

/// A bloom that spreads outward once when [active] becomes true.
class SpreadingBloom extends StatelessWidget {
  const SpreadingBloom({
    super.key,
    required this.active,
    required this.spots,
    required this.color,
  });
  final bool active;
  final List<BloomSpot> spots;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: active ? 1 : 0),
      duration: still ? Duration.zero : const Duration(milliseconds: 680),
      curve: Curves.easeOutQuart,
      builder: (context, value, _) => value <= 0.01
          ? const SizedBox.shrink()
          : RepaintBoundary(
              child: InkBloom(spots: spots, color: color, spread: value),
            ),
    );
  }
}
