import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class InkCard extends StatelessWidget {
  const InkCard({
    super.key,
    required this.child,
    this.project,
    this.focused = false,
    this.inquiry = false,
    this.padding = const EdgeInsets.all(24),
  });
  final Widget child;
  final String? project;
  final bool focused, inquiry;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: inquiry ? p.inquiryWash : p.paperRaised,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(6),
        gradient: focused && !MediaQuery.disableAnimationsOf(context)
            ? RadialGradient(
                center: const Alignment(-.65, -.65),
                radius: 1.4,
                colors: [
                  Color.alphaBlend(p.wash, p.paperRaised),
                  p.paperRaised,
                ],
              )
            : null,
      ),
      child: Stack(
        children: [
          if (project != null)
            Positioned(
              top: 16,
              bottom: 16,
              left: 0,
              child: SizedBox(
                width: 2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        (p.projects[project] ?? p.inkZhong).withValues(
                          alpha: 0,
                        ),
                        p.projects[project] ?? p.inkZhong,
                        p.projects[project] ?? p.inkZhong,
                        (p.projects[project] ?? p.inkZhong).withValues(
                          alpha: 0,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}
