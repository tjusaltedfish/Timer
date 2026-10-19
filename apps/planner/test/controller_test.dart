import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:time_planner/controller.dart';

void main() {
  test(
    'returned result resolves waiting without creating a work session',
    () async {
      final controller = PlannerController(storage: MemoryStore());
      await controller.initialize();
      controller.state['tasks'] = <Json>[
        {
          'id': 't',
          'title': '扫描',
          'state': 'waiting',
          'remaining_minutes': 60,
          'version': 1,
        },
      ];
      controller.state['waiting_checks'] = <Json>[
        {
          'id': 'w',
          'task_id': 't',
          'source_block_id': 'b',
          'resolved_at': null,
        },
      ];
      await controller.submit('waiting.resolve', {
        'id': 'w',
        'resolution': 'done',
        'outcome_text': '输出已核对',
      });
      expect(controller.tasks.single['state'], 'done');
      expect(controller.sessions, isEmpty);
      expect(
        (controller.state['waiting_checks'] as List).single['resolved_at'],
        isNotNull,
      );
      controller.dispose();
    },
  );
  test(
    'offline actions survive restart and replay with the same operation id',
    () async {
      final storage = MemoryStore();
      final controller = PlannerController(
        storage: storage,
        transport: MockClient(
          (_) async => throw http.ClientException('offline'),
        ),
      );
      await controller.initialize();
      await controller.connect('http://127.0.0.1:8787', 'test-token');
      await controller.submit('task.create', {
        'id': 'local-task',
        'title': '算法',
        'outcome_criteria': '完成两道题',
        'remaining_minutes': 45,
      });
      expect(controller.tasks.single['title'], '算法');
      expect(controller.pending.length, 1);
      final originalId = controller.pending.single['operation_id'];
      controller.dispose();
      final requests = <Map<String, dynamic>>[];
      final restarted = PlannerController(
        storage: storage,
        transport: MockClient((request) async {
          if (request.method == 'POST') {
            final operation = jsonDecode(request.body) as Map<String, dynamic>;
            requests.add(operation);
            return http.Response(
              jsonEncode({'revision': 1, 'entity': {}}),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'revision': 1,
              'tasks': [
                {'id': 'local-task', 'title': '算法'},
              ],
              'blocks': [],
              'sessions': [],
              'feedbacks': [],
              'waiting_checks': [],
              'reviews': [],
              'settings': {'timezone': 'America/Los_Angeles'},
            }),
            200,
          );
        }),
      );
      await restarted.initialize();
      await restarted.sync();
      expect(requests.single['operation_id'], originalId);
      expect(restarted.pending, isEmpty);
      expect(restarted.tasks.single['title'], '算法');
      restarted.dispose();
    },
  );

  test(
    'conflicting offline action remains visible and is not silently dropped',
    () async {
      final storage = MemoryStore();
      final controller = PlannerController(
        storage: storage,
        transport: MockClient(
          (_) async => http.Response(
            '{"message":"状态已变化"}',
            409,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await controller.initialize();
      await controller.connect('http://127.0.0.1:8787', 'test-token');
      await controller.submit('task.create', {
        'id': 'draft',
        'title': '实验',
        'outcome_criteria': '记录参数',
        'remaining_minutes': 60,
      });
      await controller.sync();
      expect(controller.pending.length, 1);
      expect(controller.conflict, isNotNull);
      expect(controller.tasks.single['title'], '实验');
      controller.dispose();
    },
  );
}
