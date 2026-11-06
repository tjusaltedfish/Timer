import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  testWidgets('滚轮选的时间就是保存的时间，预览也跟着变', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tzdata.initializeTimeZones();
    final current = DateTime.utc(2026, 10, 19, 16, 20); // 09:20 Los Angeles
    final original = DateTime.utc(2026, 10, 19, 17);
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
      'start_at': original.toIso8601String(),
      'end_at': original.add(const Duration(hours: 1)).toIso8601String(),
    });
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('待办操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('改时间'));
    await tester.pumpAndSettle();

    String preview() =>
        tester.widget<Text>(find.byKey(const Key('reschedule.preview'))).data!;
    final before = preview();
    expect(before, contains('10:00'));

    final hour = find.byKey(const ValueKey('wheel.hour'));
    await tester.ensureVisible(hour);
    await tester.pumpAndSettle();
    await tester.drag(hour, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(preview(), isNot(before), reason: '滚完滚轮预览要跟着变');

    await tester.ensureVisible(find.byKey(const Key('reschedule.confirm')));
    await tester.tap(find.byKey(const Key('reschedule.confirm')));
    await tester.pumpAndSettle();

    final moved = c.blocks.single;
    final start = DateTime.parse(moved['start_at'] as String);
    final end = DateTime.parse(moved['end_at'] as String);
    expect(start.isAfter(original), isTrue, reason: '保存的必须是滚轮选的时间');
    expect(end.difference(start), const Duration(hours: 1));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
