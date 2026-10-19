import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  final now = DateTime.utc(2026, 10, 19, 16);
  Json fixture(String status) {
    final old = <String, dynamic>{
      'id': 'b1',
      'task_id': 't1',
      'title': '下一件',
      'kind': 'flexible',
      'status': status == 'applied' ? 'superseded' : 'scheduled',
      'version': 1,
      'timezone': 'America/Los_Angeles',
      'start_at': '2026-10-19T17:00:00Z',
      'end_at': '2026-10-19T17:30:00Z',
    };
    final next = <String, dynamic>{
      ...old,
      'id': 'b2',
      'source_block_id': 'b1',
      'status': 'scheduled',
      'start_at': '2026-10-19T17:15:00Z',
      'end_at': '2026-10-19T17:45:00Z',
    };
    return {
      ...blankState(),
      'revision': 7,
      'tasks': <Json>[
        for (final id in ['t0', 't1'])
          {
            'id': id,
            'title': id == 't0' ? '正在投入' : '下一件',
            'state': id == 't0' ? 'in_progress' : 'ready',
            'version': 1,
            'outcome_criteria': '保存输出',
            'remaining_minutes': 60,
            'dependency_ids': <String>[],
          },
      ],
      'blocks': <Json>[
        {
          'id': 'b0',
          'task_id': 't0',
          'title': '正在投入',
          'status': 'scheduled',
          'kind': 'flexible',
          'start_at': '2026-10-19T16:00:00Z',
          'end_at': '2026-10-19T17:00:00Z',
          'version': 1,
          'timezone': 'America/Los_Angeles',
        },
        old,
        if (status == 'applied') next,
      ],
      'sessions': <Json>[
        {
          'id': 's',
          'block_id': 'b0',
          'task_id': 't0',
          'state': 'running',
          'actual_start_at': now.toIso8601String(),
          'expected_end_at': '2026-10-19T17:15:00Z',
          'last_event_at': now.toIso8601String(),
          'planned_seconds': 4500,
          'version': 2,
          'intervals': <Json>[
            {'start_at': now.toIso8601String(), 'end_at': null},
          ],
          'adjustment': {
            'status': status == 'draft' ? 'proposal' : status,
            'proposal_id': 'p',
            'count': 1,
            'reason': '后续安排顺延',
          },
        },
      ],
      'proposals': <Json>[
        {
          'id': 'p',
          'kind': 'ripple',
          'status': status,
          'auto': status == 'applied',
          'created_at': now.toIso8601String(),
          'base_revision': 7,
          'applied_revision': 7,
          'expires_at': now.add(const Duration(minutes: 15)).toIso8601String(),
          'reason': status == 'blocked' ? '遇到固定预约，原安排已保留' : '后续弹性安排顺延十五分钟',
          'old_blocks': <Json>[old],
          'new_blocks': <Json>[if (status != 'blocked') next],
          'unscheduled_items': <Json>[
            if (status == 'blocked')
              {'title': '正在投入', 'minutes': 15, 'reason': '遇到固定预约'},
          ],
        },
      ],
    };
  }

  Future<PlannerController> show(
    WidgetTester tester,
    String status,
    List<String> sent, {
    int? revision,
  }) async {
    tzdata.initializeTimeZones();
    final remote = fixture(status);
    if (revision != null) remote['revision'] = revision;
    final c = PlannerController(
      storage: MemoryStore(),
      clock: () => now,
      transport: MockClient((request) async {
        if (request.method == 'POST') {
          final op = jsonDecode(request.body) as Json;
          sent.add(op['kind']);
          final plan = (remote['proposals'] as List).single;
          if (op['kind'] == 'plan.undo') {
            plan['status'] = 'undone';
            remote['blocks'] = (remote['blocks'] as List)
                .where((b) => b['id'] != 'b2')
                .toList();
            (remote['blocks'] as List).last['status'] = 'scheduled';
          }
          if (op['kind'] == 'plan.apply') {
            plan['status'] = 'applied';
            plan['applied_revision'] = (remote['revision'] as int) + 1;
            (remote['blocks'] as List).last['status'] = 'superseded';
            (remote['blocks'] as List).add((plan['new_blocks'] as List).single);
          }
          if (op['kind'] == 'settings.update') {
            (remote['settings'] as Json).addAll(op['payload'] as Json);
          }
          remote['revision'] = (remote['revision'] as int) + 1;
          return http.Response(jsonEncode({'revision': 8, 'entity': {}}), 200);
        }
        return http.Response(
          jsonEncode(remote),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await c.initialize();
    await c.connect('http://127.0.0.1:8787', 'isolated-token');
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets(
    'a small automatic shift offers undo without rewinding the current execution',
    (tester) async {
      final sent = <String>[];
      final c = await show(tester, 'applied', sent);
      expect(find.text('已顺延 1 段'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(sent, contains('plan.undo'));
      expect(c.sessions.single['expected_end_at'], '2026-10-19T17:15:00Z');
      expect(c.blocks.last['id'], 'b1');
      expect(c.blocks.last['status'], 'scheduled');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets('large or opted-out shift opens a review before applying it', (
    tester,
  ) async {
    final sent = <String>[];
    final c = await show(tester, 'draft', sent);
    expect(sent, isEmpty);
    await tester.tap(find.text('查看调整'));
    await tester.pumpAndSettle();
    expect(find.text('调整后'), findsOneWidget);
    await tester.tap(find.byKey(const Key('plan.confirm')));
    await tester.pumpAndSettle();
    expect(sent, contains('plan.apply'));
    expect(c.blocks.last['id'], 'b2');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets(
    'hard conflicts can be inspected but cannot be confirmed as a valid plan',
    (tester) async {
      final sent = <String>[];
      final c = await show(tester, 'blocked', sent);
      await tester.tap(find.text('查看调整'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plan.confirm')), findsNothing);
      expect(find.textContaining('固定预约'), findsAtLeastNWidgets(1));
      expect(sent, isEmpty);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'a stale undo is not advertised and automatic shifts can be switched off',
    (tester) async {
      final sent = <String>[];
      final c = await show(tester, 'applied', sent, revision: 9);
      expect(find.text('撤销'), findsNothing);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('settings.auto-adjust'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(c.settings['auto_adjust'], false);
      expect(sent, contains('settings.update'));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
