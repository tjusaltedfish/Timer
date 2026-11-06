import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'controller.dart';
import 'formatting.dart';
import 'theme/tokens.dart';

// 手机周视图（总览 / 单天概览 / 详细课表）经由这里暴露给 `pages/week_page.dart`：
// 那个文件是 home.dart 的 part，不能自己 import。
export 'week/day_overview.dart';
export 'week/mobile_week_view.dart';
export 'week/week_blocks_overview.dart';

/// Called with the chosen start and length when an empty slot is picked.
typedef SlotPicked = void Function(tz.TZDateTime start, int minutes);

/// Called when a block was dragged (moved or stretched) to a new interval.
typedef BlockMoved =
    void Function(Json block, tz.TZDateTime start, tz.TZDateTime end);

/// 拖动改期时对齐到的分钟数。
const dragSnapMinutes = 15;

enum _DragMode { move, resize }

class _BlockDrag {
  _BlockDrag(this.slice, this.mode, this.dayIndex, this.origin);
  final DaySlice slice;
  final _DragMode mode;
  final int dayIndex;
  final Offset origin;
  Offset delta = Offset.zero;
}

/// Where a dragged block would land, and why it cannot (if it cannot).
class _DragTarget {
  const _DragTarget(this.dayIndex, this.start, this.end, this.problem);
  final int dayIndex;
  final tz.TZDateTime start, end;
  final String? problem;
}

const _hourHeight = 56.0, _axisWidth = 48.0, _headerHeight = 54.0;

/// 桌面整周网格每小时的高度：页面本来就能上下滚动，给半小时的块留出
/// 一行「时间 + 标题」的位置，免得挤成一团。
const desktopHourHeight = 72.0;

/// 低于这个高度，时间块改成一行「时间 标题」，不再分两行。
const _twoLineChipHeight = 40.0;

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
    this.sessions = const [],
    required this.zone,
    required this.selectedDay,
    required this.dayStart,
    required this.dayEnd,
    required this.onSelectDay,
    required this.onBlockTap,
    this.now,
    this.onSlotPicked,
    this.onBlockMoved,
    this.markOf,
    this.zoom = 1,
  });
  final List<Json> blocks, tasks, sessions;
  final tz.Location zone;
  final DateTime selectedDay;
  final DateTime? now;
  final String dayStart, dayEnd;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Json> onBlockTap;
  final SlotPicked? onSlotPicked;

  /// 拖动时间块改期/改时长；为空时时间块不能拖。
  final BlockMoved? onBlockMoved;
  final Color? Function(Json block)? markOf;

  /// 放大倍数（默认 1，桌面不受影响）。手机详细课表用 +/− 按钮调它。
  final double zoom;
  @override
  State<WeekCalendar> createState() => _WeekCalendarState();
}

class _WeekCalendarState extends State<WeekCalendar> {
  final scroll = ScrollController();
  double _columnWidth = 0;
  _BlockDrag? _drag;

  /// Only a planned, untouched block that lies within one day can be dragged.
  bool _canDrag(DaySlice slice) {
    if (widget.onBlockMoved == null || slice.actual) return false;
    final block = slice.block;
    if (block['status'] != 'scheduled') return false;
    if (widget.sessions.any((s) => s['block_id'] == block['id'])) return false;
    final start = DateTime.tryParse(block['start_at'] as String? ?? '');
    final end = DateTime.tryParse(block['end_at'] as String? ?? '');
    return start != null &&
        end != null &&
        slice.start.isAtSameMomentAs(start) &&
        slice.end.isAtSameMomentAs(end);
  }

