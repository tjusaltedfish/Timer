import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  testWidgets('crossing midnight moves 今天 forward unless you are reading another day',
      (tester) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var now = DateTime.utc(2026, 10, 19, 16); // 09:00 in Los Angeles
    final c = PlannerController(storage: MemoryStore(), clock: () => now);
    await c.initialize();
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.textContaining('10月19日'), findsWidgets);
    expect(find.textContaining('正在查看'), findsNothing);

    // 10/20 00:00 Los Angeles = 07:00Z
    now = DateTime.utc(2026, 10, 20, 7);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('10月20日'), findsWidgets);
    expect(find.textContaining('正在查看'), findsNothing,
        reason: '午夜后默认跟着今天走，不应停在「正在查看昨天」');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    c.dispose();
  });
}
