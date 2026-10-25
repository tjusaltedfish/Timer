import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  testWidgets('an upcoming block can be moved to another time in place', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    final current = DateTime.utc(2026, 10, 19, 16, 20);
    final c = PlannerController(storage: MemoryStore(), clock: () => current);
    await c.initialize();
    await c.submit('task.create', {
      'id': 't',
      'title': '实验',
      'outcome_criteria': '报告',
      'remaining_minutes': 60,
    });
    await c.submit('block.create', {
      'id': 'b',
      'task_id': 't',
      'start_at': DateTime.utc(2026, 10, 19, 16, 30).toIso8601String(),
      'end_at': DateTime.utc(2026, 10, 19, 17, 30).toIso8601String(),
    });
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();

    // The block's own menu carries the time change, next to edit/delete.
    await tester.tap(find.byTooltip('待办操作'));
    await tester.pumpAndSettle();
    expect(find.text('改时间'), findsOneWidget);
    await tester.tap(find.text('改时间'));
    await tester.pumpAndSettle();

    // The dialog keeps the old interval visible and offers a target.
    expect(find.text('改这一段的时间'), findsOneWidget);
    expect(find.byKey(const Key('reschedule.preview')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reschedule.tonight')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reschedule.confirm')));
    await tester.pumpAndSettle();

    final zone = tz.getLocation(c.settings['timezone'] as String);
    final expected = tz.TZDateTime(zone, 2026, 10, 19, 20).toUtc();
    final moved = c.blocks.single;
    expect(
      DateTime.parse(moved['start_at'] as String)
          .toUtc()
          .millisecondsSinceEpoch,
      expected.millisecondsSinceEpoch,
    );
    expect(
      DateTime.parse(moved['end_at'] as String).toUtc().millisecondsSinceEpoch,
      expected.add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
    // Moving a planned block must not create an execution record.
    expect(c.sessions, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'time and length can be changed from the block details, meals too',
    (tester) async {
      tzdata.initializeTimeZones();
      final current = DateTime.utc(2026, 10, 19, 16, 20); // 09:20 Los Angeles
      final c = PlannerController(storage: MemoryStore(), clock: () => current);
      await c.initialize();
      await c.submit('task.create', {
        'id': 't',
        'title': '实验',
        'outcome_criteria': '报告',
        'remaining_minutes': 60,
      });
      await c.submit('block.create', {
        'id': 'work',
        'task_id': 't',
        'start_at': DateTime.utc(2026, 10, 19, 17).toIso8601String(),
        'end_at': DateTime.utc(2026, 10, 19, 18).toIso8601String(),
      });
      await c.submit('block.create', {
        'id': 'meal',
        'title': '午饭',
        'kind': 'protected',
        'start_at': DateTime.utc(2026, 10, 19, 19).toIso8601String(),
        'end_at': DateTime.utc(2026, 10, 19, 20).toIso8601String(),
      });
      await tester.pumpWidget(PlannerApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('列表'));
      await tester.pumpAndSettle();

      Future<void> openTime(String title, String id) async {
        await tester.tap(find.text(title).first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('block.time.$id')));
        await tester.pumpAndSettle();
        expect(find.text('改这一段的时间'), findsOneWidget);
      }

      // A work block: keep the start, make it 30 minutes longer.
      await openTime('实验', 'work');
      await tester.ensureVisible(find.byKey(const Key('reschedule.longer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reschedule.longer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reschedule.longer')));
      await tester.pumpAndSettle();
      expect(find.text('90 分钟'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('reschedule.confirm')));
      await tester.tap(find.byKey(const Key('reschedule.confirm')));
      await tester.pumpAndSettle();
      final work = c.blocks.firstWhere((b) => b['id'] == 'work');
      expect(
        DateTime.parse(work['start_at']).toUtc(),
        DateTime.utc(2026, 10, 19, 17),
      );
      expect(
        DateTime.parse(work['end_at']).toUtc(),
        DateTime.utc(2026, 10, 19, 18, 30),
      );

      // A meal slot has no task, yet it can move as well.
      await openTime('午饭', 'meal');
      await tester.tap(find.byKey(const Key('reschedule.tonight')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('reschedule.shorter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reschedule.shorter')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('reschedule.confirm')));
      await tester.tap(find.byKey(const Key('reschedule.confirm')));
      await tester.pumpAndSettle();
      final zone = tz.getLocation(c.settings['timezone'] as String);
      final meal = c.blocks.firstWhere((b) => b['id'] == 'meal');
      final evening = tz.TZDateTime(
        zone,
        2026,
        10,
        19,
        20,
      ).millisecondsSinceEpoch;
      expect(DateTime.parse(meal['start_at']).millisecondsSinceEpoch, evening);
      expect(
        DateTime.parse(meal['end_at']).millisecondsSinceEpoch,
        evening + const Duration(minutes: 45).inMilliseconds,
      );
      expect(c.sessions, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets('编辑待办 itself changes the time and the length', (tester) async {
    tzdata.initializeTimeZones();
    final current = DateTime.utc(2026, 10, 19, 16, 20); // 09:20 Los Angeles
    final c = PlannerController(storage: MemoryStore(), clock: () => current);
    await c.initialize();
    await c.submit('task.create', {
      'id': 't',
      'title': '实验',
      'outcome_criteria': '报告',
      'remaining_minutes': 60,
    });
    await c.submit('block.create', {
      'id': 'b',
      'task_id': 't',
      'start_at': DateTime.utc(2026, 10, 19, 17).toIso8601String(),
      'end_at': DateTime.utc(2026, 10, 19, 18).toIso8601String(),
    });
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();

    Future<void> lengthen(Finder open) async {
      await tester.tap(open);
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑待办').last);
      await tester.pumpAndSettle();
      expect(find.text('时间安排'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('task.edit.time.b')),
      );
      await tester.tap(find.byKey(const ValueKey('task.edit.time.b')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('reschedule.longer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reschedule.longer')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('reschedule.confirm')));
      await tester.tap(find.byKey(const Key('reschedule.confirm')));
      await tester.pumpAndSettle();
      // Back in 编辑待办, the row already shows the new length.
      expect(find.textContaining('分钟）'), findsOneWidget);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
    }

    int minutes() {
      final b = c.blocks.single;
      return DateTime.parse(b['end_at'])
          .difference(DateTime.parse(b['start_at']))
          .inMinutes;
    }

    // From the card's own menu.
    await lengthen(find.byTooltip('待办操作'));
    expect(minutes(), 75);
    expect(find.textContaining('75 分钟'), findsWidgets);

    // From the day list, through the block's details.
    await tester.tap(find.text('列表'));
    await tester.pumpAndSettle();
    await lengthen(find.text('实验').first);
    expect(minutes(), 90);
    expect(
      DateTime.parse(c.blocks.single['start_at']).toUtc(),
      DateTime.utc(2026, 10, 19, 17),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
