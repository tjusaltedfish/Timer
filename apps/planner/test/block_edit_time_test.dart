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
    final c = PlannerController(
      storage: MemoryStore(),
      clock: () => current,
    );
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
    expect(find.text('把这一段挪到？'), findsOneWidget);
    expect(find.byKey(const Key('reschedule.preview')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reschedule.tonight')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reschedule.confirm')));
    await tester.pumpAndSettle();

    final zone = tz.getLocation(c.settings['timezone'] as String);
    final expected = tz.TZDateTime(zone, 2026, 10, 19, 20).toUtc();
    final moved = c.blocks.single;
    expect(
      DateTime.parse(moved['start_at'] as String).toUtc().millisecondsSinceEpoch,
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
}
