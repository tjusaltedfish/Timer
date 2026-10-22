import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../calendar.dart';
import '../controller.dart';
import '../formatting.dart';
import '../theme/schedule_ink.dart';
import '../theme/tokens.dart';

/// 手机上的整周色块总览：7 列，一天一列。
///
/// 一列就是一天；当天的安排按时间先后从上往下叠放，颜色区分事情（一色一事），
/// 标题尽量写在色块里，放不下的截断，长按看全名。点某一天进入单天概览，
/// 点某个色块直接打开那件事。
class WeekBlocksOverview extends StatelessWidget {
  const WeekBlocksOverview({
    super.key,
    required this.blocks,
    required this.tasks,
    this.sessions = const [],
    required this.day,
    required this.now,
    required this.zone,
    required this.dayStart,
    required this.dayEnd,
    required this.onSelectDay,
    required this.onBlockTap,
  });

  final List<Json> blocks;
  final List<Json> tasks;
  final List<Json> sessions;
  final DateTime day;
  final DateTime now;
  final tz.Location zone;
  final String dayStart;
  final String dayEnd;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Json> onBlockTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.inkPalette;
    final brightness = Theme.of(context).brightness;
    Color pigment(Json block) => block['kind'] == 'protected'
        ? palette.inkZhong
        : ScheduleInk.forTask(
            block['task_id'] ?? block['id'],
            tasks,
            brightness,
          );
    final monday = DateTime(day.year, day.month, day.day - day.weekday + 1);
    final days = List.generate(
      7,
      (index) => DateTime(monday.year, monday.month, monday.day + index),
    );
    final slices = [
      for (final date in days) daySlices(blocks, date, zone, sessions: sessions),
    ];
    final (first, last) = _visibleHours(
      slices.expand((value) => value),
      dayStart,
      dayEnd,
    );
    final empty = slices.every((value) => value.isEmpty);
    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < 7; index++)
              Expanded(
                child: _DayColumn(
                  key: ValueKey('week.day.$index'),
                  date: days[index],
                  selected: dateKey(days[index]) == dateKey(day),
                  today: dateKey(days[index]) == dateKey(now),
                  slices: slices[index],
                  now: now,
                  zone: zone,
                  firstHour: first,
                  lastHour: last,
                  pigment: pigment,
                  onSelectDay: onSelectDay,
                  onBlockTap: onBlockTap,
                ),
              ),
          ],
        ),
        if (empty) const Positioned.fill(child: IgnorePointer(child: _EmptyWeek())),
      ],
    );
  }
}

