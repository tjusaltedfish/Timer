import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  testWidgets(
    'review sends saved material ids and human text, then shows the generated analysis',
    (tester) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = blankState();
      state['materials'] = [
        {
          'id': 'm1',
          'name': '实验.md',
          'date': '2026-10-19',
          'characters': 20,
          'external_allowed': true,
        },
      ];
      Json? generated;
      final c = PlannerController(
        storage: MemoryStore(),
        clock: () => DateTime.utc(2026, 10, 19, 16),
        transport: MockClient((request) async {
          if (request.url.path.endsWith('/generate')) {
            generated = jsonDecode(request.body) as Json;
            state['analyses'] = [
              {
                'id': generated!['request_id'],
                'date': '2026-10-19',
                'text': '实验现象待核验，明天先复查参数。',
                'model': 'test-model',
              },
            ];
            return http.Response(
              jsonEncode((state['analyses'] as List).single),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(state),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await c.initialize();
      await c.connect('http://127.0.0.1:8787', 'fixture-token');
      await tester.pumpWidget(PlannerApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('回顾'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '你的两三句话'),
        '今天跑了实验，结果还没确认。',
      );
      await tester.tap(find.byKey(const Key('review.generate')));
      await tester.pumpAndSettle();
      expect(generated!['material_ids'], ['m1']);
      expect(generated!['text'], '今天跑了实验，结果还没确认。');
      await tester.ensureVisible(find.text('实验现象待核验，明天先复查参数。'));
      expect(find.text('助手复盘'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
