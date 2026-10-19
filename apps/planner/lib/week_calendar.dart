import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'controller.dart';
import 'theme/tokens.dart';

class WeekCalendar extends StatelessWidget {
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
  });
  final List<Json> blocks, tasks;
  final tz.Location zone;
  final DateTime selectedDay;
  final String dayStart, dayEnd;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Json> onBlockTap;

  String hm(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final monday = DateTime(
        selectedDay.year,
        selectedDay.month,
        selectedDay.day - selectedDay.weekday + 1,
      );
      final days = constraints.maxWidth < 650
          ? [selectedDay]
          : List.generate(
              7,
              (i) => DateTime(monday.year, monday.month, monday.day + i),
            );
      final slices = {
        for (final day in days) day: daySlices(blocks, day, zone),
      };
      var firstHour = int.parse(dayStart.split(':').first);
      var lastHour =
          int.parse(dayEnd.split(':').first) + (dayEnd.endsWith(':00') ? 0 : 1);
      for (final day in days) {
        for (final slice in slices[day]!) {
          firstHour = math.min(firstHour, slice.start.hour);
          final endHour = slice.end.day != day.day
              ? 24
              : slice.end.hour + (slice.end.minute > 0 ? 1 : 0);
          lastHour = math.max(lastHour, endHour);
        }
      }
      final starts = {
        for (final day in days)
          day: tz.TZDateTime(zone, day.year, day.month, day.day, firstHour),
      };
      final ends = {
        for (final day in days)
          day: tz.TZDateTime(zone, day.year, day.month, day.day, lastHour),
      };
      final height = days
          .map((day) => ends[day]!.difference(starts[day]!).inMinutes)
          .reduce(math.max)
          .toDouble();
      final changingOffset = days.any(
        (day) => starts[day]!.timeZoneOffset != ends[day]!.timeZoneOffset,
      );
      final axisStart = starts[days.first]!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (changingOffset)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                '本周有夏令时切换；时间块按实际持续时长显示，并标明 UTC 偏移。',
                style: TextStyle(fontSize: 11),
              ),
            ),
          GestureDetector(
            excludeFromSemantics: true,
            onHorizontalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0).abs() > 100) {
                onSelectDay(
                  DateTime(
                    selectedDay.year,
                    selectedDay.month,
                    selectedDay.day + (details.primaryVelocity! < 0 ? 1 : -1),
                  ),
                );
              }
            },
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 45,
                  child: Column(
                    children: [
                      const SizedBox(height: 48),
                      for (var minute = 0; minute < height; minute += 60)
                        SizedBox(
                          height: 60,
                          child: Text(
                            hm(axisStart.add(Duration(minutes: minute))),
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                    ],
                  ),
                ),
                for (final day in days)
                  Expanded(
                    child: Column(
                      children: [
                        SizedBox(
                          height: 48,
                          child: Center(
                            child: Text(
                              '${['周一', '周二', '周三', '周四', '周五', '周六', '周日'][day.weekday - 1]} ${day.day}',
                            ),
                          ),
                        ),
                        SizedBox(
                          height: height,
                          child: Stack(
                            children: [
                              for (
                                var minute = 0;
                                minute < height;
                                minute += 60
                              )
                                Positioned(
                                  top: minute.toDouble(),
                                  left: 0,
                                  right: 0,
                                  child: const Divider(height: 1),
                                ),
                              for (final slice in slices[day]!)
                                Positioned(
                                  top: slice.start
                                      .difference(starts[day]!)
                                      .inMinutes
                                      .toDouble(),
                                  left: 3,
                                  right: 3,
                                  height: slice.end
                                      .difference(slice.start)
                                      .inMinutes
                                      .toDouble()
                                      .clamp(18, 1440)
                                      .toDouble(),
                                  child: Semantics(
                                    button: true,
                                    label:
                                        '${hm(slice.start)}至${hm(slice.end)} ${slice.block['title']}',
                                    child: Material(
                                      color: slice.block['kind'] == 'protected'
                                          ? context.inkPalette.wash
                                          : context.inkPalette.paperRaised,
                                      borderRadius: BorderRadius.circular(6),
                                      child: InkWell(
                                        onTap: () => onBlockTap(slice.block),
                                        borderRadius: BorderRadius.circular(6),
                                        child: Padding(
                                          padding: const EdgeInsets.all(5),
                                          child: Text(
                                            '${hm(slice.start)}${slice.block['kind'] == 'fixed' ? ' ⌑' : ''}\n${slice.block['title']}${changingOffset ? '\n${utcOffset(slice.start.timeZoneOffset)}' : ''}',
                                            overflow: TextOverflow.fade,
                                            style: const TextStyle(
                                              fontSize: 10,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
