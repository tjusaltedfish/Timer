import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../controller.dart';
import '../theme/tokens.dart';

/// 一周里某个分类的计划与实际投入（分钟）。
class CategoryTime {
  CategoryTime(this.projectId, this.name);
  final String? projectId;
  final String name;
  int planned = 0, actual = 0;
}

/// 「本周时间去向」：由本地状态推出来，不新增任何接口。
///
/// - 计划：本周开始的非保护、未撤下的时间段的时长。
/// - 实际：执行记录里真正在计时的区间（暂停不算），截在本周之内；
///   正在进行的一段算到 [now]。
/// - 完成 / 跳过：本周段的反馈结果；错过：已经过点、没开始也没反馈的段。
class WeekStats {
  WeekStats._(this.categories, this.done, this.skipped, this.missed,
      this.lastWeekActual);

  factory WeekStats.of({
    required List<Json> blocks,
    required List<Json> sessions,
    required List<Json> tasks,
    required List<Json> projects,
    required DateTime monday,
    required tz.Location zone,
    required DateTime now,
  }) {
    final start = tz.TZDateTime(zone, monday.year, monday.month, monday.day);
    final end = tz.TZDateTime(zone, monday.year, monday.month, monday.day + 7);
    final previous =
        tz.TZDateTime(zone, monday.year, monday.month, monday.day - 7);
    final taskById = {for (final t in tasks) t['id']: t};
    final projectName = {for (final p in projects) p['id']: p['name']};
    final categories = <String?, CategoryTime>{};
    CategoryTime bucket(String? taskId) {
      final projectId = taskById[taskId]?['project_id'] as String?;
      final known = projectName.containsKey(projectId) ? projectId : null;
      return categories.putIfAbsent(
        known,
        () => CategoryTime(known, projectName[known] as String? ?? '未分类'),
      );
    }

    final recorded = {for (final s in sessions) s['block_id']};
    var done = 0, skipped = 0, missed = 0;
    for (final block in blocks) {
      if (block['kind'] == 'protected' || block['status'] == 'cancelled') {
        continue;
      }
      final from = DateTime.tryParse(block['start_at'] as String? ?? '');
      final to = DateTime.tryParse(block['end_at'] as String? ?? '');
      if (from == null || to == null) continue;
      if (from.isBefore(start) || !from.isBefore(end)) continue;
      bucket(block['task_id'] as String?).planned +=
          to.difference(from).inMinutes;
      switch (block['status']) {
        case 'completed':
          done++;
        case 'skipped':
          skipped++;
        case 'scheduled' when to.isBefore(now) &&
            !recorded.contains(block['id']):
          missed++;
      }
    }

    var lastWeek = 0;
    for (final session in sessions) {
      for (final (a, b) in _focus(session, now)) {
        bucket(session['task_id'] as String?).actual += _overlap(
          a,
          b,
          start,
          end,
        );
        lastWeek += _overlap(a, b, previous, start);
      }
    }
    final list = categories.values
        .where((c) => c.planned > 0 || c.actual > 0)
        .toList()
      ..sort(
        (a, b) => math
            .max(b.planned, b.actual)
            .compareTo(math.max(a.planned, a.actual)),
      );
    return WeekStats._(list, done, skipped, missed, lastWeek);
  }

  final List<CategoryTime> categories;
  final int done, skipped, missed, lastWeekActual;

  int get planned => categories.fold(0, (sum, c) => sum + c.planned);
  int get actual => categories.fold(0, (sum, c) => sum + c.actual);
  bool get isEmpty => planned == 0 && actual == 0 && lastWeekActual == 0;

  /// Timed intervals of a session; older records without intervals fall back
  /// to their start and end.
  static Iterable<(DateTime, DateTime)> _focus(Json session, DateTime now) sync* {
    final intervals = session['intervals'] as List?;
    if (intervals != null && intervals.isNotEmpty) {
      for (final raw in intervals) {
        final a = DateTime.tryParse(raw['start_at'] as String? ?? '');
        final b = DateTime.tryParse(raw['end_at'] as String? ?? '') ?? now;
        if (a != null && b.isAfter(a)) yield (a, b);
      }
      return;
    }
    final a = DateTime.tryParse(session['actual_start_at'] as String? ?? '');
    final b =
        DateTime.tryParse(session['actual_end_at'] as String? ?? '') ?? now;
    if (a != null && b.isAfter(a)) yield (a, b);
  }

