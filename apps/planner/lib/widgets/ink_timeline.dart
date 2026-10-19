import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../calendar.dart';
import '../controller.dart';
import '../formatting.dart';
import '../theme/tokens.dart';
import 'ink_card.dart';

class InkTimeline extends StatelessWidget {
  const InkTimeline({
    super.key,
    required this.blocks,
    required this.tasks,
    required this.zone,
    required this.day,
    required this.now,
    required this.dayStart,
    required this.dayEnd,
    required this.onBlockTap,
  });
  final List<Json> blocks, tasks;
  final tz.Location zone;
  final DateTime day, now;
  final String dayStart, dayEnd;
  final ValueChanged<Json> onBlockTap;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette, slices = daySlices(blocks, day, zone);
    var first = int.parse(dayStart.split(':').first);
    var last =
        int.parse(dayEnd.split(':').first) + (dayEnd.endsWith(':00') ? 0 : 1);
    for (final s in slices) {
      first = math.min(first, s.start.hour);
      last = math.max(
        last,
        s.end.day != day.day ? 24 : s.end.hour + (s.end.minute > 0 ? 1 : 0),
      );
    }
    final start = tz.TZDateTime(zone, day.year, day.month, day.day, first);
    final end = tz.TZDateTime(zone, day.year, day.month, day.day, last);
    final height = end.difference(start).inMinutes.toDouble();
    return SingleChildScrollView(
      child: SizedBox(
        height: height + 24,
        child: Stack(
          children: [
            for (var minute = 0; minute <= height; minute += 60) ...[
              Positioned(
                top: minute.toDouble(),
                left: 0,
                child: Text(
                  hm(start.add(Duration(minutes: minute))),
                  style: TextStyle(
                    fontFamily: 'WenKai',
                    fontSize: 13,
                    color: p.inkZhong,
                  ),
                ),
              ),
              Positioned(
                top: minute.toDouble() + 10,
                left: 58,
                right: 0,
                child: Divider(color: p.line, height: 1),
              ),
            ],
            for (final s in slices)
              Positioned(
                top: s.start.difference(start).inMinutes.toDouble() + 10,
                left: 64,
                right: 0,
                height: math.max(
                  s.end.difference(s.start).inMinutes.toDouble(),
                  24,
                ),
                child: Semantics(
                  button: true,
                  label: '${hm(s.start)}至${hm(s.end)} ${s.block['title']}',
                  child: InkWell(
                    onTap: () => onBlockTap(s.block),
                    child: ClipRect(
                      child: InkCard(
                        project: tasks
                            .where((t) => t['id'] == s.block['task_id'])
                            .firstOrNull?['project_id'],
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            s.block['title'],
                            style: TextStyle(
                              fontFamily: 'WenKai',
                              fontSize: 16,
                              color: p.inkJiao,
                            ),
                            maxLines: s.end.difference(s.start).inMinutes < 40
                                ? 1
                                : 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (dateKey(now) == dateKey(day) &&
                now.isAfter(start) &&
                now.isBefore(end))
              Positioned(
                top: now.difference(start).inSeconds / 60 + 10,
                left: 52,
                right: 0,
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.accent,
                      ),
                    ),
                    Expanded(child: Divider(height: 1, color: p.accent)),
                    Text('此刻', style: TextStyle(color: p.accent, fontSize: 12)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
