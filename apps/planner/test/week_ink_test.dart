import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;
import 'package:time_planner/controller.dart';
import 'package:time_planner/theme/ink_theme.dart';
import 'package:time_planner/theme/schedule_ink.dart';
import 'package:time_planner/theme/tokens.dart';
import 'package:time_planner/widgets/week_overview.dart';

void main() {
  setUpAll(data.initializeTimeZones);
  final tasks = <Json>[
    for (var i = 0; i < 8; i++) {'id': 't$i', 'title': '待办$i'},
  ];
  test('task pigments stay distinct and stable; text remains readable on both papers', () {
    for (final brightness in Brightness.values) {
      final colors = [
        for (final t in tasks) ScheduleInk.forTask(t['id'], tasks, brightness),
      ];
      expect(colors.toSet().length, 8);
      final renamed = tasks
          .map((t) => {...t, 'title': '改名', 'state': 'cancelled'})
          .toList();
      for (var i = 0; i < tasks.length; i++) {
        expect(
          ScheduleInk.forTask(tasks[i]['id'], renamed, brightness),
          colors[i],
        );
        final paper = brightness == Brightness.light
            ? InkPalette.light.paper
            : InkPalette.dark.paper;
        final surface = Color.alphaBlend(
          colors[i].withValues(alpha: .35),
          paper,
        );
        final a = colors[i].computeLuminance(), b = surface.computeLuminance();
        expect(
          (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05),
          greaterThanOrEqualTo(4.5),
        );
      }
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      '390px $brightness shows short titles and reveals full details',
      (tester) async {
        tester.view.physicalSize = const Size(390, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final blocks = <Json>[
          {
            'id': 'b0',
            'task_id': 't0',
            'title': '实验分析报告',
            'kind': 'flexible',
            'status': 'scheduled',
            'start_at': '2026-10-19T16:00:00Z',
            'end_at': '2026-10-19T17:00:00Z',
          },
          {
            'id': 'b1',
            'task_id': 't1',
            'title': '算法学习',
            'kind': 'flexible',
            'status': 'scheduled',
            'start_at': '2026-10-20T17:00:00Z',
            'end_at': '2026-10-20T19:00:00Z',
          },
          {
            'id': 'b2',
            'task_id': 't2',
            'title': '短时检查',
            'kind': 'flexible',
            'status': 'scheduled',
            'start_at': '2026-10-19T17:00:00Z',
            'end_at': '2026-10-19T17:05:00Z',
          },
        ];
        Json? opened;
        DateTime? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildInkTheme(brightness),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(20),
                child: WeekOverview(
                  tasks: tasks,
                  blocks: blocks,
                  day: DateTime(2026, 10, 19),
                  now: DateTime(2026, 10, 19),
                  zone: tz.getLocation('America/Los_Angeles'),
                  dayStart: '09:00',
                  dayEnd: '22:00',
                  onBlockTap: (b) => opened = b,
                  onSelectDay: (d) => selected = d,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('实验分'), findsOneWidget);
        expect(find.text('算法学习'), findsOneWidget);
        expect(find.text('短时检'), findsOneWidget);
        await tester.longPress(find.byKey(const ValueKey('week.stamp.b0')));
        await tester.pumpAndSettle();
        expect(find.text('实验分析报告\n09:00—10:00'), findsOneWidget);
        await tester.tapAt(const Offset(380, 580));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('week.stamp.b1')));
        expect(opened?['id'], 'b1');
        await tester.tap(find.byKey(const ValueKey('week.day.1')));
        expect(selected?.day, 20);
        for (var i = 0; i < 7; i++) {
          expect(
            tester.getRect(find.byKey(ValueKey('week.day.$i'))).right,
            lessThanOrEqualTo(390),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
