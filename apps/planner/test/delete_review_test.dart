import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';
import 'package:time_planner/reminders.dart';

void main() {
  testWidgets(
    'deleting from tasks requires confirmation and removes planned reminders',
    (tester) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final current = DateTime.utc(2026, 10, 19, 16);
      final c = PlannerController(storage: MemoryStore(), clock: () => current);
      await c.initialize();
      await c.submit('task.create', {
        'id': 't',
        'title': '实验',
        'outcome_criteria': '保存报告',
        'remaining_minutes': 60,
      });
      await c.submit('block.create', {
        'id': 'b',
        'task_id': 't',
        'kind': 'flexible',
        'timezone': 'America/Los_Angeles',
        'start_at': current.add(const Duration(hours: 1)).toIso8601String(),
        'end_at': current.add(const Duration(hours: 2)).toIso8601String(),
      });
      await tester.pumpWidget(PlannerApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('诸事'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('task.delete.t')));
      await tester.pumpAndSettle();
      expect(c.tasks.single['state'], 'ready');
      await tester.tap(find.byKey(const Key('task.confirm-delete')));
      await tester.pumpAndSettle();
      expect(c.tasks.single['state'], 'cancelled');
      expect(c.blocks.single['status'], 'cancelled');
      expect(
        buildReminders(
          c.state,
          current,
        ).where((r) => r.payload['block_id'] == 'b'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  test(
    'explicit memory survives local restart and can be deleted offline',
    () async {
      final storage = MemoryStore();
      final c = PlannerController(storage: storage);
      await c.initialize();
      await c.submit('memory.save', {'id': 'memory-1', 'text': '上午优先做实验'});
      c.dispose();
      final restarted = PlannerController(storage: storage);
      await restarted.initialize();
      expect((restarted.state['memories'] as List).single['text'], '上午优先做实验');
      await restarted.submit('memory.delete', {'id': 'memory-1'});
      expect(restarted.state['memories'], isEmpty);
      restarted.dispose();
    },
  );
}
