import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native desktop UI saves execution feedback to a real isolated server',
    (tester) async {
      timezone_data.initializeTimeZones();
      final fixturePath = Platform.environment['PLANNER_E2E_FIXTURE'];
      expect(
        fixturePath,
        isNotNull,
        reason: 'Run through tools/test-desktop.ps1',
      );
      final fixture =
          jsonDecode(await File(fixturePath!).readAsString()) as Json;
      final controller = PlannerController(
        storage: MemoryStore(),
        clock: fixture['clock'] == null
            ? null
            : () => DateTime.parse(fixture['clock']),
      );
      await controller.initialize();
      await controller.connect(fixture['server_url'], fixture['token']);
      expect(controller.connected, isTrue);
      final screenshotKey = GlobalKey();
      Future<void> capture(String name) async {
        final folder = fixture['screenshots_dir'] as String?;
        if (folder == null) return;
        await tester.pump();
        final boundary =
            screenshotKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final rendered = await boundary.toImage(pixelRatio: 1);
        try {
          final data = await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await Directory(folder).create(recursive: true);
          await File('$folder/$name.png')
              .writeAsBytes(data!.buffer.asUint8List());
        } finally {
          rendered.dispose();
        }
      }

      await tester.pumpWidget(
        RepaintBoundary(
          key: screenshotKey,
          child: PlannerApp(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('action.first-task')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '原生界面验收任务');
      await tester.enterText(find.byType(TextField).at(1), '记录一次真实执行和等待结果');
      await tester.ensureVisible(find.byKey(const Key('action.save-task')));
      await tester.tap(find.byKey(const Key('action.save-task')));
      await tester.pumpAndSettle();
      await controller.sync();
      expect(controller.pending, isEmpty);
      expect(controller.tasks.single['title'], '原生界面验收任务');
      await tester.pumpAndSettle();
      await capture('home-desktop');
      final primaryTask = controller.tasks.single['id'];
      final followingStart = DateTime.parse(controller.blocks.single['end_at']);
      await controller.submit('task.create', {
        'id': 'native-next-task',
        'title': '后续弹性安排',
        'outcome_criteria': '保留一次可解释的改期',
        'remaining_minutes': 30,
      });
      await controller.submit('block.create', {
        'id': 'native-next-block',
        'task_id': 'native-next-task',
        'kind': 'flexible',
        'start_at': followingStart.toIso8601String(),
        'end_at': followingStart
            .add(const Duration(minutes: 30))
            .toIso8601String(),
        'timezone': controller.settings['timezone'],
      });
      await controller.sync();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('action.start')));
      await tester.pumpAndSettle();
      await controller.sync();
      expect(controller.sessions.single['state'], 'running');
      await tester.pumpAndSettle();
      if (find.byType(SnackBar).evaluate().isNotEmpty) {
        await tester.fling(find.byType(SnackBar), const Offset(0, 180), 1000);
        await tester.pumpAndSettle();
      }
      await capture('focus-desktop');
      await tester.tap(find.byKey(const Key('action.extend.15')));
      await tester.pumpAndSettle();
      await controller.sync();
      await tester.pumpAndSettle();
      expect(controller.sessions.single['adjustment']['status'], 'applied');
      expect(
        controller.blocks.firstWhere(
          (b) => b['id'] == 'native-next-block',
        )['status'],
        'superseded',
      );
      final extendedEnd = controller.sessions.single['expected_end_at'];
      await capture('automatic-shift');
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      await controller.sync();
      await tester.pumpAndSettle();
      expect(
        controller.blocks.firstWhere(
          (b) => b['id'] == 'native-next-block',
        )['status'],
        'scheduled',
      );
      expect(controller.sessions.single['expected_end_at'], extendedEnd);
      // The undo receipt covers the lower card actions until it dismisses.
      await tester.fling(find.byType(SnackBar), const Offset(0, 180), 1000);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('action.end')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('feedback.waiting')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '已提交运行，稍后检查输出。');
      await tester.ensureVisible(find.byKey(const Key('action.save-feedback')));
      await tester.tap(find.byKey(const Key('action.save-feedback')));
      await tester.pumpAndSettle();
      await controller.sync();
      final actual = await controller.request('GET', '/api/v1/snapshot');
      expect(
        (actual['tasks'] as List).firstWhere(
          (t) => t['id'] == primaryTask,
        )['state'],
        'waiting',
      );
      expect((actual['sessions'] as List).single['state'], 'closed');
      expect(
        (actual['feedbacks'] as List).single['outcome_text'],
        '已提交运行，稍后检查输出。',
      );
      expect((actual['waiting_checks'] as List).length, 1);
      final check = (actual['waiting_checks'] as List).single;
      await tester.tap(find.text('诸事'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('waiting.snooze.${check['id']}')));
      await tester.pumpAndSettle();
      await capture('waiting-reschedule');
      await tester.tap(find.byKey(const Key('waiting.save-snooze')));
      await tester.pumpAndSettle();
      await controller.sync();
      await tester.pumpAndSettle();
      final changed = (controller.state['waiting_checks'] as List).single;
      expect(
        DateTime.parse(changed['check_at'])
            .isAfter(DateTime.parse(check['check_at'])),
        isTrue,
      );
      expect(changed['resolved_at'], isNull);
      expect(changed['version'], 2);
      if (fixture['review_mock'] == true) {
        final day = controller.blocks.first['start_at'].substring(0, 10);
        final material = await controller.uploadMaterial(
          'notes.md',
          day,
          '本次实验结果待验证',
          true,
          utf8.encode('已记录偏压参数，侧壁角度需要进一步核验。'),
        );
        await controller.generateReview(day, '今天提交运行，还在等待输出。', [
          material['id'],
        ], 'native-review-001');
        expect(
          (controller.state['analyses'] as List).single['text'],
          contains('材料'),
        );
        for (final offset in [1, 2, 4, 6]) {
          final start = DateTime.parse(fixture['clock'])
              .add(Duration(days: offset, hours: offset));
          await controller.submit('task.create', {
            'id': 'week-task-$offset',
            'title': '本周实验 $offset',
            'outcome_criteria': '记录数据',
            'remaining_minutes': 60,
          });
          await controller.submit('block.create', {
            'id': 'week-block-$offset',
            'task_id': 'week-task-$offset',
            'kind': 'flexible',
            'start_at': start.toIso8601String(),
            'end_at': start.add(const Duration(hours: 1)).toIso8601String(),
            'timezone': controller.settings['timezone'],
          });
        }
        await controller.sync();
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.tap(find.text('今日'));
        await tester.pumpAndSettle();
        await capture('home-phone');
        await tester.tap(find.text('一周'));
        await tester.pumpAndSettle();
        await capture('week-phone');
        await tester.tap(find.text('回顾'));
        await tester.pumpAndSettle();
        await capture('review-phone');
        await tester.ensureVisible(find.textContaining('材料').last);
        await tester.tap(find.text('诸事'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('task.delete.native-next-task')),
        );
        await tester.tap(
          find.byKey(const ValueKey('task.delete.native-next-task')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('task.confirm-delete')));
        await tester.pumpAndSettle();
        await controller.sync();
        expect(
          controller.tasks.firstWhere(
            (t) => t['id'] == 'native-next-task',
          )['state'],
          'cancelled',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
