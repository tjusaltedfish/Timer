import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Vertical card wheel: past above, future below. Cards keep a fixed height;
/// distance from the centre only drives paint-time transforms (scale, roll,
/// fade, blur), so dragging never re-lays-out content and tracks the finger.
class CardWheel extends StatefulWidget {
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
  State<CardWheel> createState() => _CardWheelState();
}

class _CardWheelState extends State<CardWheel> {
  PageController? controller;
  late int current = widget.initial;
  double _wheelDelta = 0;
  DateTime _lastWheelStep = DateTime.fromMillisecondsSinceEpoch(0);

  PageController _controllerFor(double fraction) {
    final existing = controller;
    if (existing != null &&
        (existing.viewportFraction - fraction).abs() < .01) {
      return existing;
    }
    final next = PageController(
      initialPage: current,
      viewportFraction: fraction,
    );
    if (existing != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => existing.dispose());
    }
    return controller = next;
  }

  @override
  void didUpdateWidget(covariant CardWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (current >= widget.count) current = math.max(0, widget.count - 1);
    if (widget.initial != oldWidget.initial && widget.initial != current) {
      move(widget.initial);
    }
  }

  void move(int next) {
    final c = controller;
    if (next < 0 || next >= widget.count || c == null || !c.hasClients) return;
    c.animateToPage(
      next,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _wheelDelta += event.scrollDelta.dy;
      final now = DateTime.now();
      if (_wheelDelta.abs() < 28 ||
          now.difference(_lastWheelStep) < const Duration(milliseconds: 220)) {
        return;
      }
      _lastWheelStep = now;
      final step = _wheelDelta > 0 ? 1 : -1;
      _wheelDelta = 0;
      move(current + step);
    });
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final viewport = bounds.maxHeight.isFinite ? bounds.maxHeight : 600.0;
      final fraction = ((widget.minimumCardHeight + 20) / viewport).clamp(
        .44,
        1.0,
      );
      final cardHeight = math.min(viewport * fraction - 20, viewport);
      final c = _controllerFor(fraction);
      final still = MediaQuery.disableAnimationsOf(context);
      return Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
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
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            scrollbars: false,
            overscroll: false,
            dragDevices: PointerDeviceKind.values.toSet(),
          ),
          child: RepaintBoundary(
            // A new controller must come with a new scroll position:
            // otherwise the old pixel offset is carried over and the wheel
            // rests between cards whenever its height changes.
            child: PageView.builder(
              key: ObjectKey(c),
              controller: c,
              scrollDirection: Axis.vertical,
              pageSnapping: false,
              physics: WheelSnapPhysics(fraction: fraction),
              itemCount: widget.count,
              onPageChanged: (value) {
                current = value;
                widget.onFocus?.call(value);
              },
              itemBuilder: (context, i) => Listener(
                behavior: HitTestBehavior.opaque,
                onPointerSignal: _onPointerSignal,
                child: AnimatedBuilder(
                  animation: c,
                  builder: (context, _) {
                    final page = c.hasClients && c.position.haveDimensions
                        ? c.page!
                        : current.toDouble();
                    final delta = i - page;
                    final d = delta.abs().clamp(0.0, 3.0);
                    final focused = d < .5;
                    // Hit-testing follows the painted (transformed) card.
                    Widget card = GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: focused ? null : () => move(i),
                      child: ExcludeFocus(
                        excluding: !focused,
                        child: AbsorbPointer(
                          absorbing: !focused,
                          child: SizedBox(
                            height: cardHeight,
                            child: widget.builder(context, i, focused),
                          ),
                        ),
                      ),
                    );
                    if (!still) {
                      // Neighbours tuck toward the centre and roll away
                      // slightly, like cards on a drum.
                      final roll = (-delta * .2).clamp(-.45, .45);
                      card = Transform(
                        alignment: delta < 0
                            ? Alignment.bottomCenter
                            : Alignment.topCenter,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, .0011)
                          ..translateByDouble(
                            0,
                            -delta.clamp(-2.0, 2.0) * cardHeight * .04,
                            0,
                            1,
                          )
                          ..rotateX(roll)
                          ..scaleByDouble(1 - .075 * d, 1 - .075 * d, 1, 1),
                        child: card,
                      );
                      if (d >= .12 && d <= 2.4) {
                        final sigma = (1.7 * d).clamp(0.0, 4.0);
                        card = ImageFiltered(
                          imageFilter: ImageFilter.blur(
                            sigmaX: sigma,
                            sigmaY: sigma,
                          ),
                          child: card,
                        );
                      }
                    }
                    return Center(
                      child: Opacity(
                        opacity: (1 - .4 * d).clamp(.08, 1.0),
                        child: card,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Snaps to whole cards. Any flick (>90 px/s) advances exactly one card;
/// only very hard flicks skip more. Settling uses a critically damped spring.
class WheelSnapPhysics extends ScrollPhysics {
  const WheelSnapPhysics({required this.fraction, super.parent});
  final double fraction;

  @override
  WheelSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      WheelSnapPhysics(fraction: fraction, parent: buildParent(ancestor));

  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: .5, stiffness: 110, ratio: 1);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final extent = position.viewportDimension * fraction;
    if (extent <= 0) return super.createBallisticSimulation(position, velocity);
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final page = position.pixels / extent;
    double target;
    if (velocity.abs() < 90) {
      target = page.roundToDouble();
    } else {
      final extra = (velocity.abs() / 4500).floor().clamp(0, 2);
      target = velocity > 0
          ? page.floorToDouble() + 1 + extra
          : page.ceilToDouble() - 1 - extra;
    }
    final pixels = (target * extent).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final tolerance = toleranceFor(position);
    if ((pixels - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      pixels,
      velocity,
      tolerance: tolerance,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}
