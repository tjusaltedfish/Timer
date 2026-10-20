import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The focus countdown: an ink ring that fills as time passes and a halo
/// that slowly breathes while the session runs. The breath follows the
/// once-a-second clock, so nothing animates forever in the background.
class FocusRing extends StatelessWidget {
  const FocusRing({
    super.key,
    required this.remaining,
    required this.planned,
    required this.caption,
    this.paused = false,
  });

  /// Seconds left (negative once over time) and seconds planned.
  final int remaining, planned;
  final String caption;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final over = remaining <= 0;
    final seconds = remaining.abs();
    final text =
        '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    final progress = planned <= 0
        ? 1.0
        : ((planned - remaining) / planned).clamp(0.0, 1.0);
    // One breath every eight seconds: in for four, out for four.
    final breath = paused
        ? 0.0
        : over
        ? (seconds.isEven ? 1.0 : .4)
        : .5 - .5 * math.cos(remaining % 8 / 8 * 2 * math.pi);
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return LayoutBuilder(
      builder: (context, bounds) {
        final room = math.min(
          bounds.maxWidth,
          bounds.maxHeight.isFinite ? bounds.maxHeight : 260.0,
        );
        final side = room.clamp(0.0, 260.0).toDouble();
        return Semantics(
          label:
              '${paused
                  ? '已暂停'
                  : over
                  ? '已到时间'
                  : '剩余'} $text，$caption',
          child: SizedBox.square(
            dimension: side,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: breath),
              duration: still
                  ? Duration.zero
                  : const Duration(milliseconds: 950),
              curve: Curves.easeInOut,
              builder: (context, value, child) => CustomPaint(
                painter: _FocusInk(
                  progress: progress,
                  breath: value,
                  paused: paused,
                  over: over,
                  p: p,
                ),
                child: child,
              ),
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(side * .16),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          over && !paused ? '+$text' : text,
                          key: const Key('focus.remaining'),
                          style: TextStyle(
                            fontFamily: 'WenKai',
                            fontSize: 52,
                            height: 1.15,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: paused ? p.inkZhong : p.inkJiao,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          caption,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FocusInk extends CustomPainter {
  _FocusInk({
    required this.progress,
    required this.breath,
    required this.paused,
    required this.over,
    required this.p,
  });
  final double progress, breath;
  final bool paused, over;
  final InkPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    // Halo: ink soaking into the paper, swelling and settling with the breath.
    final halo = radius * (.80 + .14 * breath);
    canvas.drawCircle(
      center,
      halo,
      Paint()
        ..shader = RadialGradient(
          colors: [
            (over ? p.accent : p.inkJiao).withValues(
              alpha: paused ? .02 : .035 + .05 * breath,
            ),
            p.inkJiao.withValues(alpha: 0),
          ],
          stops: const [.55, 1],
        ).createShader(Rect.fromCircle(center: center, radius: halo)),
    );
    final ring = Rect.fromCircle(center: center, radius: radius * .74);
    final start = -math.pi / 2;
    canvas.drawCircle(
      center,
      ring.width / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = p.inkJiao.withValues(alpha: .10),
    );
    // Elapsed time as one brush stroke: heavy where it began, lifting at the tip.
    final segments = (progress * 160).round();
    for (var i = 0; i < segments; i++) {
      final t = i / 160;
      final tip = segments <= 1 ? 1.0 : i / (segments - 1);
      canvas.drawArc(
        ring,
        start + t * 2 * math.pi,
        2 * math.pi / 160 + .004,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = radius * (.035 + .02 * (1 - tip))
          ..color =
              (over
                      ? p.accent
                      : paused
                      ? p.inkDan
                      : p.inkJiao)
                  .withValues(alpha: .35 + .5 * (1 - tip * .6)),
      );
    }
    if (!paused && progress < 1) {
      // A drop of fresh ink at the brush tip.
      final angle = start + progress * 2 * math.pi;
      final tip =
          center + Offset(math.cos(angle), math.sin(angle)) * (ring.width / 2);
      canvas.drawCircle(
        tip,
        radius * (.03 + .02 * breath),
        Paint()..color = p.inkJiao.withValues(alpha: .75),
      );
    }
  }

  @override
  bool shouldRepaint(_FocusInk old) =>
      progress != old.progress ||
      breath != old.breath ||
      paused != old.paused ||
      over != old.over ||
      p != old.p;
}

/// A short "entering focus" moment: ink spreads across the page, the task
/// name settles, then the page returns. Tapping skips it.
void showFocusEntry(BuildContext context, String title, String until) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _FocusEntry(
      title: title,
      until: until,
      onDone: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

class _FocusEntry extends StatefulWidget {
  const _FocusEntry({
    required this.title,
    required this.until,
    required this.onDone,
  });
  final String title, until;
  final VoidCallback onDone;
  @override
  State<_FocusEntry> createState() => _FocusEntryState();
}

class _FocusEntryState extends State<_FocusEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2100),
  );

  @override
  void initState() {
    super.initState();
    motion.forward().whenComplete(widget.onDone);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      motion.duration = const Duration(milliseconds: 900);
    }
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    return GestureDetector(
      key: const Key('focus.entry'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        motion.stop();
        widget.onDone();
      },
      child: AnimatedBuilder(
        animation: motion,
        builder: (context, _) {
          final t = motion.value;
          // Spread (0–30%), hold (30–75%), fade back to the page (75–100%).
          final spread = Curves.easeOutCubic.transform((t / .3).clamp(0, 1));
          final fade =
              1 - Curves.easeIn.transform(((t - .75) / .25).clamp(0, 1));
          final words = Curves.easeOut.transform(((t - .15) / .25).clamp(0, 1));
          final size = MediaQuery.sizeOf(context);
          final reach = size.longestSide * .9;
          return Opacity(
            opacity: fade,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _Spread(spread * reach, p.paper, p.inkJiao),
                  ),
                ),
                Center(
                  child: Opacity(
                    opacity: words,
                    child: Transform.translate(
                      offset: Offset(0, 12 * (1 - words)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '入定',
                              style: TextStyle(
                                fontFamily: 'WenKai',
                                fontSize: 20,
                                letterSpacing: 8,
                                color: p.paper.withValues(alpha: .72),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              widget.title,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'WenKai',
                                fontSize: 30,
                                height: 1.3,
                                color: p.paper,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              widget.until,
                              style: TextStyle(
                                fontSize: 13,
                                color: p.paper.withValues(alpha: .72),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Spread extends CustomPainter {
  _Spread(this.radius, this.paper, this.ink);
  final double radius;
  final Color paper, ink;
  @override
  void paint(Canvas canvas, Size size) {
    if (radius <= 0) return;
    final center = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            ink.withValues(alpha: .94),
            ink.withValues(alpha: .88),
            ink.withValues(alpha: 0),
          ],
          stops: const [0, .82, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_Spread old) => radius != old.radius;
}
