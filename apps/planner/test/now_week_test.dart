import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  testWidgets(
    'today stays distinct from selected day; starting enters focus, whole week fits phone',
    (tester) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = PlannerController(
        storage: MemoryStore(),
        clock: () => DateTime.utc(2026, 10, 19, 16),
      );
      await c.initialize();
      await c.submit('task.create', {
        'id': 't',
        'title': '实验代码',
        'outcome_criteria': '输出 CSV',
        'remaining_minutes': 60,
      });
      await c.submit('block.create', {
        'id': 'b',
        'task_id': 't',
        'kind': 'flexible',
        'timezone': 'America/Los_Angeles',
        'start_at': '2026-10-19T16:00:00Z',
        'end_at': '2026-10-19T17:00:00Z',
      });
      await tester.pumpWidget(PlannerApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home.clock')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('day.2026-10-20')));
      await tester.pumpAndSettle();
      expect(find.textContaining('正在查看 10月20日'), findsOneWidget);
      expect(find.text('今天'), findsOneWidget);
      await tester.tap(find.text('回到今天'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('action.start')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('focus.panel')), findsOneWidget);
      expect(find.text('正在专注'), findsOneWidget);
      expect(find.byKey(const Key('focus.remaining')), findsOneWidget);
      await tester.tap(find.text('一周'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('week.overview')), findsOneWidget);
      for (var i = 0; i < 7; i++) {
        final rect = tester.getRect(find.byKey(ValueKey('week.day.$i')));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(390));
        expect(rect.bottom, lessThan(760));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
