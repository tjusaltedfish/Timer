part of 'controller.dart';

void _optimistic(Json state, Json operation, {required DateTime now}) {
  final p = operation['payload'] as Json;
  final kind = operation['kind'];
  final tasks = (state['tasks'] as List).cast<Json>();
  final blocks = (state['blocks'] as List).cast<Json>();
  final sessions = (state['sessions'] as List).cast<Json>();
  Json find(List<Json> values, dynamic id) => values.firstWhere(
    (v) => v['id'] == id,
    orElse: () => throw ApiFailure('记录不存在，请同步后重试', 404),
  );
  if (kind == 'material.delete') {
    (state['materials'] as List? ?? []).removeWhere((m) => m['id'] == p['id']);
  } else if (kind == 'memory.save') {
    final memories = state.putIfAbsent('memories', () => <Json>[]) as List;
    if (memories.length >= 50 || (p['text'] as String).trim().isEmpty) {
      throw ApiFailure('请填写记忆，最多保留 50 条。', 422);
    }
    memories.add({...p, 'source': 'user', 'created_at': now.toIso8601String()});
  } else if (kind == 'memory.delete') {
    (state['memories'] as List).removeWhere((m) => m['id'] == p['id']);
  } else if (kind == 'task.create') {
    if (tasks.any((t) => t['id'] == p['id'])) return;
    tasks.add({
      'state': 'ready',
      'version': 1,
      'project_id': null,
      'min_chunk_minutes': 15,
      'splittable': true,
      'priority': 2,
      'deadline': null,
      'dependency_ids': <String>[],
      ...p,
    });
  } else if (kind == 'task.update') {
    final task = find(tasks, p['id']);
    if (p['state'] != null &&
        sessions.any(
          (s) =>
              s['task_id'] == task['id'] &&
              ['running', 'paused'].contains(s['state']),
        )) {
      throw ApiFailure('请先结束当前投入。', 409);
    }
    task.addAll({...p, 'version': (task['version'] as int) + 1});
    if (p['title'] != null) {
      for (final planned in blocks.where(
        (b) => b['task_id'] == task['id'] && b['status'] == 'scheduled',
      )) {
        planned['title'] = p['title'];
        planned['version']++;
      }
    }
    if (task['state'] == 'cancelled') {
      for (final block in blocks.where(
        (b) => b['task_id'] == task['id'] && b['status'] == 'scheduled',
      )) {
        block['status'] = 'cancelled';
        block['version']++;
      }
      for (final session in sessions.where(
        (s) => s['task_id'] == task['id'] && s['state'] == 'awaiting_feedback',
      )) {
        session['state'] = 'closed';
        session['cancelled_by_task'] = true;
        session['version']++;
      }
      for (final check in (state['waiting_checks'] as List).cast<Json>().where(
        (v) => v['task_id'] == task['id'] && v['resolved_at'] == null,
      )) {
        check['resolved_at'] = now.toUtc().toIso8601String();
        check['resolution'] = 'cancelled';
        check['version'] = (check['version'] as int? ?? 1) + 1;
      }
    }
  } else if (kind == 'block.create') {
    if (blocks.any((b) => b['id'] == p['id'])) return;
    final start = DateTime.parse(p['start_at'] as String),
        end = DateTime.parse(p['end_at'] as String);
    if (!end.isAfter(start)) throw ApiFailure('结束时间应晚于开始时间', 422);
    if (blocks.any(
      (b) =>
          b['status'] == 'scheduled' &&
          start.isBefore(DateTime.parse(b['end_at'])) &&
          end.isAfter(DateTime.parse(b['start_at'])),
    )) {
      throw ApiFailure('与已有安排冲突，请选择其他时间。', 409);
    }
    blocks.add({
      'status': 'scheduled',
      'version': 1,
      'kind': 'flexible',
      'title': p['task_id'] == null
          ? p['title']
          : find(tasks, p['task_id'])['title'],
      ...p,
    });
  } else if (kind == 'block.move') {
    final block = find(blocks, p['id']);
    if (block['status'] != 'scheduled' ||
        sessions.any((s) => s['block_id'] == block['id'])) {
      throw ApiFailure('已有执行记录，不能改写过去的安排', 409);
    }
    if (p['version'] != null && p['version'] != block['version']) {
      throw ApiFailure('安排已经变化，请同步后重试', 409);
    }
    if (['fixed', 'protected'].contains(block['kind']) &&
        p['allow_fixed'] != true) {
      throw ApiFailure('固定时段的调整需要单独确认。', 409);
    }
    final start = DateTime.parse(p['start_at'] as String),
        end = DateTime.parse(p['end_at'] as String);
    if (!end.isAfter(start)) throw ApiFailure('结束时间应晚于开始时间', 422);
    if (end.difference(start) > const Duration(hours: 24)) {
      throw ApiFailure('单段安排不能超过 24 小时', 422);
    }
    if (blocks.any(
      (b) =>
          b['id'] != block['id'] &&
          b['status'] == 'scheduled' &&
          start.isBefore(DateTime.parse(b['end_at'])) &&
          end.isAfter(DateTime.parse(b['start_at'])),
    )) {
      throw ApiFailure('与已有安排冲突，请选择其他时间。', 409);
    }
    block.addAll({
      'start_at': p['start_at'],
      'end_at': p['end_at'],
      'version': (block['version'] as int) + 1,
    });
  } else if (kind == 'block.cancel') {
    final block = find(blocks, p['id']);
    if (block['status'] != 'scheduled' ||
        sessions.any((s) => s['block_id'] == block['id'])) {
      throw ApiFailure('这一段已经开始或有记录，不能撤下。', 409);
    }
    block['status'] = 'cancelled';
    block['version']++;
  } else if (kind == 'session.start') {
    _startSession(state, p, now);
  } else if (kind == 'session.extend') {
    _extendSession(state, p, now);
  } else if (kind.toString().startsWith('session.')) {
    _controlSession(state, kind, p, now);
  } else if (kind == 'feedback.create') {
    final session = p['session_id'] == null
        ? null
        : find(sessions, p['session_id']);
    final block = find(blocks, session?['block_id'] ?? p['block_id']);
    final task = find(tasks, block['task_id']);
    if (['partial', 'interrupted'].contains(p['choice']) &&
        (p['remaining_minutes'] is! int || p['remaining_minutes'] < 1)) {
      throw ApiFailure('请填写剩余工作量。', 422);
    }
    if (p['choice'] == 'waiting' &&
        (p['check_at'] == null ||
            !DateTime.parse(p['check_at']).isAfter(now))) {
      throw ApiFailure('请选择未来的检查时间。', 422);
    }
    if (session != null && session['state'] != 'awaiting_feedback') {
      throw ApiFailure('请先结束本次投入。', 409);
    }
    if (session != null) {
      session['state'] = 'closed';
      session['version']++;
    }
    block['status'] = p['choice'] == 'not_started' ? 'skipped' : 'completed';
    block['version']++;
    task['state'] = p['choice'] == 'done'
        ? 'done'
        : p['choice'] == 'waiting'
        ? 'waiting'
        : 'ready';
    task['version']++;
    if (['partial', 'interrupted'].contains(p['choice'])) {
      task['remaining_minutes'] = p['remaining_minutes'];
    }
    if (p['choice'] == 'done') {
      task['remaining_minutes'] = 0;
      for (final future in blocks.where(
        (b) => b['task_id'] == task['id'] && b['status'] == 'scheduled',
      )) {
        future['status'] = 'cancelled';
        future['version']++;
      }
    }
    if (p['choice'] == 'waiting') {
      (state['waiting_checks'] as List).add({
        'id': operation['operation_id'],
        'task_id': task['id'],
        'source_block_id': block['id'],
        'check_at': p['check_at'],
        'resolved_at': null,
        'version': 1,
      });
    }
    (state['feedbacks'] as List).add({
      'id': operation['operation_id'],
      'task_id': task['id'],
      'block_id': block['id'],
      'created_at': DateTime.now().toUtc().toIso8601String(),
      ...p,
    });
  } else if (kind == 'review.save') {
    final previous = (state['reviews'] as List)
        .where((r) => r['date'] == p['date'])
        .fold<int>(
          0,
          (v, r) =>
              r['version'] is int && r['version'] > v ? r['version'] as int : v,
        );
    (state['reviews'] as List).add({
      'version': previous + 1,
      'id': operation['operation_id'],
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'archive_status': 'pending',
      ...p,
    });
  } else if (kind == 'waiting.snooze') {
    final check = find((state['waiting_checks'] as List).cast<Json>(), p['id']);
    final task = find(tasks, check['task_id']);
    if (check['resolved_at'] != null || task['state'] != 'waiting') {
      throw ApiFailure('检查点已处理。', 409);
    }
    final version = check['version'] as int? ?? 1;
    if (p['version'] != null && p['version'] != version) {
      throw ApiFailure('检查时间已变化，请同步后重试。', 409);
    }
    if (!DateTime.parse(p['check_at']).isAfter(now)) {
      throw ApiFailure('请选择未来的检查时间。', 422);
    }
    check.addAll({'check_at': p['check_at'], 'version': version + 1});
  } else if (kind == 'waiting.resolve') {
    final check = find((state['waiting_checks'] as List).cast<Json>(), p['id']);
    final task = find(tasks, check['task_id']);
    if (check['resolved_at'] != null) throw ApiFailure('检查点已处理。', 409);
    if (sessions.any(
      (s) =>
          s['task_id'] == task['id'] &&
          ['running', 'paused'].contains(s['state']),
    )) {
      throw ApiFailure('请先结束该任务的当前投入。', 409);
    }
    check['resolved_at'] = DateTime.now().toUtc().toIso8601String();
    task['state'] = p['resolution'];
    task['version']++;
    task['remaining_minutes'] = p['resolution'] == 'done'
        ? 0
        : p['remaining_minutes'];
    if (p['resolution'] == 'done') {
      for (final block in blocks.where(
        (b) => b['task_id'] == task['id'] && b['status'] == 'scheduled',
      )) {
        block['status'] = 'cancelled';
        block['version']++;
      }
    }
    (state['feedbacks'] as List).add({
      'id': operation['operation_id'],
      'task_id': task['id'],
      'block_id': check['source_block_id'],
      'choice': p['resolution'] == 'done' ? 'done' : 'partial',
      'source': 'waiting_result',
      'created_at': check['resolved_at'],
      'outcome_text': p['outcome_text'] ?? '',
    });
  } else if (kind == 'settings.update') {
    (state['settings'] as Json).addAll(p);
  } else if (kind == 'project.create') {
    final projects = state.putIfAbsent('projects', () => <dynamic>[]) as List;
    if (projects.any((x) => x['id'] == p['id'])) return;
    if (projects.any((x) => x['name'] == p['name'] && x['archived'] != true)) {
      throw ApiFailure('已经有同名的分类了', 409);
    }
    projects.add({'archived': false, ...p});
  } else if (kind == 'project.update') {
    final projects = (state['projects'] as List).cast<Json>();
    find(projects, p['id']).addAll({
      for (final e in p.entries)
        if (e.key != 'id' && e.value != null) e.key: e.value,
    });
  } else if (kind == 'sleep.log') {
    final sleeps = (state.putIfAbsent('sleeps', () => <dynamic>[]) as List)
        .cast<Json>();
    final existing = sleeps.where((s) => s['id'] == p['id']).firstOrNull;
    if (existing == null &&
        p['woke_at'] == null &&
        sleeps.any((s) => s['woke_at'] == null)) {
      throw ApiFailure('已经有一段正在记录的睡眠了', 409);
    }
    final entry = {'woke_at': null, 'quality': null, 'note': '', ...p};
    existing == null
        ? (state['sleeps'] as List).add(entry)
        : (existing
            ..clear()
            ..addAll(entry));
  } else if (kind == 'sleep.delete') {
    (state['sleeps'] as List? ?? []).removeWhere((s) => s['id'] == p['id']);
  } else if (kind == 'plan.apply' || kind == 'plan.undo') {
    // The proposal is stored before sending; the canonical snapshot supplies the result.
    return;
  } else {
    throw ApiFailure('这项操作需要连接电脑后执行。', 409);
  }
}
