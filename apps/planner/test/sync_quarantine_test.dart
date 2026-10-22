import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:time_planner/controller.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _snapshot() => {
  'revision': 9,
  'server_time': '2026-10-19T16:00:00Z',
  'tasks': [
    {'id': 'kept', 'title': '保住的', 'state': 'ready', 'version': 1},
  ],
  'blocks': <Json>[],
  'sessions': <Json>[],
  'feedbacks': <Json>[],
  'waiting_checks': <Json>[],
  'reviews': <Json>[],
  'settings': {'timezone': 'Asia/Shanghai'},
};

/// Submit two operations while the phone has no connection.
Future<MemoryStore> _queueTwo(MemoryStore storage) async {
  final offline = PlannerController(
    storage: storage,
    transport: MockClient(
      (_) async => throw http.ClientException('offline'),
    ),
  );
  await offline.initialize();
  await offline.connect('http://127.0.0.1:8787', 'test-token');
  for (final title in ['被拒的', '保住的']) {
    await offline.submit('task.create', {
      'id': 'local-$title',
      'title': title,
      'outcome_criteria': '交付',
      'remaining_minutes': 30,
    });
  }
  expect(offline.pending.length, 2);
  offline.dispose();
  return storage;
}

String _rejectedTitle(http.Request request) {
  final operation = jsonDecode(request.body) as Map<String, dynamic>;
  final payload = operation['payload'] as Map<String, dynamic>;
  return payload['title'] as String? ?? '';
}

void main() {
  test('a permanently rejected action is quarantined and the queue keeps going', () async {
    final storage = await _queueTwo(MemoryStore());
    final controller = PlannerController(
      storage: storage,
      transport: MockClient((request) async {
        if (request.method == 'POST') {
          if (_rejectedTitle(request) == '被拒的') {
            return http.Response(
              jsonEncode({'message': '这个待办已经不存在了'}),
              422,
              headers: _json,
            );
          }
          return http.Response(
            jsonEncode({'revision': 9, 'entity': {}}),
            200,
            headers: _json,
          );
        }
        return http.Response(jsonEncode(_snapshot()), 200, headers: _json);
      }),
    );
    await controller.initialize();
    await controller.sync();

    expect(controller.pending, isEmpty);
    expect(controller.connected, isTrue);
    expect(controller.conflict, contains('新建待办'));
    expect(controller.preservedConflicts.length, 1);
    final kept = controller.preservedConflicts.single;
    expect(kept['status'], 422);
    expect(
      (kept['operations'] as List).single['payload']['title'],
      '被拒的',
    );
    expect(controller.tasks.single['title'], '保住的');
    controller.dispose();
  });

  test('a conflict (409) still blocks the queue and stays visible', () async {
    final storage = await _queueTwo(MemoryStore());
    final controller = PlannerController(
      storage: storage,
      transport: MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'message': '状态已变化'}),
            409,
            headers: _json,
          );
        }
        return http.Response(jsonEncode(_snapshot()), 200, headers: _json);
      }),
    );
    await controller.initialize();
    await controller.sync();

    expect(controller.pending.length, 2);
    expect(controller.preservedConflicts, isEmpty);
    expect(controller.conflict, isNotNull);
    controller.dispose();
  });
}
