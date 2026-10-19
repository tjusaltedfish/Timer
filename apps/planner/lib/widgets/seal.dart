import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class Seal extends StatelessWidget {
  const Seal(this.text, {super.key, required this.label, this.size = 28});
  final String text, label;
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    excludeSemantics: true,
    child: Transform.rotate(
      angle: -3 * math.pi / 180,
      child: ClipPath(
        clipper: _SealEdge(),
        child: ColoredBox(
          color: context.inkPalette.accent,
          child: SizedBox(
            width: text.length > 1 ? size * 1.6 : size,
            height: size,
            child: Center(
              child: Text(
                text,
                style: TextStyle(
                  fontFamily: 'WenKai',
                  fontSize: size * .66,
                  color: context.inkPalette.paper,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SealEdge extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final random = math.Random(19);
    final path = Path()..moveTo(1, 1);
    for (var edge = 0; edge < 4; edge++) {
      for (var i = 0; i <= 12; i++) {
        final t = i / 12, jitter = random.nextDouble() * .6;
        final point = switch (edge) {
          0 => Offset(t * size.width, jitter),
          1 => Offset(size.width - jitter, t * size.height),
          2 => Offset((1 - t) * size.width, size.height - jitter),
          _ => Offset(jitter, (1 - t) * size.height),
        };
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldReclip(_SealEdge oldClipper) => false;
}
