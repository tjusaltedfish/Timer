import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'controller.dart';
import 'formatting.dart';
import 'theme/tokens.dart';

/// Called with the chosen start and length when an empty slot is picked.
typedef SlotPicked = void Function(tz.TZDateTime start, int minutes);

const _hourHeight = 56.0, _axisWidth = 48.0, _headerHeight = 54.0;

/// Visible hour range: the configured day, widened to fit every block shown.
(int, int) visibleHours(
  Iterable<DaySlice> slices,
  String dayStart,
  String dayEnd,
) {
  var first = int.parse(dayStart.split(':').first);
  var last =
      int.parse(dayEnd.split(':').first) + (dayEnd.endsWith(':00') ? 0 : 1);
  for (final slice in slices) {
    first = math.min(first, slice.start.hour);
    last = math.max(
      last,
      slice.end.day != slice.start.day && slice.end.hour == 0
          ? 24
          : slice.end.hour + (slice.end.minute > 0 ? 1 : 0),
    );
  }
  return (first, math.min(last, 24));
}

class WeekCalendar extends StatefulWidget {
  const WeekCalendar({
    super.key,
    required this.blocks,
    required this.tasks,
    required this.zone,
    required this.selectedDay,
    required this.dayStart,
    required this.dayEnd,
    required this.onSelectDay,
    required this.onBlockTap,
    this.now,
    this.onSlotPicked,
    this.markOf,
  });
  final List<Json> blocks, tasks;
  final tz.Location zone;
  final DateTime selectedDay;
  final DateTime? now;
  final String dayStart, dayEnd;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Json> onBlockTap;
  final SlotPicked? onSlotPicked;
  final Color? Function(Json block)? markOf;
  @override
  State<WeekCalendar> createState() => _WeekCalendarState();
}

class _WeekCalendarState extends State<WeekCalendar> {
  final scroll = ScrollController();
  double _columnWidth = 0;

  DateTime get monday => DateTime(
    widget.selectedDay.year,
    widget.selectedDay.month,
    widget.selectedDay.day - widget.selectedDay.weekday + 1,
  );

  void _reveal() {
    if (!mounted || !scroll.hasClients || _columnWidth == 0) return;
    final index = widget.selectedDay.weekday - 1;
    final target = (index - .5) * _columnWidth;
    scroll.animateTo(
      target.clamp(0, scroll.position.maxScrollExtent),
      duration: context.stillMotion ? Duration.zero : InkMetrics.transition,
      curve: InkMetrics.settle,
    );
  }

