import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';
import 'package:time_planner/reminders.dart';

void main() {
  testWidgets(
    'deleting the current focus explicitly ends it and preserves actual work',
    (tester) async {
      tzdata.initializeTimeZones();
      var current = DateTime.utc(2026, 10, 19, 16);
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
        'start_at': current.toIso8601String(),
        'end_at': current.add(const Duration(hours: 1)).toIso8601String(),
      });
      await c.startBlock(c.blocks.single);
      current = current.add(const Duration(minutes: 10));
      await tester.pumpWidget(PlannerApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('待办操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除待办'));
      await tester.pumpAndSettle();
      expect(find.text('结束并删除'), findsOneWidget);
      // Leaving the confirmation changes neither the timer nor the task.
      await tester.tap(find.text('保留'));
      await tester.pumpAndSettle();
      expect(c.sessions.single['state'], 'running');
      await tester.tap(find.byTooltip('待办操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除待办'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task.confirm-delete')));
      await tester.pumpAndSettle();
      expect(c.tasks.single['state'], 'cancelled');
      expect(c.sessions.single['state'], 'closed');
      expect(c.sessions.single['actual_end_at'], current.toIso8601String());
      final interval = (c.sessions.single['intervals'] as List).single as Json;
      expect(
        DateTime.parse(interval['end_at'])
            .difference(DateTime.parse(interval['start_at'])),
        const Duration(minutes: 10),
      );
      expect(
        buildReminders(
          c.state,
          current,
        ).where((r) => r.key.startsWith('session:')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  for (final entry in ['home', 'week', 'tasks']) {
    testWidgets(
      '360px $entry allows task edit and deletion with the keyboard open',
      (tester) async {
        tzdata.initializeTimeZones();
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final current = DateTime.utc(2026, 10, 19, 16);
        final c = PlannerController(
          storage: MemoryStore(),
          clock: () => current,
        );
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
        Future<void> open(bool edit) async {
          if (entry == 'home') {
            await tester.tap(find.byTooltip('待办操作'));
            await tester.pumpAndSettle();
            await tester.tap(find.text(edit ? '编辑待办' : '删除待办'));
          } else if (entry == 'week') {
            await tester.tap(find.text('一周').last);
            await tester.pumpAndSettle();
            // 第二次进来时可能还停在单天概览，先退回整周总览。
            if (find.byKey(const Key('week.overview')).evaluate().isEmpty) {
              await tester.tap(find.byKey(const Key('week.day.close')));
              await tester.pumpAndSettle();
            }
            // 手机周视图先点开当天（周一），再从紧凑列表点这一件事。
            await tester.tap(find.byKey(const ValueKey('week.day.0')));
            await tester.pumpAndSettle();
            final detailTitle = find.byKey(const ValueKey('week.day.item.b'));
            await tester.ensureVisible(detailTitle);
            await tester.tap(detailTitle);
            await tester.pumpAndSettle();
            await tester.tap(
              edit
                  ? find.text('编辑待办')
                  : find.byKey(const ValueKey('task.delete.t')),
            );
          } else {
            await tester.tap(find.text('诸事').last);
            await tester.pumpAndSettle();
            final target = edit
                ? find.text('编辑')
                : find.byKey(const ValueKey('task.delete.t'));
            await tester.ensureVisible(target);
            await tester.tap(target);
          }
          await tester.pumpAndSettle();
        }

        await open(true);
        await tester.enterText(
          find.widgetWithText(TextField, '任务名称'),
          '已编辑的实验',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('保存'));
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(c.tasks.single['title'], '已编辑的实验');
        expect(c.blocks.single['title'], '已编辑的实验');
        await open(false);
        await tester.tap(find.byKey(const Key('task.confirm-delete')));
        await tester.pumpAndSettle();
        expect(c.tasks.single['state'], 'cancelled');
        expect(c.blocks.single['status'], 'cancelled');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }

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
