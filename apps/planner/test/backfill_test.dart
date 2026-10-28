import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  testWidgets('a block that ended without being started can be backfilled', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    final current = DateTime.utc(2026, 10, 19, 18, 30); // 11:30 Los Angeles
    final c = PlannerController(storage: MemoryStore(), clock: () => current);
    await c.initialize();
    await c.submit('task.create', {
      'id': 't',
      'title': '读论文',
      'outcome_criteria': '读完一篇',
      'remaining_minutes': 60,
    });
    // Planned for 10:00–11:00 local, never started; it is now 11:30.
    c.state['blocks'] = [
      {
        'id': 'b',
        'task_id': 't',
        'title': '读论文',
        'kind': 'flexible',
        'status': 'scheduled',
        'version': 1,
        'start_at': DateTime.utc(2026, 10, 19, 17).toIso8601String(),
        'end_at': DateTime.utc(2026, 10, 19, 18).toIso8601String(),
      },
    ];
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();

    await tester.tap(find.text('补记这一段的结果'));
    await tester.pumpAndSettle();
    // The dialog opens even though there is no timed execution.
    expect(find.text('补记这一段的结果'), findsWidgets);
    await tester.ensureVisible(find.byKey(const Key('action.save-feedback')));
    await tester.tap(find.byKey(const Key('action.save-feedback')));
    await tester.pumpAndSettle();

    final feedback = (c.state['feedbacks'] as List).single as Json;
    expect(feedback['block_id'], 'b');
    expect(feedback.containsKey('session_id'), isFalse);
    expect(c.blocks.single['status'], 'completed');
    expect(c.tasks.single['state'], 'done');
    expect(c.sessions, isEmpty, reason: '补记不伪造计时');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