  @override
  void didUpdateWidget(covariant WeekCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (dateKey(oldWidget.selectedDay) != dateKey(widget.selectedDay)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final p = context.inkPalette;
      final days = List.generate(
        7,
        (i) => DateTime(monday.year, monday.month, monday.day + i),
      );
      final slices = {
        for (final day in days) day: daySlices(widget.blocks, day, widget.zone),
      };
      final (first, last) = visibleHours(
        slices.values.expand((s) => s),
        widget.dayStart,
        widget.dayEnd,
      );
      final available = constraints.maxWidth - _axisWidth;
      final fits = available >= 7 * 96;
      _columnWidth = fits ? available / 7 : math.max(available / 3.2, 96);
      final gridHeight = (last - first) * _hourHeight;
      final changingOffset = days.any((day) {
        final a = tz.TZDateTime(
          widget.zone,
          day.year,
          day.month,
          day.day,
          first,
        );
        final b = tz.TZDateTime(
          widget.zone,
          day.year,
          day.month,
          day.day,
          last,
        );
        return a.timeZoneOffset != b.timeZoneOffset;
      });
      final columns = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final day in days)
            SizedBox(
              width: _columnWidth,
              child: Column(
                children: [
                  _DayHeader(
                    day: day,
                    selected: dateKey(day) == dateKey(widget.selectedDay),
                    today:
                        widget.now != null &&
                        dateKey(day) == dateKey(widget.now!),
                    onTap: () => widget.onSelectDay(day),
                  ),
                  SizedBox(
                    height: gridHeight,
                    child: _DayColumn(
                      day: day,
                      zone: widget.zone,
                      firstHour: first,
                      lastHour: last,
                      slices: slices[day]!,
                      tasks: widget.tasks,
                      now: widget.now,
                      showOffset: changingOffset,
                      onBlockTap: widget.onBlockTap,
                      onSlotPicked: widget.onSlotPicked,
                      markOf: widget.markOf,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (changingOffset)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '本周有夏令时切换；时间块按实际持续时长显示，并标明 UTC 偏移。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _axisWidth,
                child: Column(
                  children: [
                    const SizedBox(height: _headerHeight),
                    for (var hour = first; hour < last; hour++)
                      SizedBox(
                        height: _hourHeight,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Transform.translate(
                            offset: const Offset(0, -8),
                            child: Text(
                              '${hour.toString().padLeft(2, '0')}:00',
                              style: TextStyle(
                                fontFamily: 'WenKai',
                                fontSize: 12,
                                color: p.inkZhong,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: fits
                    ? columns
                    : SingleChildScrollView(
                        controller: scroll,
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: columns,
                      ),
              ),
            ],
          ),
          if (widget.onSlotPicked != null)
            Padding(
              padding: const EdgeInsets.only(top: 14, left: _axisWidth),
              child: Text(
                '点空白处安排一件事；长按后上下拖动，可以圈出一段时间。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      );
    },
  );
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.day,
    required this.selected,
    required this.today,
    required this.onTap,
  });
  final DateTime day;
  final bool selected, today;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    return Semantics(
      button: true,
      selected: selected,
      label: '${day.month}月${day.day}日 ${weekdays[day.weekday - 1]}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: _headerHeight,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                weekdays[day.weekday - 1],
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 2),
              AnimatedContainer(
                duration: InkMetrics.micro,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: selected ? p.inkJiao : p.paper.withValues(alpha: 0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontFamily: 'WenKai',
                    fontSize: 18,
                    height: 1.3,
                    color: selected ? p.paper : p.inkJiao,
                    decoration: today && !selected
                        ? TextDecoration.underline
                        : null,
                    decorationColor: p.inkZhong,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayColumn extends StatefulWidget {
  const _DayColumn({
    required this.day,
    required this.zone,
    required this.firstHour,
    required this.lastHour,
    required this.slices,
    required this.tasks,
    required this.now,
    required this.showOffset,
    required this.onBlockTap,
    required this.onSlotPicked,
    required this.markOf,
  });
  final DateTime day;
  final DateTime? now;
  final tz.Location zone;
  final int firstHour, lastHour;
  final List<DaySlice> slices;
  final List<Json> tasks;
  final bool showOffset;
  final ValueChanged<Json> onBlockTap;
  final SlotPicked? onSlotPicked;
  final Color? Function(Json block)? markOf;
  @override
  State<_DayColumn> createState() => _DayColumnState();
}

class _DayColumnState extends State<_DayColumn> {
  int? hoverSlot, dragFrom, dragTo;
  static const slotMinutes = 30;

  tz.TZDateTime get origin => tz.TZDateTime(
    widget.zone,
    widget.day.year,
    widget.day.month,
    widget.day.day,
    widget.firstHour,
  );
  int get slotCount => (widget.lastHour - widget.firstHour) * 60 ~/ slotMinutes;
  int slotAt(double dy) =>
      (dy / (_hourHeight * slotMinutes / 60)).floor().clamp(0, slotCount - 1);
  tz.TZDateTime slotStart(int slot) =>
      origin.add(Duration(minutes: slot * slotMinutes));

  bool _occupied(int slot) {
    final a = slotStart(slot), b = slotStart(slot + 1);
    return widget.slices.any(
      (s) =>
          s.block['status'] == 'scheduled' &&
          s.start.isBefore(b) &&
          s.end.isAfter(a),
    );
  }

  bool _past(int slot) =>
      widget.now != null && !slotStart(slot + 1).isAfter(widget.now!);

  bool _contains(int slot) =>
      widget.now != null &&
      !slotStart(slot).isAfter(widget.now!) &&
      slotStart(slot + 1).isAfter(widget.now!);

  bool _usable(int slot) => !_past(slot) || _contains(slot);

  void _pick(int from, int to) {
    final picked = widget.onSlotPicked;
    if (picked == null) return;
    final a = math.min(from, to), b = math.max(from, to);
    picked(slotStart(a), (b - a + 1) * slotMinutes);
  }

  double _y(DateTime t) => t.difference(origin).inSeconds / 3600 * _hourHeight;

  void _pastHint() {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('这段时间已经过去了，挑一个还没到来的时段吧。')));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final now = widget.now;
    final end = slotStart(slotCount);
    final isToday = now != null && dateKey(now) == dateKey(widget.day);
    final pastUntil = now == null || now.isBefore(origin)
        ? 0.0
        : now.isAfter(end)
        ? _y(end)
        : _y(now);
    final sel = dragFrom == null
        ? null
        : (math.min(dragFrom!, dragTo!), math.max(dragFrom!, dragTo!));
    final slotHeight = _hourHeight * slotMinutes / 60;
    final picking = widget.onSlotPicked != null;
    return MouseRegion(
      onHover: picking
          ? (e) {
              final slot = slotAt(e.localPosition.dy);
              if (slot != hoverSlot) setState(() => hoverSlot = slot);
            }
          : null,
      onExit: (_) => setState(() => hoverSlot = null),
      cursor: picking ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: picking
            ? (d) {
                final slot = slotAt(d.localPosition.dy);
                if (!_usable(slot)) return _pastHint();
                // A single tap reserves an hour where the next half hour is free.
                final last = slot + 1 < slotCount && !_occupied(slot + 1)
                    ? slot + 1
                    : slot;
                _pick(slot, last);
              }
            : null,
        onLongPressStart: picking
            ? (d) {
                final slot = slotAt(d.localPosition.dy);
                setState(() => dragFrom = dragTo = slot);
              }
            : null,
        onLongPressMoveUpdate: picking
            ? (d) => setState(() => dragTo = slotAt(d.localPosition.dy))
            : null,
        onLongPressEnd: picking
            ? (_) {
                final from = dragFrom, to = dragTo;
                setState(() => dragFrom = dragTo = null);
                if (from == null || to == null) return;
                if (!_usable(math.min(from, to))) return _pastHint();
                _pick(from, to);
              }
            : null,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            if (isToday)
              Positioned.fill(
                child: ColoredBox(color: p.inkJiao.withValues(alpha: .02)),
              ),
            for (var h = 0; h <= widget.lastHour - widget.firstHour; h++)
              Positioned(
                top: h * _hourHeight,
                left: 0,
                right: 0,
                child: Container(height: 1, color: p.line),
              ),
            Positioned(
              top: 0,
              left: 0,
              bottom: 0,
              child: Container(width: 1, color: p.line),
            ),
            if (pastUntil > 0)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: pastUntil,
                child: ColoredBox(color: p.inkJiao.withValues(alpha: .025)),
              ),
            if (hoverSlot != null &&
                sel == null &&
                picking &&
                !_occupied(hoverSlot!) &&
                _usable(hoverSlot!))
              Positioned(
                top: hoverSlot! * slotHeight + 2,
                left: 4,
                right: 4,
                height: slotHeight * 2 - 4,
                child: _Ghost(text: '+ ${hm(slotStart(hoverSlot!))}'),
              ),
            if (sel != null)
              Positioned(
                top: sel.$1 * slotHeight + 2,
                left: 4,
                right: 4,
                height: (sel.$2 - sel.$1 + 1) * slotHeight - 4,
                child: _Ghost(
                  text: '${hm(slotStart(sel.$1))}–${hm(slotStart(sel.$2 + 1))}',
                  strong: true,
                ),
              ),
            for (final slice in widget.slices)
              Positioned(
                top: _y(slice.start) + 1.5,
                left: 4,
                right: 4,
                height: math.max(_y(slice.end) - _y(slice.start) - 3, 20),
                child: _BlockChip(
                  slice: slice,
                  mark: widget.markOf?.call(slice.block),
                  showOffset: widget.showOffset,
                  onTap: () => widget.onBlockTap(slice.block),
                ),
              ),
            if (isToday && now.isAfter(origin) && now.isBefore(end))
              Positioned(
                top: _y(now) - 3,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: p.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(child: Container(height: 1.4, color: p.accent)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Ghost extends StatelessWidget {
  const _Ghost({required this.text, this.strong = false});
  final String text;
  final bool strong;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: strong ? p.washStrong : p.wash,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: p.inkJiao.withValues(alpha: strong ? .25 : .1),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.fade,
            style: TextStyle(fontSize: 12, color: p.inkNong),
          ),
        ),
      ),
    );
  }
}

class _BlockChip extends StatelessWidget {
  const _BlockChip({
    required this.slice,
    required this.mark,
    required this.showOffset,
    required this.onTap,
  });
  final DaySlice slice;
  final Color? mark;
  final bool showOffset;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final block = slice.block;
    final protected = block['kind'] == 'protected';
    final finished = ['completed', 'skipped'].contains(block['status']);
    return Semantics(
      button: true,
      label: '${hm(slice.start)}至${hm(slice.end)} ${block['title']}',
      excludeSemantics: true,
      child: Opacity(
        opacity: finished ? .55 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: protected ? null : p.halo,
          ),
          child: Material(
            color: protected ? p.wash : p.paperRaised,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 3,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: protected ? p.inkQing : mark ?? p.inkQing,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(2),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(7, 5, 6, 4),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text:
                                  '${hm(slice.start)}'
                                  '${block['kind'] == 'fixed' ? ' · 定' : ''}'
                                  '${showOffset ? ' ${utcOffset(slice.start.timeZoneOffset)}' : ''}\n',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: p.inkZhong,
                              ),
                            ),
                            TextSpan(
                              text: block['title'],
                              style: TextStyle(
                                fontFamily: 'WenKai',
                                fontSize: 13.5,
                                height: 1.25,
                                color: p.inkJiao,
                              ),
                            ),
                          ],
                        ),
                        overflow: TextOverflow.fade,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
