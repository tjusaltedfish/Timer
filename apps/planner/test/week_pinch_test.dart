import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  tzdata.initializeTimeZones();

  testWidgets('两指捏合缩放详细课表，有上下限', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = PlannerController(
      storage: MemoryStore(),
      clock: () => DateTime.utc(2026, 10, 19, 16),
    );
    await c.initialize();
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一周').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('week.detail.open')));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    final center = tester.getCenter(find.byKey(const Key('week.detail.pinch')));
    Future<void> pinch(double from, double to) async {
      final a = await tester.startGesture(center - Offset(from / 2, 0));
      final b = await tester.startGesture(center + Offset(from / 2, 0));
      await tester.pump();
      for (var i = 1; i <= 5; i++) {
        final spread = from + (to - from) * i / 5;
        await a.moveTo(center - Offset(spread / 2, 0));
        await b.moveTo(center + Offset(spread / 2, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
    }

    // Fingers 100px apart spread to 150px: 1.5×.
    await pinch(100, 150);
    expect(find.text('150%'), findsOneWidget);
    // Pinching far in stops at the lower bound.
    await pinch(200, 40);
    expect(find.text('75%'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
