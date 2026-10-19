import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ink_bloom.dart';

/// Pure white paper with a faint fibre texture and two ink washes that have
/// spread in from the corners. Static: painted once per size change.
class PaperBackground extends StatelessWidget {
  const PaperBackground({super.key, required this.child, this.blooms = true});
  final Widget child;
  final bool blooms;

  static const _spots = [
    BloomSpot(Offset(1.02, -.04), .62, .15, seed: 11),
    BloomSpot(Offset(.86, .12), .18, .09, seed: 23),
    BloomSpot(Offset(-.08, 1.04), .5, .11, seed: 5),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final texture =
        Theme.of(context).extension<InkTokens>()!.texture &&
        !context.stillMotion;
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: p.paper)),
        if (blooms)
          Positioned.fill(
            child: RepaintBoundary(
              child: InkBloom(
                spots: _spots,
                color: dark ? p.inkJiao.withValues(alpha: .5) : p.bloom,
                maxRadius: 560,
              ),
            ),
          ),
        if (texture)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: Opacity(
                  opacity: dark ? .02 : .035,
                  child: Image.asset(
                    'assets/textures/paper.png',
                    repeat: ImageRepeat.repeat,
                    color: dark ? p.inkJiao : null,
                    colorBlendMode: BlendMode.screen,
                  ),
                ),
              ),
            ),
          ),
        child,
      ],
    );
  }
}
