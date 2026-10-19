import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';
import 'package:time_planner/theme/ink_theme.dart';
import 'package:time_planner/week_calendar.dart';
import 'package:time_planner/widgets/card_wheel.dart';
import 'package:time_planner/widgets/ink_wheel_picker.dart';

Widget host(Widget child, {double height = 600}) => MaterialApp(
  theme: buildInkTheme(Brightness.light),
  home: Scaffold(
    body: SizedBox(height: height, child: child),
  ),
);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('a light flick on the card wheel advances exactly one card', (
    tester,
  ) async {
    final focused = <int>[];
    await tester.pumpWidget(
      host(
        CardWheel(
          count: 6,
          initial: 1,
          onFocus: focused.add,
          builder: (_, i, _) => Card(child: Center(child: Text('卡 $i'))),
        ),
      ),
    );
    // Short, gentle swipe: well under half a card, modest speed.
    await tester.fling(find.byType(PageView), const Offset(0, -50), 300);
    await tester.pumpAndSettle();
    expect(focused.last, 2);
    await tester.fling(find.byType(PageView), const Offset(0, 50), 300);
    await tester.pumpAndSettle();
    expect(focused.last, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wheel settles on a whole card after a slow drag', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        CardWheel(
          count: 4,
          initial: 0,
          builder: (_, i, _) => Card(child: Center(child: Text('卡 $i'))),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -9));
      await tester.pump(const Duration(milliseconds: 80));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    final page = tester
        .widget<PageView>(find.byType(PageView))
        .controller!
        .page!;
    expect(page, closeTo(page.roundToDouble(), .001));
  });

  testWidgets('time wheel never settles before the minimum', (tester) async {
    final values = <DateTime>[];
    final today = DateTime(2026, 10, 19, 14, 37);
    await tester.pumpWidget(
      host(
        InkDateTimeWheel(
          initial: DateTime(2026, 10, 19, 9, 0),
          today: today,
          minimum: today,
          onChanged: (d, h, m) =>
              values.add(DateTime(d.year, d.month, d.day, h, m)),
        ),
      ),
    );
    // Initial value is lifted to the next 5-minute slot after "now".
    expect(find.text('14'), findsWidgets);
    expect(find.text('40'), findsWidgets);
    // Drag the hour drum back three hours, into the past.
    await tester.drag(
      find.byKey(const ValueKey('wheel.hour')),
      const Offset(0, 120),
    );
    await tester.pumpAndSettle();
    expect(values, isNotEmpty);
    expect(values.last.isBefore(DateTime(2026, 10, 19, 14, 40)), isFalse);
    expect(find.textContaining('已经过去的时刻不能安排'), findsOneWidget);
  });

  testWidgets('hour drum loops from 23 back to 00', (tester) async {
    final hours = <int>[];
    final today = DateTime(2026, 10, 19, 8);
    await tester.pumpWidget(
      host(
        InkDateTimeWheel(
          showDate: false,
          initial: DateTime(2026, 10, 19, 23, 0),
          today: today,
          onChanged: (_, h, _) => hours.add(h),
        ),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('wheel.hour')),
      const Offset(0, -40),
    );
    await tester.pumpAndSettle();
    expect(hours.last, 0);
  });

  testWidgets('tapping an empty week slot offers it; past slots are refused', (
    tester,
  ) async {
    final zone = tz.getLocation('Asia/Shanghai');
    final now = tz.TZDateTime(zone, 2026, 10, 21, 13, 10); // Wednesday
    final picked = <(tz.TZDateTime, int)>[];
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          child: WeekCalendar(
            blocks: const [],
            tasks: const [],
            zone: zone,
            selectedDay: DateTime(2026, 10, 21),
            now: now,
            dayStart: '09:00',
            dayEnd: '18:00',
            onSelectDay: (_) {},
            onBlockTap: (_) {},
            onSlotPicked: (start, minutes) => picked.add((start, minutes)),
          ),
        ),
        height: 1600,
      ),
    );
    await tester.pumpAndSettle();
    final grid = tester.getTopLeft(find.text('09:00'));
    final columnWidth = (1280 - 48) / 7;
    Offset at(int dayIndex, double hoursFromNine) => Offset(
      48 + columnWidth * dayIndex + columnWidth / 2,
      grid.dy + 8 + 54 * 0 + hoursFromNine * 56 + 4,
    );
    // Thursday 15:00 (future): one-hour default.
    await tester.tapAt(at(3, 6));
    await tester.pump();
    expect(picked.single.$1.day, 22);
    expect(picked.single.$1.hour, 15);
    expect(picked.single.$2, 60);
    // Wednesday 10:00 is already over.
    await tester.tapAt(at(2, 1));
    await tester.pump();
    expect(picked.length, 1);
    expect(find.textContaining('已经过去了'), findsOneWidget);
  });

  testWidgets('a task created from the form never starts in the past', (
    tester,
  ) async {
    final c = PlannerController(storage: MemoryStore());
    await c.initialize();
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.tap(find.byKey(const Key('action.first-task')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '整理投递');
    await tester.enterText(find.byType(TextField).at(1), '更新表格');
    await tester.ensureVisible(find.text('保存安排'));
    await tester.tap(find.text('保存安排'));
    await tester.pumpAndSettle();
    expect(
      DateTime.parse(c.blocks.single['start_at']).isAfter(DateTime.now()),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
