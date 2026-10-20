import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../calendar.dart';
import '../controller.dart';
import '../formatting.dart';
import '../theme/tokens.dart';

/// Fit the whole week into the available height; details live below the map.
class WeekOverview extends StatelessWidget {
  const WeekOverview({
    super.key,
    required this.blocks,
    required this.day,
    required this.now,
    required this.zone,
    required this.onSelectDay,
    required this.onBlockTap,
    required this.dayStart,
    required this.dayEnd,
  });
  final List<Json> blocks;
  final DateTime day, now;
  final tz.Location zone;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Json> onBlockTap;
  final String dayStart, dayEnd;

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final monday = DateTime(day.year, day.month, day.day - day.weekday + 1);
    final days = List.generate(
      7,
      (i) => DateTime(monday.year, monday.month, monday.day + i),
    );
    final slices = [for (final d in days) daySlices(blocks, d, zone)];
    var first = int.parse(dayStart.split(':')[0]);
    var last =
        int.parse(dayEnd.split(':')[0]) + (dayEnd.endsWith(':00') ? 0 : 1);
    for (final slice in slices.expand((v) => v)) {
      first = math.min(first, slice.start.hour);
      last = math.max(last, slice.end.hour == 0 ? 24 : slice.end.hour + 1);
    }
    last = last.clamp(first + 1, 24);
    final selected = daySlices(blocks, day, zone);
    return LayoutBuilder(
      builder: (context, bounds) {
        final chartHeight = (bounds.maxHeight * .58).clamp(180.0, 390.0);
        final range = (last - first) * 60;
        double position(tz.TZDateTime t, {bool end = false}) =>
            ((end && t.hour == 0 ? 1440 : t.hour * 60 + t.minute) -
                first * 60) /
            range;
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
                    width: 32,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 48),
                      child: SizedBox(
                        height: chartHeight,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            for (var h = first; h <= last; h += 2)
                              Positioned(
                                top:
                                    (h - first) / (last - first) * chartHeight -
                                    6,
                                child: Text(
                                  '$h',
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
                                  borderRadius: BorderRadius.circular(8),
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
                                child: Stack(
                                  children: [
                                    for (var h = first; h < last; h += 2)
                                      Positioned(
                                        top:
                                            (h - first) /
                                            (last - first) *
                                            chartHeight,
                                        left: 0,
                                        right: 0,
                                        child: Container(
                                          height: 1,
                                          color: p.line,
                                        ),
                                      ),
                                    for (final slice in slices[i])
                                      Positioned(
                                        top:
                                            position(slice.start) * chartHeight,
                                        left: 3,
                                        right: 3,
                                        height: math.max(
                                          3,
                                          (position(slice.end, end: true) -
                                                  position(slice.start)) *
                                              chartHeight,
                                        ),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color:
                                                slice.block['kind'] ==
                                                    'protected'
                                                ? p.inkQing
                                                : p.inkNong,
                                            borderRadius: BorderRadius.circular(
                                              3,
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
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${day.month}月${day.day}日 · ${selected.length} 段安排',
              style: Theme.of(context).textTheme.titleMedium,
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
                            title: Text(slice.block['title']),
                            subtitle: Text(
                              '${hm(slice.start)}—${hm(slice.end)}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
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
}
