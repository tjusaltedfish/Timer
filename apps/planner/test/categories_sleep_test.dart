import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';
import 'package:time_planner/theme/ink_theme.dart';
import 'package:time_planner/widgets/ink_wheel_picker.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('a fresh planner has no built-in categories', () async {
    final c = PlannerController(storage: MemoryStore());
    await c.initialize();
    expect(c.projects, isEmpty);
    await c.submit('task.create', {
      'id': 't1',
      'title': '随手一件事',
      'outcome_criteria': '做完',
      'remaining_minutes': 30,
    });
    expect(c.tasks.single['project_id'], isNull);
    await c.submit('project.create', {'id': 'p1', 'name': '读论文'});
    expect(
      () => c.submit('project.create', {'id': 'p2', 'name': '读论文'}),
      throwsA(isA<ApiFailure>()),
    );
    await c.submit('project.update', {'id': 'p1', 'archived': true});
    expect(c.activeProjects, isEmpty);
    c.dispose();
  });

  test('sleep can be started, finished and corrected locally', () async {
    final c = PlannerController(storage: MemoryStore());
    await c.initialize();
    final start = DateTime.now().toUtc().subtract(const Duration(hours: 8));
    await c.submit('sleep.log', {
      'id': 's1',
      'slept_at': start.toIso8601String(),
    });
    expect(c.openSleep?['id'], 's1');
    expect(
      () => c.submit('sleep.log', {
        'id': 's2',
        'slept_at': DateTime.now().toUtc().toIso8601String(),
      }),
      throwsA(isA<ApiFailure>()),
    );
    await c.submit('sleep.log', {
      'id': 's1',
      'slept_at': start.toIso8601String(),
      'woke_at': DateTime.now().toUtc().toIso8601String(),
      'quality': 4,
    });
    expect(c.openSleep, isNull);
    expect(c.sleeps.single['quality'], 4);
    await c.submit('sleep.delete', {'id': 's1'});
    expect(c.sleeps, isEmpty);
    c.dispose();
  });

  testWidgets('a sleep wheel never settles in the future', (tester) async {
    final values = <DateTime>[];
    final now = DateTime(2026, 10, 19, 7, 42);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildInkTheme(Brightness.light),
        home: Scaffold(
          body: InkDateTimeWheel(
            initial: DateTime(2026, 10, 19, 6, 0),
            today: now,
            firstDay: DateTime(2026, 10, 6),
            days: 14,
            maximum: now,
            onChanged: (d, h, m) =>
                values.add(DateTime(d.year, d.month, d.day, h, m)),
          ),
        ),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('wheel.hour')),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
    expect(values.last.isAfter(DateTime(2026, 10, 19, 7, 40)), isFalse);
    expect(find.textContaining('还没到来的时刻不能记录'), findsOneWidget);
  });

  testWidgets('the task form offers no category by default and can add one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = PlannerController(storage: MemoryStore());
    await c.initialize();
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.tap(find.byKey(const Key('action.first-task')));
    await tester.pumpAndSettle();
    expect(find.text('不归类'), findsOneWidget);
    await tester.ensureVisible(find.text('新分类'));
    await tester.tap(find.text('新分类'));
    await tester.pumpAndSettle();
    expect(find.text('新的分类'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '健身');
    await tester.pump();
    expect(find.text('健身'), findsWidgets);
    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();
    expect(find.text('新的分类'), findsNothing);
    expect(c.projects.single['name'], '健身');
    await tester.enterText(find.byType(TextField).at(0), '跑步');
    await tester.enterText(find.byType(TextField).at(1), '5 公里');
    // Invoke the save action directly; hit-testing inside nested sheets is
    // covered by the 360px keyboard test.
    tester
        .widget<FilledButton>(find.byKey(const Key('action.save-task')))
        .onPressed!();
    await tester.pumpAndSettle();
    expect(c.tasks.single['project_id'], c.projects.single['id']);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
