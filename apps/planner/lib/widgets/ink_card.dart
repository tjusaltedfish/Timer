import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ink_bloom.dart';

/// Raised paper with rounded, soft edges. Focused cards have an ink wash
/// spreading out from behind them; there are no hard borders in light mode.
class InkCard extends StatelessWidget {
  const InkCard({
    super.key,
    required this.child,
    this.mark,
    this.focused = false,
    this.inquiry = false,
    this.padding = const EdgeInsets.all(24),
    this.radius = InkMetrics.cardRadius,
  });
  final Widget child;
  final Color? mark;
  final bool focused, inquiry;
  final EdgeInsetsGeometry padding;
  final double radius;

  static const _focusSpots = [
    BloomSpot(Offset(.12, .1), .62, .07, seed: 3),
    BloomSpot(Offset(.92, .95), .4, .045, seed: 17),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        if (focused)
          Positioned(
            left: -36,
            top: -28,
            right: -36,
            bottom: -36,
            child: SpreadingBloom(
              active: focused,
              spots: _focusSpots,
              color: dark ? p.inkJiao.withValues(alpha: .6) : p.bloom,
            ),
          ),
        AnimatedContainer(
          duration: context.stillMotion ? Duration.zero : InkMetrics.micro,
          decoration: BoxDecoration(
            color: inquiry
                ? Color.alphaBlend(p.inquiryWash, p.paperRaised)
                : p.paperRaised,
            borderRadius: BorderRadius.circular(radius),
            border: dark ? Border.all(color: p.line) : null,
            boxShadow: dark ? null : p.halo,
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                if (mark != null)
                  Positioned(
                    top: 22,
                    left: 0,
                    child: Container(
                      width: 3.5,
                      height: 26,
                      decoration: BoxDecoration(
                        color: mark,
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(3),
                        ),
                      ),
                    ),
                  ),
                Padding(padding: padding, child: child),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
