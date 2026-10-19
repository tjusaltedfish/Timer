import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class PaperBackground extends StatelessWidget {
  const PaperBackground({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final texture =
        Theme.of(context).extension<InkTokens>()!.texture &&
        !MediaQuery.disableAnimationsOf(context);
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: p.paper)),
        if (texture)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: Opacity(
                  opacity: Theme.of(context).brightness == Brightness.dark
                      ? .025
                      : .06,
                  child: Image.asset(
                    'assets/textures/paper.png',
                    repeat: ImageRepeat.repeat,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? p.inkJiao
                        : null,
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
