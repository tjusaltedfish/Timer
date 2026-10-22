import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../calendar.dart';
import '../controller.dart';
import '../formatting.dart';
import '../theme/schedule_ink.dart';
import '../theme/tokens.dart';

/// 单天概览：先给数字（计划多久、实际投入多久、完成/中断几段），再给当天的紧凑列表。
class DayOverview extends StatelessWidget {
  const DayOverview({
    super.key,
    required this.day,
    required this.now,
    required this.blocks,
    required this.tasks,
    this.sessions = const [],
    required this.zone,
    required this.onBlockTap,
    this.onPlan,
  });

  final DateTime day;
  final DateTime now;
  final List<Json> blocks;
  final List<Json> tasks;
  final List<Json> sessions;
  final tz.Location zone;
  final ValueChanged<Json> onBlockTap;
  final VoidCallback? onPlan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slices = daySlices(blocks, day, zone, sessions: sessions);
    final midnight = tz.TZDateTime(zone, day.year, day.month, day.day);
    final nextMidnight = tz.TZDateTime(zone, day.year, day.month, day.day + 1);
    var planned = 0;
    var spent = 0;
    var closed = 0;
    var interrupted = 0;
    for (final slice in slices) {
      planned += _plannedMinutes(slice, midnight, nextMidnight);
      spent += _spentMinutes(slice.session, now);
      final state = slice.session?['state'] as String?;
      if (state == 'awaiting_feedback' || state == 'closed') closed++;
      if (state == 'awaiting_feedback' && slice.session?['ended_by'] == 'user') {
        interrupted++;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _Stat(label: '计划', value: _duration(planned)),
            _Stat(label: '已投入', value: _duration(spent)),
            _Stat(label: '完成', value: '$closed 段'),
            _Stat(label: '中断', value: '$interrupted 段'),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: slices.isEmpty
              ? _empty(theme)
              : ListView(
                  children: [
                    for (final slice in slices)
                      _Row(
                        slice: slice,
                        pigment: _pigment(context, slice.block),
                        onTap: () => onBlockTap(slice.block),
                      ),
                    const SizedBox(height: 60),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _empty(ThemeData theme) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('这一天还空着。', style: theme.textTheme.titleMedium),
            if (onPlan != null) ...[
              const SizedBox(height: 8),
              TextButton(
                key: const Key('week.day.plan'),
                onPressed: onPlan,
                child: const Text('排一件事'),
              ),
            ],
          ],
        ),
      );

  Color _pigment(BuildContext context, Json block) {
    if (block['kind'] == 'protected') return context.inkPalette.inkZhong;
    return ScheduleInk.forTask(
      block['task_id'] ?? block['id'],
      tasks,
      Theme.of(context).brightness,
    );
  }

  /// 计划时长按原定时间算；被午夜截断的当天只算进当天的部分。
  int _plannedMinutes(DaySlice slice, tz.TZDateTime dayStart, tz.TZDateTime dayEnd) {
    final plannedStart = slice.plannedStart ?? slice.start;
    final plannedEnd = slice.plannedEnd ?? slice.end;
    final start = plannedStart.isAfter(dayStart) ? plannedStart : dayStart;
    final end = plannedEnd.isBefore(dayEnd) ? plannedEnd : dayEnd;
    return math.max(0, end.difference(start).inMinutes);
  }

  /// 已投入时长按 intervals 累加（正在进行的段以“现在”为终点），
  /// 没有 intervals 的旧数据退回到 actual_start_at / actual_end_at。
  int _spentMinutes(Map<String, dynamic>? session, DateTime now) {
    if (session == null) return 0;
    final intervals = session['intervals'];
    if (intervals is List && intervals.isNotEmpty) {
      var seconds = 0;
      for (final entry in intervals) {
        if (entry is! Map) continue;
        final start = DateTime.tryParse(entry['start_at'] as String? ?? '');
        if (start == null) continue;
        final end = DateTime.tryParse(entry['end_at'] as String? ?? '') ?? now;
        if (end.isAfter(start)) seconds += end.difference(start).inSeconds;
      }
      return seconds ~/ 60;
    }
    final start = DateTime.tryParse(session['actual_start_at'] as String? ?? '');
    if (start == null) return 0;
    final end = DateTime.tryParse(session['actual_end_at'] as String? ?? '') ?? now;
    return end.isAfter(start) ? end.difference(start).inMinutes : 0;
  }
}

String _duration(int minutes) {
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
}

String _stateLabel(DaySlice slice) {
  final session = slice.session;
  if (session == null) return '还没开始';
  switch (session['state']) {
    case 'running':
      return '进行中';
    case 'paused':
      return '已暂停';
    case 'awaiting_feedback':
      return session['ended_by'] == 'user' ? '已记录' : '待回话';
    case 'closed':
      return '已完成';
  }
  return '已记录';
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.inkPalette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.wash,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: palette.inkZhong),
          ),
          const SizedBox(width: 5),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontFamily: 'WenKai',
              color: palette.inkJiao,
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.slice,
    required this.pigment,
    required this.onTap,
  });

  final DaySlice slice;
  final Color pigment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.inkPalette;
    final title = slice.block['title'] as String? ?? '未命名';
    final subtitle = StringBuffer(_stateLabel(slice));
    if (slice.differsFromPlan) {
      subtitle
        ..write(' · 原定 ')
        ..write(hm(slice.plannedStart!))
        ..write('—')
        ..write(hm(slice.plannedEnd!));
    }
    return InkWell(
      key: ValueKey('week.day.item.${slice.block['id']}'),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 32,
              decoration: BoxDecoration(
                color: pigment,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 9),
            SizedBox(
              width: 76,
              child: Text(
                '${hm(slice.start)}—${hm(slice.end)}',
                style: TextStyle(fontSize: 11.5, color: palette.inkZhong),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontFamily: 'WenKai',
                      color: palette.inkJiao,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle.toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: palette.inkZhong),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: palette.inkDan),
          ],
        ),
      ),
    );
  }
}
