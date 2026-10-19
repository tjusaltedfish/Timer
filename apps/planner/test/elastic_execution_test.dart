import 'package:flutter_test/flutter_test.dart';
import 'package:time_planner/controller.dart';

void main() {
  late PlannerController c;
  late DateTime now;
  late MemoryStore storage;

  setUp(() async {
    now = DateTime.utc(2026, 10, 19, 16);
    storage = MemoryStore();
    c = PlannerController(storage: storage, clock: () => now);
    await c.initialize();
    await c.submit('task.create', {
      'id': 't',
      'title': '扫描',
      'outcome_criteria': '保存输出',
      'remaining_minutes': 60,
    });
    await c.submit('block.create', {
      'id': 'b',
      'task_id': 't',
      'start_at': now.toIso8601String(),
      'end_at': now.add(const Duration(hours: 1)).toIso8601String(),
      'kind': 'flexible',
      'timezone': 'America/Los_Angeles',
    });
  });
  tearDown(() => c.dispose());

  test('late start keeps the selected end and a timer extension leaves the gap empty', () async {
    now = now.add(const Duration(minutes: 20));
    await c.startBlock(c.blocks.single, mode: 'keep_end');
    expect(c.sessions.single['expected_end_at'], c.blocks.single['end_at']);
    expect(c.sessions.single['planned_seconds'], 40 * 60);
    now = now.add(const Duration(minutes: 45));
    await c.extendSession(c.sessions.single, 15);
    final session = c.sessions.single;
    expect(session['state'], 'running');
    expect((session['intervals'] as List).length, 2);
    expect(
      (session['intervals'] as List).last['start_at'],
      now.toIso8601String(),
    );
    expect(
      session['expected_end_at'],
      now.add(const Duration(minutes: 15)).toIso8601String(),
    );
    expect(session['planned_seconds'], 55 * 60);
    final originalId = c.pending.last['operation_id'];
    final restarted = PlannerController(storage: storage, clock: () => now);
    await restarted.initialize();
    expect(restarted.pending.last['operation_id'], originalId);
    expect(
      restarted.sessions.single['expected_end_at'],
      session['expected_end_at'],
    );
    restarted.dispose();
  });

  test(
    'extending a paused session leaves it paused and resume excludes the pause',
    () async {
      await c.startBlock(c.blocks.single);
      now = now.add(const Duration(minutes: 10));
      await c.controlSession(c.sessions.single, 'pause');
      now = now.add(const Duration(minutes: 5));
      await c.extendSession(c.sessions.single, 15);
      expect(c.sessions.single['state'], 'paused');
      now = now.add(const Duration(minutes: 5));
      await c.controlSession(c.sessions.single, 'resume');
      expect(
        DateTime.parse(c.sessions.single['expected_end_at']),
        DateTime.utc(2026, 10, 19, 17, 25),
      );
      expect(
        (c.sessions.single['intervals'] as List).first['end_at'],
        DateTime.utc(2026, 10, 19, 16, 10).toIso8601String(),
      );
    },
  );

  test(
    'invalid extensions and ended sessions never enter the offline queue',
    () async {
      await c.startBlock(c.blocks.single);
      final count = c.pending.length;
      await expectLater(
        c.extendSession(c.sessions.single, 121),
        throwsA(isA<ApiFailure>()),
      );
      expect(c.pending.length, count);
      await c.controlSession(c.sessions.single, 'end');
      await expectLater(
        c.extendSession(c.sessions.single, 15),
        throwsA(isA<ApiFailure>()),
      );
    },
  );

  test('interrupted result requires remaining work and waiting reschedule retains identity', () async {
    await c.startBlock(c.blocks.single);
    await c.controlSession(c.sessions.single, 'end');
    final before = c.pending.length;
    await expectLater(
      c.submit('feedback.create', {
        'session_id': c.sessions.single['id'],
        'choice': 'interrupted',
      }),
      throwsA(isA<ApiFailure>()),
    );
    expect(c.pending.length, before);
    await c.submit('feedback.create', {
      'session_id': c.sessions.single['id'],
      'choice': 'waiting',
      'check_at': now.add(const Duration(hours: 2)).toIso8601String(),
    });
    final check = (c.state['waiting_checks'] as List).single as Json;
    final id = check['id'];
    await c.snoozeWaiting(check, now.add(const Duration(hours: 4)));
    expect((c.state['waiting_checks'] as List).length, 1);
    expect((c.state['waiting_checks'] as List).single['id'], id);
    expect((c.state['waiting_checks'] as List).single['version'], 2);
    expect(c.pending.last['payload']['version'], 1);
    await expectLater(
      c.startBlock(c.blocks.single),
      throwsA(isA<ApiFailure>()),
    );
  });

  test(
    'keep_end after expiry is rejected and review versions advance offline',
    () async {
      now = now.add(const Duration(hours: 2));
      await expectLater(
        c.startBlock(c.blocks.single, mode: 'keep_end'),
        throwsA(isA<ApiFailure>()),
      );
      for (var i = 0; i < 3; i++) {
        await c.submit('review.save', {'date': '2026-10-19', 'text': '回顾 $i'});
      }
      expect(c.reviews.map((r) => r['version']), [1, 2, 3]);
    },
  );
}
