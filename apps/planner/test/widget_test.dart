import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  testWidgets('user creates an outcome-based task and schedule in local mode', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    final controller = PlannerController(storage: MemoryStore());
    await controller.initialize();
    await tester.pumpWidget(PlannerApp(controller: controller));
    expect(find.text('这一天，还留着空间。'), findsOneWidget);
    await tester.tap(find.text('安排第一件事'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '参数扫描');
    await tester.enterText(find.byType(TextField).at(1), '保存一组可复现输出');
    await tester.ensureVisible(find.text('保存安排'));
    await tester.tap(find.text('保存安排'));
    await tester.pumpAndSettle();
    expect(controller.tasks.single['outcome_criteria'], '保存一组可复现输出');
    expect(controller.blocks.single['task_id'], controller.tasks.single['id']);
    expect(controller.pending.length, 2);
    expect(find.text('参数扫描'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