  _DragTarget _target(
    _BlockDrag drag,
    List<DateTime> days,
    int firstHour,
    int lastHour,
    double hourHeight,
  ) {
    int snap(double minutes) =>
        (minutes / dragSnapMinutes).round() * dragSnapMinutes;
    final start = drag.slice.start, end = drag.slice.end;
    final moved = drag.delta.dy / hourHeight * 60;
    final length = end.difference(start).inMinutes;
    final top = firstHour * 60, bottom = lastHour * 60;
    final startMinute = start.hour * 60 + start.minute;
    late final int dayIndex;
    late final tz.TZDateTime from, to;
    if (drag.mode == _DragMode.resize) {
      dayIndex = drag.dayIndex;
      final endMinute = startMinute + length;
      final latest = math.min(bottom, startMinute + 24 * 60);
      final target = snap(endMinute + moved)
          .clamp(startMinute + dragSnapMinutes, math.max(latest, endMinute))
          .toInt();
      from = start;
      to = start.add(Duration(minutes: target - startMinute));
    } else {
      final shift = _columnWidth == 0
          ? 0
          : (drag.delta.dx / _columnWidth).round().clamp(
              -drag.dayIndex,
              days.length - 1 - drag.dayIndex,
            );
      dayIndex = drag.dayIndex + shift;
      // Keep the block inside the visible hours when it fits there.
      final latestStart = math.max(top, bottom - length);
      final target = snap(startMinute + moved).clamp(top, latestStart).toInt();
      final day = days[dayIndex];
      from = tz.TZDateTime(widget.zone, day.year, day.month, day.day, 0, target);
      to = from.add(Duration(minutes: length));
    }
    return _DragTarget(dayIndex, from, to, _problem(drag.slice.block, from, to));
  }

  String? _problem(Json block, tz.TZDateTime start, tz.TZDateTime end) {
    final now = widget.now;
    if (now != null && start.isBefore(now)) return '这段时间已经过去了';
    for (final other in widget.blocks) {
      if (other['id'] == block['id'] || other['status'] != 'scheduled') {
        continue;
      }
      final a = DateTime.tryParse(other['start_at'] as String? ?? '');
      final b = DateTime.tryParse(other['end_at'] as String? ?? '');
      if (a != null && b != null && start.isBefore(b) && end.isAfter(a)) {
        return '和「${other['title']}」撞了';
      }
    }
    return null;
  }

  void _dragStart(DaySlice slice, _DragMode mode, int dayIndex, Offset at) =>
      setState(() => _drag = _BlockDrag(slice, mode, dayIndex, at));

  void _dragUpdate(Offset at) {
    final drag = _drag;
    if (drag == null) return;
    setState(() => drag.delta = at - drag.origin);
  }

