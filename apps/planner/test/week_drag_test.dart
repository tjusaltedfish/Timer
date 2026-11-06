import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:time_planner/controller.dart';
import 'package:time_planner/theme/ink_theme.dart';
import 'package:time_planner/week_calendar.dart';

void main() {
  tzdata.initializeTimeZones();

  final zone = tz.getLocation('Asia/Shanghai');
  // Thursday 2026-11-05 08:00 in Shanghai.
  final now = tz.TZDateTime(zone, 2026, 11, 5, 8);
  const columnWidth = (1280 - 48) / 7;

  Json block(String id, String title, String start, String end) => {
    'id': id,
    'title': title,
    'kind': 'flexible',
    'status': 'scheduled',
    'version': 1,
    'start_at': start,
    'end_at': end,
  };

  final blocks = [
    // Thursday 10:00–11:00 and Friday 14:00–15:00 local time.
    block('a', '写报告', '2026-11-05T02:00:00.000Z', '2026-11-05T03:00:00.000Z'),
    block('b', '组会', '2026-11-06T06:00:00.000Z', '2026-11-06T07:00:00.000Z'),
  ];

  Future<List<(String, tz.TZDateTime, tz.TZDateTime)>> pump(
    WidgetTester tester, {
    List<Json> sessions = const [],
  }) async {
    final moved = <(String, tz.TZDateTime, tz.TZDateTime)>[];
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildInkTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: WeekCalendar(
              blocks: blocks,
              tasks: const [],
              sessions: sessions,
              zone: zone,
              now: now,
              selectedDay: DateTime(2026, 11, 5),
              dayStart: '09:00',
              dayEnd: '18:00',
              onSelectDay: (_) {},
              onBlockTap: (_) {},
              onSlotPicked: (_, _) {},
              onBlockMoved: (b, start, end) =>
                  moved.add((b['id'] as String, start, end)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return moved;
  }

  Offset chipCenter(WidgetTester tester, String id) =>
      tester.getCenter(find.byKey(ValueKey('week.block.$id')));

  testWidgets('mouse drag moves a block to another day and time', (
    tester,
  ) async {
    final moved = await pump(tester);
    final gesture = await tester.startGesture(
      chipCenter(tester, 'a'),
      kind: PointerDeviceKind.mouse,
    );
    // One column right, an hour and a half later.
    await gesture.moveBy(const Offset(20, 20));
    await tester.pump();
    await gesture.moveTo(
      chipCenter(tester, 'a') +
          const Offset(columnWidth, desktopHourHeight * 1.5),
    );
    await tester.pump();
    expect(find.byKey(const Key('week.drag.preview')), findsOneWidget);
    expect(find.textContaining('11:30–12:30'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(moved, hasLength(1));
    final (id, start, end) = moved.single;
    expect(id, 'a');
    expect((start.day, start.hour, start.minute), (6, 11, 30));
    expect(end.difference(start), const Duration(hours: 1));
    expect(find.byKey(const Key('week.drag.preview')), findsNothing);
  });

  testWidgets('dragging the lower edge changes the length in 15-minute steps', (
    tester,
  ) async {
    final moved = await pump(tester);
    final handle = tester.getCenter(
      find.descendant(
        of: find.byKey(const ValueKey('week.block.a')),
        matching: find.byKey(const Key('week.block.resize')),
      ),
    );
    final gesture = await tester.startGesture(
      handle,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, desktopHourHeight * .55));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final (_, start, end) = moved.single;
    expect((start.hour, start.minute), (10, 0));
    expect((end.hour, end.minute), (10 + 1, 30));
  });

  testWidgets('a drop onto another block is refused and explained', (
    tester,
  ) async {
    final moved = await pump(tester);
    final gesture = await tester.startGesture(
      chipCenter(tester, 'a'),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(columnWidth, desktopHourHeight * 4));
    await tester.pump();
    expect(find.textContaining('撞了'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(moved, isEmpty);
    expect(find.textContaining('没挪过去'), findsOneWidget);
  });

  testWidgets('a finger moves a block after a long press', (tester) async {
    final moved = await pump(tester);
    final gesture = await tester.startGesture(chipCenter(tester, 'a'));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(columnWidth, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final (_, start, _) = moved.single;
    expect((start.day, start.hour, start.minute), (6, 10, 0));
  });

  testWidgets('blocks with an execution record cannot be dragged', (
    tester,
  ) async {
    final moved = await pump(
      tester,
      sessions: [
        {
          'id': 's',
          'block_id': 'b',
          'state': 'running',
          'actual_start_at': '2026-11-06T06:00:00.000Z',
          'expected_end_at': '2026-11-06T07:00:00.000Z',
        },
      ],
    );
    expect(find.byKey(const Key('week.block.resize')), findsOneWidget);
    final gesture = await tester.startGesture(
      chipCenter(tester, 'b'),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, desktopHourHeight));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(moved, isEmpty);
  });
}
