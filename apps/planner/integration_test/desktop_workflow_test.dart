import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
      final controller = PlannerController(storage: MemoryStore());
      await controller.initialize();
      await controller.connect(fixture['server_url'], fixture['token']);
      expect(controller.connected, isTrue);
      await tester.pumpWidget(PlannerApp(controller: controller));
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
      await tester.ensureVisible(find.byKey(const Key('action.start')));
      await tester.tap(find.byKey(const Key('action.start')));
      await tester.pumpAndSettle();
      await controller.sync();
      expect(controller.sessions.single['state'], 'running');
      await tester.ensureVisible(find.byKey(const Key('action.end')));
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
      expect((actual['tasks'] as List).single['state'], 'waiting');
      expect((actual['sessions'] as List).single['state'], 'closed');
      expect(
        (actual['feedbacks'] as List).single['outcome_text'],
        '已提交运行，稍后检查输出。',
      );
      expect((actual['waiting_checks'] as List).length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