  void _dragEnd(_DragTarget? target) {
    final drag = _drag;
    setState(() => _drag = null);
    if (drag == null || target == null) return;
    if (target.start.isAtSameMomentAs(drag.slice.start) &&
        target.end.isAtSameMomentAs(drag.slice.end)) {
      return;
    }
    if (target.problem != null) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('没挪过去：${target.problem}。')),
        );
      return;
    }
    widget.onBlockMoved?.call(drag.slice.block, target.start, target.end);
  }

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
    if (dateKey(oldWidget.selectedDay) != dateKey(widget.selectedDay) ||
        oldWidget.zoom != widget.zoom) {
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
        for (final day in days)
          day: daySlices(
            widget.blocks,
            day,
            widget.zone,
            sessions: widget.sessions,
          ),
      };
      final (first, last) = visibleHours(
        slices.values.expand((s) => s),
        widget.dayStart,
        widget.dayEnd,
      );
      final zoom = widget.zoom.clamp(.75, 2.0).toDouble();
      final available = constraints.maxWidth - _axisWidth;
      // 放大后固定列宽会超出屏幕，所以 zoom > 1 时走横向滚动那一支。
      final fits = available >= 7 * 96 && zoom <= 1;
      // 七列并排放得下（桌面）时用更高的行；手机详细课表仍按 zoom 走。
      final hourHeight = fits && zoom == 1
          ? desktopHourHeight
          : _hourHeight * zoom;
      _columnWidth = fits
          ? available / 7
          : math.max(available / 3.2, 96) * zoom;
      final gridHeight = (last - first) * hourHeight;
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
      final drag = _drag;
      final target = drag == null
          ? null
          : _target(drag, days, first, last, hourHeight);
      final columns = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, day) in days.indexed)
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
                      hourHeight: hourHeight,
                      slices: slices[day]!,
                      tasks: widget.tasks,
                      now: widget.now,
                      showOffset: changingOffset,
                      onBlockTap: widget.onBlockTap,
                      onSlotPicked: widget.onSlotPicked,
                      markOf: widget.markOf,
                      canDrag: _canDrag,
                      draggingId: drag?.slice.block['id'] as String?,
                      preview: target?.dayIndex == index ? target : null,
                      previewTitle: drag?.slice.block['title'] as String?,
                      onDragStart: (slice, mode, at) =>
                          _dragStart(slice, mode, index, at),
                      onDragUpdate: _dragUpdate,
                      onDragEnd: () => _dragEnd(
                        _drag == null
                            ? null
                            : _target(_drag!, days, first, last, hourHeight),
                      ),
                      onDragCancel: () => setState(() => _drag = null),
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
                        height: hourHeight,
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
                widget.onBlockMoved == null
                    ? '点空白处安排一件事；长按后上下拖动，可以圈出一段时间。'
                    : '点空白处安排一件事；长按后上下拖动，可以圈出一段时间。'
                          '拖动时间块可以改期，拖它的下边缘改时长（手机上先长按）。',
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
    required this.hourHeight,
    required this.slices,
    required this.tasks,
    required this.now,
    required this.showOffset,
    required this.onBlockTap,
    required this.onSlotPicked,
    required this.markOf,
    required this.canDrag,
    required this.draggingId,
    required this.preview,
    required this.previewTitle,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });
  final DateTime day;
  final DateTime? now;
  final tz.Location zone;
  final int firstHour, lastHour;
  final double hourHeight;
  final List<DaySlice> slices;
  final List<Json> tasks;
  final bool showOffset;
  final ValueChanged<Json> onBlockTap;
  final SlotPicked? onSlotPicked;
  final Color? Function(Json block)? markOf;
  final bool Function(DaySlice slice) canDrag;
  final String? draggingId;
  final _DragTarget? preview;
  final String? previewTitle;
  final void Function(DaySlice slice, _DragMode mode, Offset at) onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd, onDragCancel;
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
      (dy / (widget.hourHeight * slotMinutes / 60)).floor().clamp(0, slotCount - 1);
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

  double _y(DateTime t) =>
      t.difference(origin).inSeconds / 3600 * widget.hourHeight;

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
    final slotHeight = widget.hourHeight * slotMinutes / 60;
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
        child: LayoutBuilder(
          builder: (context, box) {
            final lanes = sliceLanes(widget.slices);
            final cell = box.maxWidth - 8;
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
            if (isToday)
              Positioned.fill(
                child: ColoredBox(color: p.inkJiao.withValues(alpha: .02)),
              ),
            for (var h = 0; h <= widget.lastHour - widget.firstHour; h++)
              Positioned(
                top: h * widget.hourHeight,
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
            for (var i = 0; i < widget.slices.length; i++)
              Positioned(
                top: _y(widget.slices[i].start) + 1.5,
                left: 4 + lanes[i].lane * cell / lanes[i].lanes,
                width:
                    cell / lanes[i].lanes - (lanes[i].lanes > 1 ? 1 : 0),
                height: math.max(
                  _y(widget.slices[i].end) -
                      _y(widget.slices[i].start) -
                      3,
                  20,
                ),
                child: _BlockChip(
                  key: ValueKey('week.block.${widget.slices[i].block['id']}'),
                  slice: widget.slices[i],
                  mark: widget.markOf?.call(widget.slices[i].block),
                  showOffset: widget.showOffset,
                  lifted:
                      widget.draggingId != null &&
                      widget.draggingId == widget.slices[i].block['id'],
                  onTap: () => widget.onBlockTap(widget.slices[i].block),
                  drag: widget.canDrag(widget.slices[i])
                      ? _ChipDrag(
                          start: (mode, at) =>
                              widget.onDragStart(widget.slices[i], mode, at),
                          update: widget.onDragUpdate,
                          end: widget.onDragEnd,
                          cancel: widget.onDragCancel,
                        )
                      : null,
                ),
              ),
            if (widget.preview case final target?)
              Positioned(
                top: _y(target.start) + 1.5,
                left: 4,
                right: 4,
                height: math.max(_y(target.end) - _y(target.start) - 3, 20),
                child: _Ghost(
                  key: const Key('week.drag.preview'),
                  text:
                      '${hm(target.start)}–${hm(target.end)}'
                      '${target.problem == null ? ' ${widget.previewTitle ?? ''}' : ' · ${target.problem}'}',
                  strong: true,
                  warn: target.problem != null,
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
            );
          },
        ),
      ),
    );
  }
}

