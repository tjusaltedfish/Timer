import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

class CardWheel extends StatelessWidget {
  const CardWheel({
    super.key,
    required this.count,
    required this.initial,
    required this.builder,
    this.onFocus,
    this.onActivate,
    this.minimumCardHeight = 280,
  });
  final int count, initial;
  final Widget Function(BuildContext, int, bool) builder;
  final ValueChanged<int>? onFocus, onActivate;
  final double minimumCardHeight;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final fraction = (minimumCardHeight / bounds.maxHeight).clamp(.5, 1.0);
      return _WheelPages(
        key: ValueKey(fraction),
        wheel: this,
        fraction: fraction,
      );
    },
  );
}

class _WheelPages extends StatefulWidget {
  const _WheelPages({super.key, required this.wheel, required this.fraction});
  final CardWheel wheel;
  final double fraction;
  int get initial => wheel.initial;
  int get count => wheel.count;
  Widget Function(BuildContext, int, bool) get builder => wheel.builder;
  ValueChanged<int>? get onFocus => wheel.onFocus;
  ValueChanged<int>? get onActivate => wheel.onActivate;
  @override
  State<_WheelPages> createState() => _CardWheelState();
}

class _CardWheelState extends State<_WheelPages> {
  late final PageController controller = PageController(
    initialPage: widget.initial,
    viewportFraction: widget.fraction,
  );
  late int current = widget.initial;
  @override
  void didUpdateWidget(covariant _WheelPages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initial != oldWidget.initial && current != widget.initial) {
      current = widget.initial;
      controller.jumpToPage(current);
    }
  }

  void move(int next) {
    if (next < 0 || next >= widget.count) return;
    controller.animateToPage(
      next,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : InkMetrics.transition,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        // Let focused buttons and text fields consume Enter before the wheel.
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          move(current + 1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          move(current - 1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter &&
            widget.onActivate != null) {
          widget.onActivate!(current);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: RepaintBoundary(
        child: PageView.builder(
          controller: controller,
          scrollDirection: Axis.vertical,
          itemCount: widget.count,
          onPageChanged: (value) {
            current = value;
            widget.onFocus?.call(value);
          },
          itemBuilder: (context, i) => AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final page =
                  controller.hasClients && controller.position.haveDimensions
                  ? controller.page!
                  : widget.initial.toDouble();
              final d = (i - page).abs().clamp(0.0, 3.0);
              final focused = d < .5;
              Widget card = widget.builder(context, i, focused);
              final content = card;
              card = LayoutBuilder(
                builder: (context, bounds) => Align(
                  alignment: Alignment(0, (page - i).clamp(-1.0, 1.0)),
                  child: SizedBox(
                    height: lerpDouble(
                      bounds.maxHeight,
                      132.0.clamp(0.0, bounds.maxHeight),
                      d.clamp(0.0, 1.0),
                    ),
                    child: content,
                  ),
                ),
              );
              if (!still) {
                card = Transform.scale(scale: 1 - .07 * d, child: card);
                if (d >= .15 && d <= 2) {
                  final sigma = (1.4 * d).clamp(0.0, 3.5);
                  card = ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: card,
                  );
                }
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Opacity(
                  opacity: (1 - .32 * d).clamp(.12, 1.0),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: focused ? null : () => move(i),
                    child: ExcludeFocus(
                      excluding: !focused,
                      child: AbsorbPointer(absorbing: !focused, child: card),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
