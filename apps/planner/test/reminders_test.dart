import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:time_planner/controller.dart';
import 'package:time_planner/reminders.dart';

void main() {
  setUpAll(data.initializeTimeZones);
  Json snapshot() => {
    ...blankState(),
    'blocks': <Json>[
      {
        'id': 'b',
        'task_id': 't',
        'title': '代码',
        'status': 'scheduled',
        'version': 1,
        'kind': 'flexible',
        'start_at': '2026-10-19T16:00:00Z',
        'end_at': '2026-10-19T17:00:00Z',
      },
    ],
  };
  final now = DateTime.utc(2026, 10, 19, 15);
  test(
    'phone test registers an OS notification fifteen seconds in the future',
    () async {
      final c = PlannerController(storage: MemoryStore());
      await c.initialize();
      final driver = FakeDriver();
      final service = ReminderService(
        controller: c,
        driver: driver,
        clock: () => now,
      );
      await service.initialize();
      await service.test();
      final testReminder = driver.pending.values.singleWhere(
        (r) => r.key == 'test',
      );
      expect(testReminder.at, now.add(const Duration(seconds: 15)));
      expect(service.status, contains('15 秒'));
      service.dispose();
      c.dispose();
    },
  );
  test('extension and waiting snooze replace the OS reminder instead of leaving the old alert', () async {
    var current = now;
    final c = PlannerController(storage: MemoryStore(), clock: () => current);
    await c.initialize();
    c.state = snapshot();
    c.state['tasks'] = <Json>[
      {
        'id': 't',
        'title': '代码',
        'state': 'ready',
        'version': 1,
        'remaining_minutes': 60,
        'outcome_criteria': '保存输出',
        'dependency_ids': <String>[],
      },
    ];
    await c.startBlock(c.blocks.single);
    final driver = FakeDriver();
    final service = ReminderService(
      controller: c,
      driver: driver,
      clock: () => current,
    );
    await service.initialize();
    await service.enable();
    final end = buildReminders(
      c.state,
      current,
    ).firstWhere((r) => r.key.startsWith('session:') && r.key.endsWith(':end'));
    current = current.add(const Duration(minutes: 65));
    driver.pending.remove(end.id);
    driver.active.add(end.id);
    await c.extendSession(c.sessions.single, 15);
    await service.refresh();
    expect(
      driver.pending[end.id]!.at,
      current.add(const Duration(minutes: 15)),
    );
    expect(driver.active, isNot(contains(end.id)));
    await c.controlSession(c.sessions.single, 'end');
    await c.submit('feedback.create', {
      'session_id': c.sessions.single['id'],
      'choice': 'waiting',
      'check_at': current.add(const Duration(hours: 2)).toIso8601String(),
    });
    await service.refresh();
    final check = (c.state['waiting_checks'] as List).single as Json;
    final waiting = buildReminders(
      c.state,
      current,
    ).firstWhere((r) => r.key.startsWith('waiting:'));
    await c.snoozeWaiting(check, current.add(const Duration(hours: 4)));
    await service.refresh();
    expect(
      driver.pending[waiting.id]!.at,
      current.add(const Duration(hours: 4)),
    );
    expect(driver.cancelled, contains(waiting.id));
    service.dispose();
    c.dispose();
  });
  test('rescheduling replaces old OS alarms and preserves delivered prompts until feedback', () async {
    final c = PlannerController(storage: MemoryStore());
    await c.initialize();
    c.state = snapshot();
    var current = now;
    final driver = FakeDriver();
    final service = ReminderService(
      controller: c,
      driver: driver,
      clock: () => current,
    );
    await service.initialize();
    await service.enable();
    final start = buildReminders(
      c.state,
      current,
    ).firstWhere((r) => r.key == 'block:b:start');
    (c.state['blocks'] as List).first['start_at'] = '2026-10-19T16:30:00Z';
    await service.refresh();
    expect(driver.pending[start.id]!.at, DateTime.utc(2026, 10, 19, 16, 30));
    expect(driver.cancelled, contains(start.id));
    final end = buildReminders(
      c.state,
      current,
    ).firstWhere((r) => r.key == 'block:b:end');
    current = DateTime.utc(2026, 10, 19, 17, 1);
    driver.pending.remove(end.id);
    driver.active.add(end.id);
    driver.cancelled.clear();
    await service.refresh();
    expect(driver.cancelled, isNot(contains(end.id)));
    (c.state['blocks'] as List).first['status'] = 'completed';
    await service.refresh();
    expect(driver.cancelled, contains(end.id));
    service.dispose();
    c.dispose();
  });
  test('plan contains start, end and one follow-up; paused execution cancels its old end', () {
    final state = snapshot();
    final first = buildReminders(state, now);
    expect(first.where((r) => r.key.startsWith('block:b:')).length, 3);
    state['sessions'] = <Json>[
      {
        'id': 's',
        'block_id': 'b',
        'state': 'paused',
        'expected_end_at': '2026-10-19T18:00:00Z',
      },
    ];
    final paused = buildReminders(state, now);
    expect(
      paused.where(
        (r) => r.key.startsWith('block:b:') || r.key.startsWith('session:s:'),
      ),
      isEmpty,
    );
  });
  test('rescheduled reminder keeps identity but changes its delivery time', () {
    final state = snapshot();
    final old = buildReminders(
      state,
      now,
    ).firstWhere((r) => r.key == 'block:b:start');
    (state['blocks'] as List).first['start_at'] = '2026-10-19T16:30:00Z';
    final changed = buildReminders(
      state,
      now,
    ).firstWhere((r) => r.key == 'block:b:start');
    expect(old.id, changed.id);
    expect(old.signature, isNot(changed.signature));
    (state['blocks'] as List).first['status'] = 'cancelled';
    expect(
      buildReminders(state, now).where((r) => r.key.startsWith('block:b:')),
      isEmpty,
    );
  });
  test('waiting checks and unresolved feedback are retained without claiming completion', () {
    final state = snapshot();
    state['waiting_checks'] = <Json>[
      {
        'id': 'w',
        'task_id': 't',
        'check_at': '2026-10-19T18:00:00Z',
        'resolved_at': null,
      },
    ];
    state['sessions'] = <Json>[
      {
        'id': 's',
        'block_id': 'b',
        'state': 'awaiting_feedback',
        'actual_end_at': '2026-10-19T14:59:00Z',
        'expected_end_at': '2026-10-19T14:59:00Z',
      },
    ];
    final reminders = buildReminders(state, now);
    expect(reminders.any((r) => r.key == 'waiting:w'), isTrue);
    expect(reminders.any((r) => r.key == 'session:s:followup'), isTrue);
    expect((state['blocks'] as List).first['status'], 'scheduled');
  });
}

class FakeDriver implements ReminderDriver {
  final pending = <int, ReminderItem>{};
  final active = <int>{};
  final cancelled = <int>[];
  @override
  bool get supported => true;
  @override
  bool get schedulesInSystem => true;
  @override
  bool get precise => true;
  @override
  Future<void> initialize(void Function(String?) onOpen) async {}
  @override
  Future<bool> allowed() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> requestExactPermission() async {}
  @override
  Future<Set<int>> knownIds() async => {...pending.keys, ...active};
  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    pending.remove(id);
    active.remove(id);
  }

  @override
  Future<void> schedule(ReminderItem item) async {
    pending[item.id] = item;
  }

  @override
  Future<void> show(ReminderItem item) async {
    active.add(item.id);
  }
}
