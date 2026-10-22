import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/ink_card.dart';
import 'onboarding_controller.dart';
import 'onboarding_steps.dart';

/// Wraps a real control and registers its rectangle for the coach overlay.
///
/// The widget itself is inert; the [GlobalKey] passed here is the one the
/// overlay measures once the frame that contains the step's page is laid out.
class CoachTarget extends StatelessWidget {
  const CoachTarget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// The ten-step tour: a dimmed layer with a hole over the real control, a card
/// that explains it, and skip / back / next.
///
/// It is deliberately animation-free: nothing here schedules frames on its own,
/// so `pumpAndSettle` in widget tests (and low-power devices) stay quiet.
class CoachOverlay extends StatefulWidget {
  const CoachOverlay({super.key, required this.controller});

  final OnboardingController controller;

  @override
  State<CoachOverlay> createState() => _CoachOverlayState();
}

class _CoachOverlayState extends State<CoachOverlay>
    with SingleTickerProviderStateMixin {
  static const _cardWidth = 384.0;
  static const _cardHeightGuess = 268.0;
  static const _edge = 16.0;

  OnboardingController get c => widget.controller;

  Rect? _hole;
  int _measuredStep = -1;

  /// Used purely as a clock: it keeps frames coming while the page switch in
  /// `PlannerHome` animates, so the hole is measured against the final layout
  /// instead of a mid-transition position. It paints nothing.
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: InkMetrics.transition,
  )..addStatusListener(_onSettleStatus);

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    _startSettling();
  }

  @override
  void didUpdateWidget(CoachOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      _startSettling();
    }
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    _settle.dispose();
    super.dispose();
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  void _onChanged() {
    if (!mounted || c.loading || !c.showTutorial) return;
    if (c.stepIndex != _measuredStep) _startSettling();
  }

  void _startSettling() {
    if (!mounted) return;
    _settle.forward(from: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted) return;
    final step = c.stepIndex.clamp(0, coachSteps.length - 1);
    final id = coachSteps[step].target;
    final rect = id == null ? null : c.targets.rectOf(id);
    if (rect == _hole && step == _measuredStep) return;
    setState(() {
      _hole = rect;
      _measuredStep = step;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.inkPalette;
    final step = c.step;
    final index = c.stepIndex;
    final size = MediaQuery.sizeOf(context);
    final width = math.min(size.width - _edge * 2, _cardWidth);
    final hole = _hole;

    double left = (size.width - width) / 2;
    double top = math.max(_edge * 2, size.height * .5 - _cardHeightGuess / 2);
    if (hole != null) {
      left = (hole.center.dx - width / 2).clamp(
        _edge,
        math.max(_edge, size.width - width - _edge),
      );
      final below = hole.bottom + 18;
      top = below + _cardHeightGuess <= size.height
          ? below
          : math.max(_edge, hole.top - 18 - _cardHeightGuess);
    }

    return Semantics(
      key: const Key('onboarding.overlay'),
      container: true,
      label: '使用引导，第 ${index + 1} 步，共 ${c.stepCount} 步',
      child: Stack(
        children: [
          // Painted scrim; never takes pointer events so the highlighted control
          // underneath stays usable — the tour copy tells people to tap it.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _SpotlightPainter(hole: hole, accent: palette.accent),
              ),
            ),
          ),
          ..._blockers(size, hole),
          Positioned(
            left: left,
            top: top,
            width: width,
            child: InkCard(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '第 ${index + 1} / ${c.stepCount} 步',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: palette.inkDan),
                      ),
                      const Spacer(),
                      _progressDots(index, palette),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    step.title,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(color: palette.inkJiao),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    step.body,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: palette.inkZhong, height: 1.5),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      TextButton(
                        key: const Key('onboarding.skip'),
                        onPressed: () => c.skip(),
                        child: const Text('跳过教程'),
                      ),
                      const Spacer(),
                      if (index > 0)
                        TextButton(
                          key: const Key('onboarding.previous'),
                          onPressed: () => c.previous(),
                          child: const Text('上一步'),
                        ),
                      const SizedBox(width: 4),
                      FilledButton(
                        key: const Key('onboarding.next'),
                        onPressed: () => c.next(),
                        child: Text(index >= c.stepCount - 1 ? '知道了' : '下一步'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Blocks every area except the spotlight hole, so taps on the highlighted
  /// control reach it (the step copy says "点这个按钮…"). The tour card still
  /// floats above with 跳过/下一步.
  List<Widget> _blockers(Size size, Rect? hole) {
    Widget block(double left, double top, double width, double height) {
      if (width <= 0 || height <= 0) return const SizedBox.shrink();
      return Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {}),
      );
    }

    if (hole == null) return [block(0, 0, size.width, size.height)];
    final top = hole.top.clamp(0.0, size.height);
    final bottom = hole.bottom.clamp(0.0, size.height);
    final left = hole.left.clamp(0.0, size.width);
    final right = hole.right.clamp(0.0, size.width);
    return [
      block(0, 0, size.width, top),
      block(0, bottom, size.width, size.height - bottom),
      block(0, top, left, bottom - top),
      block(right, top, size.width - right, bottom - top),
    ];
  }

  Widget _progressDots(int index, InkPalette palette) => Row(
    children: [
      for (var i = 0; i < c.stepCount; i++)
        Container(
          width: 6,
          height: 6,
          margin: const EdgeInsets.only(left: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i <= index ? palette.accent : palette.line,
          ),
        ),
    ],
  );
}

class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({required this.hole, required this.accent});

  final Rect? hole;
  final Color accent;

  static const _scrim = Color(0xA0000000);

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Path()..addRect(Offset.zero & size);
    RRect? ring;
    var path = screen;
    if (hole != null) {
      ring = RRect.fromRectAndRadius(
        hole!.inflate(8),
        const Radius.circular(20),
      );
      path = Path.combine(
        PathOperation.difference,
        screen,
        Path()..addRRect(ring),
      );
    }
    canvas.drawPath(path, Paint()..color = _scrim);
    if (ring != null) {
      canvas.drawRRect(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) =>
      oldDelegate.hole != hole || oldDelegate.accent != accent;
}