  static int _overlap(DateTime a, DateTime b, DateTime from, DateTime to) {
    final lo = a.isAfter(from) ? a : from;
    final hi = b.isBefore(to) ? b : to;
    return hi.isAfter(lo) ? hi.difference(lo).inMinutes : 0;
  }
}

/// 「3 小时」「2.5 小时」「45 分钟」。
String durationText(int minutes) {
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes / 60;
  final rounded = (hours * 2).round() / 2;
  return rounded == rounded.roundToDouble()
      ? '${rounded.round()} 小时'
      : '${rounded.toStringAsFixed(1)} 小时';
}

/// 本周时间去向。[compact] 时只有一行摘要，点开看分类明细（手机总览用）。
class WeekStatsCard extends StatelessWidget {
  const WeekStatsCard({
    super.key,
    required this.stats,
    required this.markOf,
    this.compact = false,
  });

  final WeekStats stats;
  final Color? Function(String? projectId) markOf;
  final bool compact;

  String get _summary {
    final parts = [
      '实际 ${durationText(stats.actual)} / 计划 ${durationText(stats.planned)}',
      if (stats.done > 0) '完成 ${stats.done} 段',
      if (stats.skipped > 0) '跳过 ${stats.skipped} 段',
      if (stats.missed > 0) '错过 ${stats.missed} 段',
    ];
    return parts.join(' · ');
  }

  String? get _trend {
    if (stats.lastWeekActual == 0) return null;
    final diff = stats.actual - stats.lastWeekActual;
    if (diff.abs() < 30) return '和上周差不多';
    return diff > 0
        ? '比上周多 ${durationText(diff)}'
        : '比上周少 ${durationText(-diff)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.inkPalette;
    if (compact) {
      return InkWell(
        key: const Key('week.stats.summary'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: WeekStatsCard(stats: stats, markOf: markOf),
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Row(
            children: [
              Text('本周', style: theme.textTheme.labelMedium),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: p.inkZhong),
            ],
          ),
        ),
      );
    }
    final trend = _trend;
    final scale = math.max(
      1,
      stats.categories.fold(
        0,
        (most, c) => math.max(most, math.max(c.planned, c.actual)),
      ),
    );
    return Column(
      key: const Key('week.stats'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '本周时间去向',
              style: TextStyle(
                fontFamily: 'WenKai',
                fontSize: 18,
                color: p.inkJiao,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                [_summary, ?trend].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (stats.categories.isEmpty)
          Text('这周还没有安排，也没有计时记录。', style: theme.textTheme.bodySmall)
        else
          LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 640;
              final width = wide ? (box.maxWidth - 24) / 2 : box.maxWidth;
              return Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  for (final c in stats.categories.take(wide ? 8 : 6))
                    SizedBox(
                      width: width,
                      child: _CategoryRow(
                        category: c,
                        scale: scale,
                        mark: markOf(c.projectId) ?? p.inkQing,
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.scale,
    required this.mark,
  });
  final CategoryTime category;
  final int scale;
  final Color mark;

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final theme = Theme.of(context);
    return Semantics(
      label:
          '${category.name}：实际 ${durationText(category.actual)}，'
          '计划 ${durationText(category.planned)}',
      excludeSemantics: true,
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: mark,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 76,
            child: Text(
              category.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                double w(int minutes) => box.maxWidth * minutes / scale;
                return SizedBox(
                  height: 10,
                  child: Stack(
                    children: [
                      // 计划：淡墨底；实际：焦墨实条。
                      Container(
                        width: w(category.planned),
                        decoration: BoxDecoration(
                          color: p.washStrong,
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                      Container(
                        width: w(category.actual),
                        margin: const EdgeInsets.symmetric(vertical: 2.5),
                        decoration: BoxDecoration(
                          color: p.inkNong,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${durationText(category.actual)} / ${durationText(category.planned)}',
            style: TextStyle(fontSize: 12, color: p.inkZhong),
          ),
        ],
      ),
    );
  }
}
