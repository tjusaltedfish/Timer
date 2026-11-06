import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';
import 'package:time_planner/week_calendar.dart';

void main() {
  tzdata.initializeTimeZones();
  final zone = tz.getLocation('Asia/Shanghai');

  Json block(
    String id,
    String? task,
    String start,
    String end, {
    String status = 'scheduled',
    String kind = 'flexible',
  }) => {
    'id': id,
    'task_id': task,
    'title': id,
    'kind': kind,
    'status': status,
    'start_at': start,
    'end_at': end,
  };

  test('planned, actual, outcomes and last week add up per category', () {
    final stats = WeekStats.of(
      projects: [
        {'id': 'p1', 'name': '实验'},
      ],
      tasks: [
        {'id': 't1', 'project_id': 'p1'},
        {'id': 't2'},
      ],
      blocks: [
        block('b1', 't1', '2026-11-02T01:00:00Z', '2026-11-02T03:00:00Z',
            status: 'completed'),
        block('b2', 't2', '2026-11-03T06:00:00Z', '2026-11-03T07:00:00Z',
            status: 'skipped'),
        block('b3', 't1', '2026-11-04T01:00:00Z', '2026-11-04T02:00:00Z'),
        block('b4', null, '2026-11-05T04:00:00Z', '2026-11-05T05:00:00Z',
            kind: 'protected'),
        block('b5', 't1', '2026-11-06T02:00:00Z', '2026-11-06T03:00:00Z'),
        block('b6', 't1', '2026-11-06T05:00:00Z', '2026-11-06T06:00:00Z',
            status: 'cancelled'),
        block('b0', 't1', '2026-10-26T02:00:00Z', '2026-10-26T03:00:00Z'),
      ],
      sessions: [
        {
          'id': 's1',
          'task_id': 't1',
          'block_id': 'b1',
          'intervals': [
            // 50 + 40 minutes; the 10-minute pause does not count.
            {'start_at': '2026-11-02T01:00:00Z', 'end_at': '2026-11-02T01:50:00Z'},
            {'start_at': '2026-11-02T02:00:00Z', 'end_at': '2026-11-02T02:40:00Z'},
          ],
        },
        {
          'id': 's2',
          'task_id': 't2',
          'block_id': 'b0',
          'intervals': [
            {'start_at': '2026-10-28T01:00:00Z', 'end_at': '2026-10-28T02:00:00Z'},
          ],
        },
        {
          'id': 's3',
          'task_id': 't1',
          'block_id': 'b5',
          'intervals': [
            {'start_at': '2026-11-05T03:30:00Z', 'end_at': null},
          ],
        },
      ],
      monday: DateTime(2026, 11, 2),
      zone: zone,
      now: DateTime.utc(2026, 11, 5, 4),
    );
    expect(stats.categories.map((c) => c.name), ['实验', '未分类']);
    final lab = stats.categories.first;
    expect((lab.planned, lab.actual), (240, 120));
    expect((stats.categories.last.planned, stats.categories.last.actual),
        (60, 0));
    expect((stats.done, stats.skipped, stats.missed), (1, 1, 1));
    expect(stats.lastWeekActual, 60);
  });

  test('durations read naturally', () {
    expect(durationText(45), '45 分钟');
    expect(durationText(120), '2 小时');
    expect(durationText(150), '2.5 小时');
    expect(durationText(100), '1.5 小时');
  });

  Future<PlannerController> seed() async {
    final c = PlannerController(
      storage: MemoryStore(),
      clock: () => DateTime.utc(2026, 10, 19, 16),
    );
    await c.initialize();
    await c.submit('task.create', {
      'id': 't1',
      'title': '实验代码',
      'outcome_criteria': '输出 CSV',
      'remaining_minutes': 60,
    });
    await c.submit('block.create', {
      'id': 'b1',
      'task_id': 't1',
      'kind': 'flexible',
      'timezone': 'America/Los_Angeles',
      'start_at': '2026-10-19T17:00:00Z',
      'end_at': '2026-10-19T18:30:00Z',
    });
    return c;
  }

  testWidgets('desktop week shows the card; phone shows a line that opens it', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(1280, 900), const Size(390, 844)]) {
      tester.view.physicalSize = size;
      final c = await seed();
      await tester.pumpWidget(PlannerApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('一周').last);
      await tester.pumpAndSettle();
      if (size.width > 600) {
        expect(find.byKey(const Key('week.stats')), findsOneWidget);
        expect(find.textContaining('计划 1.5 小时'), findsWidgets);
      } else {
        expect(find.byKey(const Key('week.stats')), findsNothing);
        await tester.tap(find.byKey(const Key('week.stats.summary')));
        await tester.pumpAndSettle();
        expect(find.text('本周时间去向'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
  });
}
