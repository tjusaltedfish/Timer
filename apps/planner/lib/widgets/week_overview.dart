import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../calendar.dart';
import '../controller.dart';
import '../formatting.dart';
import '../theme/schedule_ink.dart';
import '../theme/tokens.dart';

/// A whole-week map: position means time, pigment and short titles identify work.
class WeekOverview extends StatelessWidget {
  const WeekOverview({
    super.key,
    required this.blocks,
    required this.tasks,
    this.sessions = const [],
    required this.day,
    required this.now,
    required this.zone,
    required this.onSelectDay,
    required this.onBlockTap,
    required this.dayStart,
    required this.dayEnd,
  });
  final List<Json> blocks, tasks, sessions;
  final DateTime day, now;
  final tz.Location zone;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Json> onBlockTap;
  final String dayStart, dayEnd;

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final brightness = Theme.of(context).brightness;
    Color pigment(Json block) => block['kind'] == 'protected'
        ? p.inkZhong
        : ScheduleInk.forTask(
            block['task_id'] ?? block['id'],
            tasks,
            brightness,
          );
    final monday = DateTime(day.year, day.month, day.day - day.weekday + 1);
    final days = List.generate(
      7,
      (i) => DateTime(monday.year, monday.month, monday.day + i),
    );
    final slices = [
      for (final d in days)
        daySlices(blocks, d, zone, sessions: sessions),
    ];
    var first = int.parse(dayStart.split(':')[0]);
    var last =
        int.parse(dayEnd.split(':')[0]) + (dayEnd.endsWith(':00') ? 0 : 1);
    for (final slice in slices.expand((v) => v)) {
      first = math.min(first, slice.start.hour);
      last = math.max(
        last,
        slice.end.hour == 0
            ? 24
            : slice.end.hour + (slice.end.minute > 0 ? 1 : 0),
      );
    }
    last = last.clamp(first + 1, 24);
    final selected = daySlices(blocks, day, zone, sessions: sessions);
    return LayoutBuilder(
      builder: (context, bounds) {
        final chartHeight = math.min(
          380.0,
          math.max(72.0, bounds.maxHeight * .57),
        );
        final range = (last - first) * 60;
        double position(tz.TZDateTime t, {bool end = false}) =>
            (((end && t.hour == 0 ? 1440 : t.hour * 60 + t.minute) -
                        first * 60) /
                    range *
                    chartHeight)
                .clamp(0, chartHeight);
        final ticks = [for (var h = first; h < last; h += 2) h, last];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              key: const Key('week.overview'),
              height: chartHeight + 48,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 30,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 48),
                      child: SizedBox(
                        height: chartHeight,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            for (final h in ticks)
                              Positioned(
                                top:
                                    (h - first) / (last - first) * chartHeight -
                                    6,
                                child: Text(
                                  h.toString().padLeft(2, '0'),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: p.inkZhong,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Semantics(
                        label:
                            '${days[i].month}月${days[i].day}日，${slices[i].length} 段安排',
                        selected: dateKey(days[i]) == dateKey(day),
                        button: true,
                        child: InkWell(
                          key: ValueKey('week.day.$i'),
                          onTap: () => onSelectDay(days[i]),
                          child: Column(
                            children: [
                              Container(
                                height: 44,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: dateKey(days[i]) == dateKey(day)
                                      ? p.inkJiao
                                      : null,
                                  borderRadius: BorderRadius.circular(14),
                                  border:
                                      dateKey(days[i]) == dateKey(now) &&
                                          dateKey(days[i]) != dateKey(day)
                                      ? Border.all(color: p.inkZhong)
                                      : null,
                                ),
                                child: Text(
                                  '${dateKey(days[i]) == dateKey(now) ? '今' : weekdays[i].replaceFirst('周', '')}\n${days[i].day}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: dateKey(days[i]) == dateKey(day)
                                        ? p.paper
                                        : p.inkJiao,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                height: chartHeight,
                                child: LayoutBuilder(
                                  builder: (context, box) {
                                    final lanes = sliceLanes(slices[i]);
                                    return Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                    if (dateKey(days[i]) == dateKey(day))
                                      Positioned.fill(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: p.wash.withValues(
                                              alpha: .025,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                        ),
                                      ),
                                    for (final h in ticks)
                                      Positioned(
                                        top:
                                            (h - first) /
                                            (last - first) *
                                            chartHeight,
                                        left: 0,
                                        right: 0,
                                        child: Container(
                                          height: .6,
                                          color: p.line,
                                        ),
                                      ),
                                    for (var j = 0; j < slices[i].length; j++)
                                      _stamp(
                                        context,
                                        slices[i][j],
                                        pigment(slices[i][j].block),
                                        position(slices[i][j].start),
                                        position(slices[i][j].end, end: true) -
                                            position(slices[i][j].start),
                                        // Close appointments keep their accurate marks; the
                                        // day list and tooltip carry titles that cannot fit.
                                        j == 0 ||
                                            position(slices[i][j].start) -
                                                    position(
                                                      slices[i][j - 1].start,
                                                    ) >=
                                                18,
                                        chartHeight,
                                        lane: lanes[j].lane,
                                        lanes: lanes[j].lanes,
                                        width: box.maxWidth,
                                      ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Text(
                  '${day.month}月${day.day}日',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(width: 10),
                Text(
                  '${selected.length} 段安排',
                  style: TextStyle(color: p.inkZhong, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: selected.isEmpty
                  ? const Align(
                      alignment: Alignment.topLeft,
                      child: Text('这一天还空着。'),
                    )
                  : ListView(
                      children: [
                        for (final slice in selected)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            onTap: () => onBlockTap(slice.block),
                            leading: Container(
                              width: 4,
                              height: 28,
                              decoration: BoxDecoration(
                                color: pigment(slice.block),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            minLeadingWidth: 12,
                            horizontalTitleGap: 10,
                            title: Text(slice.block['title']),
                            subtitle: Text(
                              '${hm(slice.start)}—${hm(slice.end)}'
                              '${slice.differsFromPlan ? '  · 原定 ${hm(slice.plannedStart!)}—${hm(slice.plannedEnd!)}' : ''}',
                            ),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                          ),
                        const SizedBox(height: 70),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _stamp(
    BuildContext context,
    DaySlice slice,
    Color pigment,
    double top,
    double height,
    bool label,
    double chartHeight, {
    int lane = 0,
    int lanes = 1,
    double width = 0,
  }) {
    final title = slice.block['title'] as String;
    final count = height >= 40 ? 8 : 4;
    final brief = title.characters.take(count).join();
    final cell = (width - 4) / lanes;
    return Positioned(
      key: ValueKey('week.stamp.${slice.block['id']}'),
      top: top,
      left: 2 + lane * cell,
      width: lanes > 1 ? cell - 1 : width - 4,
      height: math.min(math.max(18, height), chartHeight - top),
      child: Tooltip(
        message: '$title\n${hm(slice.start)}—${hm(slice.end)}',
        waitDuration: const Duration(milliseconds: 350),
        child: Semantics(
          label: '$title，${hm(slice.start)}至${hm(slice.end)}',
          button: true,
          child: InkWell(
            onTap: () => onBlockTap(slice.block),
            borderRadius: BorderRadius.circular(6),
            // A flat, faint tint with a solid bar on the left: the colour only
            // tells tasks apart, the words stay in ink.
            child: Stack(
              children: [
                Positioned.fill(
                  top: 1,
                  bottom: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: pigment.withValues(
                        alpha: ScheduleInk.tint(Theme.of(context).brightness),
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
                Positioned(
                  top: 1,
                  bottom: 1,
                  left: 0,
                  width: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: pigment,
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(6),
                      ),
                    ),
                  ),
                ),
                if (label)
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4, right: 1),
                      child: Center(
                        child: Text(
                          brief,
                          textAlign: TextAlign.center,
                          maxLines: height >= 40 ? 2 : 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.25,
                            color: context.inkPalette.inkJiao,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
