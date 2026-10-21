import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  late PlannerController c;
  late DateTime current;
  Future<void> prepare() async {
    tzdata.initializeTimeZones();
    current = DateTime.utc(2026, 10, 19, 16, 20);
    c = PlannerController(storage: MemoryStore(), clock: () => current);
    await c.initialize();
    await c.submit('task.create', {
      'id': 't',
      'title': '实验脚本',
      'outcome_criteria': '保存 CSV',
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
  }

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'late start asks for a mode and extension is usable on the focus card',
    (tester) async {
      await prepare();
      await show(tester);
      await tester.tap(find.byKey(const Key('action.start')));
      await tester.pumpAndSettle();
      expect(find.text('这一段现在开始，怎么安排？'), findsOneWidget);
      await tester.tap(find.byKey(const Key('start.mode.keep_end')));
      await tester.pumpAndSettle();
      expect(
        DateTime.parse(c.sessions.single['expected_end_at']),
        DateTime.utc(2026, 10, 19, 17),
      );
      await tester.tap(find.byKey(const Key('action.extend.15')));
      await tester.pumpAndSettle();
      expect(
        DateTime.parse(c.sessions.single['expected_end_at']),
        DateTime.utc(2026, 10, 19, 17, 15),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets('an ended block shows its actual time and keeps the plan as reference', (
    tester,
  ) async {
    await prepare();
    await c.startBlock(c.blocks.single);
    current = DateTime.utc(2026, 10, 19, 17, 5);
    await c.controlSession(c.sessions.single, 'end');
    await show(tester);
    expect(find.text('09:20 — 10:05'), findsOneWidget);
    expect(find.text('原定 09:00–10:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'interruption asks remaining work and saves it before trying a replan',
    (tester) async {
      await prepare();
      await c.startBlock(c.blocks.single);
      await show(tester);
      await tester.tap(find.byKey(const Key('action.end')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('feedback.interrupted')));
      await tester.tap(find.byKey(const Key('feedback.interrupted')));
      await tester.pumpAndSettle();
      expect(find.text('还需要多久？'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('action.save-feedback')));
      await tester.tap(find.byKey(const Key('action.save-feedback')));
      await tester.pumpAndSettle();
      expect(c.tasks.single['remaining_minutes'], 30);
      expect(c.feedbacks.single['choice'], 'interrupted');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'waiting can be deferred from tasks without marking the result complete',
    (tester) async {
      await prepare();
      await c.startBlock(c.blocks.single);
      await c.controlSession(c.sessions.single, 'end');
      await c.submit('feedback.create', {
        'session_id': c.sessions.single['id'],
        'choice': 'waiting',
        'check_at': current.add(const Duration(hours: 2)).toIso8601String(),
      });
      final id = (c.state['waiting_checks'] as List).single['id'];
      await show(tester);
      await tester.tap(find.text('诸事'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('waiting.snooze.$id')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('waiting.save-snooze')));
      await tester.tap(find.byKey(const Key('waiting.save-snooze')));
      await tester.pumpAndSettle();
      final check = (c.state['waiting_checks'] as List).single;
      expect(
        DateTime.parse(check['check_at']),
        current.add(const Duration(hours: 4)),
      );
      expect(check['resolved_at'], isNull);
      expect(c.tasks.single['state'], 'waiting');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