class _Ghost extends StatelessWidget {
  const _Ghost({
    super.key,
    required this.text,
    this.strong = false,
    this.warn = false,
  });
  final String text;
  final bool strong, warn;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: strong ? p.washStrong : p.wash,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: warn
                ? p.accent
                : p.inkJiao.withValues(alpha: strong ? .25 : .1),
            width: warn ? 1.4 : 1,
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

/// Drag callbacks for one chip; positions are global.
class _ChipDrag {
  const _ChipDrag({
    required this.start,
    required this.update,
    required this.end,
    required this.cancel,
  });
  final void Function(_DragMode mode, Offset at) start;
  final ValueChanged<Offset> update;
  final VoidCallback end, cancel;

  /// Mouse: press and drag right away. Touch: long-press first so the page
  /// still scrolls under a finger.
  Widget wrap(_DragMode mode, Widget child) => GestureDetector(
    supportedDevices: const {PointerDeviceKind.mouse},
    dragStartBehavior: DragStartBehavior.down,
    behavior: HitTestBehavior.opaque,
    onPanStart: (d) => start(mode, d.globalPosition),
    onPanUpdate: (d) => update(d.globalPosition),
    onPanEnd: (_) => end(),
    onPanCancel: cancel,
    child: GestureDetector(
      supportedDevices: const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.unknown,
      },
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (d) => start(mode, d.globalPosition),
      onLongPressMoveUpdate: (d) => update(d.globalPosition),
      onLongPressEnd: (_) => end(),
      onLongPressCancel: cancel,
      child: child,
    ),
  );
}

class _BlockChip extends StatelessWidget {
  const _BlockChip({
    super.key,
    required this.slice,
    required this.mark,
    required this.showOffset,
    required this.onTap,
    this.drag,
    this.lifted = false,
  });
  final DaySlice slice;
  final Color? mark;
  final bool showOffset;
  final VoidCallback onTap;
  final _ChipDrag? drag;

  /// The block is being dragged: its old place stays as a faint outline.
  final bool lifted;
  @override
  Widget build(BuildContext context) {
    final drag = this.drag;
    final chip = _chip(context);
    if (drag == null) return chip;
    return drag.wrap(
      _DragMode.move,
      Stack(
        fit: StackFit.expand,
        children: [
          chip,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 8,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: drag.wrap(
                _DragMode.resize,
                const SizedBox.expand(key: Key('week.block.resize')),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context) {
    final p = context.inkPalette;
    final block = slice.block;
    final protected = block['kind'] == 'protected';
    final finished = ['completed', 'skipped'].contains(block['status']);
    final time =
        '${hm(slice.start)}'
        '${block['kind'] == 'fixed' ? ' · 定' : ''}'
        '${showOffset ? ' ${utcOffset(slice.start.timeZoneOffset)}' : ''}';
    final timeStyle = TextStyle(fontSize: 10.5, color: p.inkZhong);
    final titleStyle = TextStyle(
      fontFamily: 'WenKai',
      fontSize: 13.5,
      height: 1.25,
      color: p.inkJiao,
    );
    return Semantics(
      button: true,
      label: '${hm(slice.start)}至${hm(slice.end)} ${block['title']}',
      excludeSemantics: true,
      child: Opacity(
        opacity: lifted
            ? .3
            : finished
            ? .55
            : 1,
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
              child: LayoutBuilder(
                builder: (context, box) {
                  final height = box.maxHeight;
                  final twoLines = height >= _twoLineChipHeight;
                  // 短块的色条跟着变短，不再缩成一个点。
                  final barInset = twoLines
                      ? 8.0
                      : ((height - 8) / 4).clamp(2.0, 6.0).toDouble();
                  final compactTitle = height < 26
                      ? titleStyle.copyWith(fontSize: 12, height: 1.1)
                      : titleStyle.copyWith(height: 1.15);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 3,
                        margin: EdgeInsets.symmetric(vertical: barInset),
                        decoration: BoxDecoration(
                          color: protected ? p.inkQing : mark ?? p.inkQing,
                          borderRadius: const BorderRadius.horizontal(
                            right: Radius.circular(2),
                          ),
                        ),
                      ),
                      Expanded(
                        child: twoLines
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(7, 5, 6, 4),
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: '$time\n',
                                        style: timeStyle,
                                      ),
                                      TextSpan(
                                        text: block['title'],
                                        style: titleStyle,
                                      ),
                                    ],
                                  ),
                                  overflow: TextOverflow.fade,
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                          text: '$time ',
                                          style: timeStyle,
                                        ),
                                        TextSpan(
                                          text: block['title'],
                                          style: compactTitle,
                                        ),
                                      ],
                                    ),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
