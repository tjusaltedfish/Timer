import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../formatting.dart';
import '../theme/tokens.dart';

/// A single drum column. Drag, fling, mouse wheel, tap a neighbour or use the
/// arrow keys; [looping] columns wrap around (23 → 00).
class InkWheel extends StatefulWidget {
  const InkWheel({
    super.key,
    required this.count,
    required this.index,
    required this.label,
    required this.onChanged,
    this.looping = true,
    this.itemExtent = 40,
    this.visible = 5,
    this.width = 64,
    this.disabled,
    this.semanticLabel = '',
  });
  final int count, index, visible;
  final String Function(int) label;
  final ValueChanged<int> onChanged;
  final bool looping;
  final double itemExtent, width;
  final bool Function(int)? disabled;
  final String semanticLabel;
  @override
  State<InkWheel> createState() => _InkWheelState();
}

class _InkWheelState extends State<InkWheel>
    with SingleTickerProviderStateMixin {
  late final AnimationController position = AnimationController.unbounded(
    vsync: this,
    value: widget.index.toDouble(),
  );
  late double _target = widget.index.toDouble();
  static final _spring = SpringDescription.withDampingRatio(
    mass: .4,
    stiffness: 160,
    ratio: 1,
  );

  int _normal(num value) {
    final i = value.round();
    return widget.looping
        ? ((i % widget.count) + widget.count) % widget.count
        : i.clamp(0, widget.count - 1);
  }

  /// Nearest unwrapped position that shows [index].
  double _nearest(int index) {
    if (!widget.looping) return index.toDouble();
    final base = (position.value / widget.count).floor() * widget.count;
    final options = [
      base - widget.count + index,
      base + index,
      base + widget.count + index,
    ];
    options.sort(
      (a, b) =>
          (a - position.value).abs().compareTo((b - position.value).abs()),
    );
    return options.first.toDouble();
  }

  @override
  void didUpdateWidget(covariant InkWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != _normal(_target)) {
      _animateTo(_nearest(widget.index), notify: false);
    }
  }

  void _animateTo(double target, {double velocity = 0, bool notify = true}) {
    if (!widget.looping) {
      target = target.clamp(0, widget.count - 1).toDouble();
    }
    _target = target;
    if (MediaQuery.disableAnimationsOf(context)) {
      position.value = target;
      if (notify) widget.onChanged(_normal(target));
      return;
    }
    position
        .animateWith(
          SpringSimulation(_spring, position.value, target, velocity),
        )
        .then((_) {
          if (notify && mounted) widget.onChanged(_normal(target));
        });
  }

  void step(int delta) => _animateTo(_target.roundToDouble() + delta);

  DateTime? _hoverSince;

  /// Scroll ticks only turn the drum once the pointer has rested on it, so a
  /// page scrolling underneath the cursor never changes the value by accident.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final since = _hoverSince;
    if (since == null ||
        DateTime.now().difference(since) < const Duration(milliseconds: 350)) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (event.scrollDelta.dy.abs() < 1) return;
      step(event.scrollDelta.dy > 0 ? 1 : -1);
    });
  }

  @override
  void dispose() {
    position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final height = widget.itemExtent * widget.visible;
    return Semantics(
      label: widget.semanticLabel,
      value: widget.label(_normal(_target)),
      increasedValue: widget.label(_normal(_target + 1)),
      decreasedValue: widget.label(_normal(_target - 1)),
      onIncrease: () => step(1),
      onDecrease: () => step(-1),
      child: Focus(
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            step(1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            step(-1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final focused = Focus.of(context).hasFocus;
            return MouseRegion(
              onEnter: (_) => _hoverSince = DateTime.now(),
              onExit: (_) => _hoverSince = null,
              child: Listener(
                onPointerSignal: _onPointerSignal,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: (_) {
                    position.stop();
                    Focus.of(context).requestFocus();
                  },
                  onVerticalDragUpdate: (d) {
                    var next = position.value - d.delta.dy / widget.itemExtent;
                    if (!widget.looping) {
                      // Gentle resistance past the ends.
                      if (next < 0 || next > widget.count - 1) {
                        next =
                            position.value -
                            d.delta.dy / widget.itemExtent * .3;
                      }
                    }
                    position.value = next;
                  },
                  onVerticalDragEnd: (d) {
                    final v =
                        (-d.velocity.pixelsPerSecond.dy / widget.itemExtent)
                            .clamp(-24.0, 24.0);
                    _animateTo(
                      (position.value + v * .12).roundToDouble(),
                      velocity: v,
                    );
                  },
                  onTapUp: (d) {
                    Focus.of(context).requestFocus();
                    final offset =
                        ((d.localPosition.dy - height / 2) / widget.itemExtent)
                            .round();
                    if (offset != 0) step(offset);
                  },
                  child: SizedBox(
                    width: widget.width,
                    height: height,
                    child: ShaderMask(
                      // Rows fade into the paper at the drum's edges.
                      shaderCallback: (rect) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x00000000),
                          Color(0xFF000000),
                          Color(0xFF000000),
                          Color(0x00000000),
                        ],
                        stops: [0, .22, .78, 1],
                      ).createShader(rect),
                      blendMode: BlendMode.dstIn,
                      child: ClipRect(
                        child: AnimatedBuilder(
                          animation: position,
                          builder: (context, _) => Stack(
                            alignment: Alignment.center,
                            children: [
                              Container(
                                height: widget.itemExtent,
                                decoration: BoxDecoration(
                                  color: focused ? p.washStrong : p.wash,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              ..._items(p, height),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _items(InkPalette p, double height) {
    final value = position.value;
    final half = widget.visible ~/ 2 + 1;
    return [
      for (var k = value.floor() - half; k <= value.ceil() + half; k++)
        if (widget.looping || (k >= 0 && k < widget.count))
          () {
            final offset = k - value;
            final distance = offset.abs();
            final index = _normal(k);
            final off = widget.disabled?.call(index) ?? false;
            final center = distance < .5;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, .004)
                ..translateByDouble(0, offset * widget.itemExtent * .92, 0, 1)
                ..rotateX(-offset * .32)
                ..scaleByDouble(1 - .08 * distance, 1 - .08 * distance, 1, 1),
              child: Opacity(
                opacity: (1 - .3 * distance).clamp(0.0, 1.0) * (off ? .45 : 1),
                child: SizedBox(
                  height: widget.itemExtent,
                  child: Center(
                    child: Text(
                      widget.label(index),
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: 'WenKai',
                        fontFamilyFallback: const ['Microsoft YaHei UI'],
                        fontSize: center ? 21 : 18,
                        height: 1,
                        color: off
                            ? p.inkDan
                            : center
                            ? p.inkJiao
                            : p.inkZhong,
                        decoration: off ? TextDecoration.lineThrough : null,
                        decorationColor: p.inkDan,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }(),
    ];
  }
}

/// Date + hour + minute drums. When [minimum] is set, earlier moments are
/// drawn faint and a selection before it springs forward to the nearest
/// allowed slot, so a past time can never be chosen.
class InkDateTimeWheel extends StatefulWidget {
  const InkDateTimeWheel({
    super.key,
    required this.initial,
    required this.today,
    required this.onChanged,
    this.minimum,
    this.maximum,
    this.firstDay,
    this.showDate = true,
    this.days = 120,
    this.minuteStep = 5,
  });

  /// Wall-clock values in the planner's zone (only y/m/d/h/m are used).
  final DateTime initial, today;

  /// Earliest / latest selectable moments (e.g. no past plans, no future
  /// sleep). [firstDay] is the first date offered when there is no minimum.
  final DateTime? minimum, maximum, firstDay;
  final bool showDate;
  final int days, minuteStep;
  final void Function(DateTime day, int hour, int minute) onChanged;

  /// Rounds a wall-clock time up to the next [step]-minute slot.
  static DateTime ceilTo(DateTime value, int step) {
    final base = DateTime(value.year, value.month, value.day, value.hour);
    final minutes = value.minute + (value.second > 0 ? 1 : 0);
    final up = ((minutes + step - 1) ~/ step) * step;
    return base.add(Duration(minutes: up));
  }

  @override
  State<InkDateTimeWheel> createState() => _InkDateTimeWheelState();
}

class _InkDateTimeWheelState extends State<InkDateTimeWheel> {
  late DateTime firstDay;
  late int day, hour, minute;
  bool corrected = false;

  DateTime? get floor => widget.minimum == null
      ? null
      : InkDateTimeWheel.ceilTo(widget.minimum!, widget.minuteStep);

  DateTime? get ceiling {
    final m = widget.maximum;
    if (m == null) return null;
    return DateTime(
      m.year,
      m.month,
      m.day,
      m.hour,
      m.minute - m.minute % widget.minuteStep,
    );
  }

  DateTime _clamp(DateTime value) {
    if (floor != null && value.isBefore(floor!)) return floor!;
    if (ceiling != null && value.isAfter(ceiling!)) return ceiling!;
    return value;
  }

  @override
  void initState() {
    super.initState();
    final start = floor ?? widget.firstDay ?? widget.today;
    firstDay = DateTime(start.year, start.month, start.day);
    _set(_clamp(widget.initial));
  }

  void _set(DateTime value) {
    day = DateTime(
      value.year,
      value.month,
      value.day,
    ).difference(firstDay).inDays.clamp(0, widget.days - 1);
    hour = value.hour;
    minute = (value.minute ~/ widget.minuteStep) % (60 ~/ widget.minuteStep);
  }

  DateTime get _dayDate =>
      DateTime(firstDay.year, firstDay.month, firstDay.day + day);
  DateTime get value => DateTime(
    _dayDate.year,
    _dayDate.month,
    _dayDate.day,
    hour,
    minute * widget.minuteStep,
  );

  /// Drawn faint: the whole slot lies outside [floor, ceiling].
  bool _outside(DateTime from, DateTime to) =>
      (floor != null && !to.isAfter(floor!)) ||
      (ceiling != null && from.isAfter(ceiling!));

  bool _hourOff(int h) {
    final d = _dayDate;
    final from = DateTime(d.year, d.month, d.day, h);
    return _outside(from, from.add(const Duration(hours: 1)));
  }

  bool _minuteOff(int m) {
    final d = _dayDate;
    final at = DateTime(d.year, d.month, d.day, hour, m * widget.minuteStep);
    return _outside(at, at.add(const Duration(minutes: 1)));
  }

  void _changed() {
    final allowed = _clamp(value);
    if (allowed != value) {
      setState(() {
        _set(allowed);
        corrected = true;
      });
    } else {
      setState(() => corrected = false);
    }
    widget.onChanged(_dayDate, hour, minute * widget.minuteStep);
  }

  String _dayLabel(int i) {
    final d = DateTime(firstDay.year, firstDay.month, firstDay.day + i);
    final offset = d
        .difference(
          DateTime(widget.today.year, widget.today.month, widget.today.day),
        )
        .inDays;
    final week = weekdays[d.weekday - 1];
    return switch (offset) {
      0 => '今天 $week',
      1 => '明天 $week',
      2 => '后天 $week',
      _ => '${d.month}月${d.day}日 $week',
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final steps = 60 ~/ widget.minuteStep;
    final narrow = MediaQuery.sizeOf(context).width < 380;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.showDate) ...[
              InkWheel(
                key: const ValueKey('wheel.day'),
                count: widget.days,
                index: day,
                looping: false,
                width: narrow ? 118 : 140,
                semanticLabel: '日期',
                label: _dayLabel,
                onChanged: (i) {
                  day = i;
                  _changed();
                },
              ),
              SizedBox(width: narrow ? 6 : 14),
            ],
            InkWheel(
              key: const ValueKey('wheel.hour'),
              count: 24,
              index: hour,
              width: 60,
              semanticLabel: '小时',
              disabled: _hourOff,
              label: (i) => i.toString().padLeft(2, '0'),
              onChanged: (i) {
                hour = i;
                _changed();
              },
            ),
            Text(
              ':',
              style: TextStyle(
                fontFamily: 'WenKai',
                fontSize: 22,
                color: p.inkZhong,
              ),
            ),
            InkWheel(
              key: const ValueKey('wheel.minute'),
              count: steps,
              index: minute,
              width: 60,
              semanticLabel: '分钟',
              disabled: _minuteOff,
              label: (i) => (i * widget.minuteStep).toString().padLeft(2, '0'),
              onChanged: (i) {
                minute = i;
                _changed();
              },
            ),
          ],
        ),
        AnimatedSize(
          duration: InkMetrics.micro,
          child: corrected
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    ceiling != null && !value.isBefore(ceiling!)
                        ? '还没到来的时刻不能记录，已挪到 ${hm(value)}。'
                        : '已经过去的时刻不能安排，已挪到最近的 ${hm(value)}。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// Opens a small sheet with time drums; returns the chosen wall time.
Future<TimeOfDay?> pickWheelTime(
  BuildContext context, {
  required TimeOfDay initial,
  required String title,
}) {
  var hour = initial.hour, minute = (initial.minute ~/ 5) * 5;
  final today = DateTime.now();
  return showModalBottomSheet<TimeOfDay>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            InkDateTimeWheel(
              showDate: false,
              today: today,
              initial: DateTime(
                today.year,
                today.month,
                today.day,
                hour,
                minute,
              ),
              onChanged: (_, h, m) {
                hour = h;
                minute = m;
              },
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('算了'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('action.confirm-time'),
                    onPressed: () => Navigator.pop(
                      context,
                      TimeOfDay(hour: hour, minute: minute),
                    ),
                    child: const Text('就这个时间'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