/// 与 WeekCalendar 相同的可见小时范围，保证两种视图的纵轴一致。
(int, int) _visibleHours(
  Iterable<DaySlice> slices,
  String dayStart,
  String dayEnd,
) {
  final firstDay = math.max(0, int.tryParse(dayStart.split(':').first) ?? 0);
  final lastDay = math.max(
    firstDay + 1,
    int.tryParse(dayEnd.split(':').first) ?? 24,
  );
  var first = firstDay;
  var last = lastDay + (dayEnd.endsWith(':00') ? 0 : 1);
  for (final slice in slices) {
    first = math.min(first, slice.start.hour);
    final crossDayEnd = slice.end.day != slice.start.day && slice.end.hour == 0;
    final endHour =
        crossDayEnd ? 24 : slice.end.hour + (slice.end.minute > 0 ? 1 : 0);
    last = math.max(last, endHour);
  }
  final upper = math.min(math.max(last, first + 1), 24);
  final lower = math.min(first, upper - 1);
  return (lower, upper);
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    super.key,
    required this.date,
    required this.selected,
    required this.today,
    required this.slices,
    required this.now,
    required this.zone,
    required this.firstHour,
    required this.lastHour,
    required this.pigment,
    required this.onSelectDay,
    required this.onBlockTap,
  });

  final DateTime date;
  final bool selected;
  final bool today;
  final List<DaySlice> slices;
  final DateTime now;
  final tz.Location zone;
  final int firstHour;
  final int lastHour;
  final Color Function(Json block) pigment;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Json> onBlockTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.inkPalette;
    final span = math.max(1, lastHour - firstHour);
    return Semantics(
      button: true,
      selected: selected,
      label: '${date.month}月${date.day}日 '
          '${weekdays[date.weekday - 1]}，${slices.length} 段安排',
      child: InkWell(
        onTap: () => onSelectDay(date),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1.5),
          child: Column(
            children: [
              _Header(date: date, selected: selected, today: today),
              const SizedBox(height: 4),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final height = box.maxHeight;
                    final width = box.maxWidth;
                    final origin = tz.TZDateTime(
                      zone,
                      date.year,
                      date.month,
                      date.day,
                      firstHour,
                    );
                    double fraction(tz.TZDateTime time) {
                      final minutes = time.difference(origin).inMinutes;
                      return (minutes / (span * 60)).clamp(0.0, 1.0).toDouble();
                    }

                    final lanes = sliceLanes(slices);
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        children: [
                          if (today)
                            Positioned.fill(
                              child: ColoredBox(
                                color: palette.inkJiao.withValues(alpha: .022),
                              ),
                            ),
                          for (var hour = firstHour;
                              hour <= lastHour;
                              hour += 2)
                            Positioned(
                              top: (hour - firstHour) / span * height,
                              left: 0,
                              right: 0,
                              child: Container(
                                height: 1,
                                color: palette.line.withValues(alpha: .6),
                              ),
                            ),
                          for (var index = 0; index < slices.length; index++)
                            _Stamp(
                              slice: slices[index],
                              top: fraction(slices[index].start) * height + 1,
                              height: math.max(
                                fraction(slices[index].end) * height -
                                    fraction(slices[index].start) * height -
                                    2,
                                14,
                              ),
                              left: 1 + lanes[index].lane * width / lanes[index].lanes,
                              width: width / lanes[index].lanes - 2,
                              pigment: pigment(slices[index].block),
                              brightness: Theme.of(context).brightness,
                              onTap: () => onBlockTap(slices[index].block),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.date,
    required this.selected,
    required this.today,
  });

  final DateTime date;
  final bool selected;
  final bool today;

  @override
  Widget build(BuildContext context) {
    final palette = context.inkPalette;
    final label =
        today ? '今' : weekdays[date.weekday - 1].replaceFirst('周', '');
    return SizedBox(
      height: 44,
      child: Center(
        child: AnimatedContainer(
          duration: InkMetrics.micro,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          decoration: BoxDecoration(
            color: selected ? palette.inkJiao : null,
            borderRadius: BorderRadius.circular(10),
            border: today && !selected
                ? Border.all(color: palette.inkZhong, width: .8)
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.1,
                  color: selected
                      ? palette.paper
                      : (today ? palette.inkJiao : palette.inkZhong),
                ),
              ),
              Text(
                '${date.day}',
                style: TextStyle(
                  fontSize: 15,
                  fontFamily: 'WenKai',
                  height: 1.15,
                  color: selected ? palette.paper : palette.inkJiao,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stamp extends StatelessWidget {
  const _Stamp({
    required this.slice,
    required this.top,
    required this.height,
    required this.left,
    required this.width,
    required this.pigment,
    required this.brightness,
    required this.onTap,
  });

  final DaySlice slice;
  final double top;
  final double height;
  final double left;
  final double width;
  final Color pigment;
  final Brightness brightness;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.inkPalette;
    final title = slice.block['title'] as String? ?? '未命名';
    final showTime = height >= 30;
    final maxLines = height >= 44 ? 3 : (height >= 22 ? 2 : 1);
    return Positioned(
      key: ValueKey('week.stamp.${slice.block['id']}'),
      top: top,
      left: left,
      width: width,
      height: height,
      child: Tooltip(
        message: '$title\n${hm(slice.start)}—${hm(slice.end)}',
        waitDuration: const Duration(milliseconds: 350),
        child: Semantics(
          button: true,
          label: '$title，${hm(slice.start)}至${hm(slice.end)}',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ColoredBox(
                color: pigment.withValues(alpha: ScheduleInk.tint(brightness)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 3, child: ColoredBox(color: pigment)),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(3, 2, 2, 2),
                        child: Text(
                          showTime ? '${hm(slice.start)}\n$title' : title,
                          maxLines: maxLines,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: showTime ? 9.5 : 8.5,
                            height: 1.25,
                            color: brightness == Brightness.dark
                                ? palette.paper
                                : palette.inkJiao,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyWeek extends StatelessWidget {
  const _EmptyWeek();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.inkPalette;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: palette.paper.withValues(alpha: .92),
          borderRadius: BorderRadius.circular(16),
          boxShadow: palette.halo,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('这周还空着', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('点下面任意一天，开始排第一件事。',
                style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
