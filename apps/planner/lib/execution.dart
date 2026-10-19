part of 'controller.dart';

Json _executionRecord(Json state, String collection, dynamic id) =>
    (state[collection] as List).cast<Json>().firstWhere(
      (v) => v['id'] == id,
      orElse: () => throw ApiFailure('记录不存在，请同步后重试', 404),
    );

DateTime _eventTime(Json p, DateTime now, [String? minimum]) {
  final at = p['occurred_at'] == null ? now : DateTime.parse(p['occurred_at']);
  if (!at.isUtc ||
      at.isAfter(now.add(const Duration(minutes: 5))) ||
      minimum != null && at.isBefore(DateTime.parse(minimum))) {
    throw ApiFailure('执行时间不正确或早于前一次操作。', 422);
  }
  return at;
}

void _startSession(Json state, Json p, DateTime now) {
  final sessions = (state['sessions'] as List).cast<Json>();
  if (sessions.any((s) => ['running', 'paused'].contains(s['state']))) {
    throw ApiFailure('请先结束当前投入。', 409);
  }
  final block = _executionRecord(state, 'blocks', p['block_id']);
  final task = _executionRecord(state, 'tasks', block['task_id']);
  if (block['status'] != 'scheduled' ||
      ['done', 'cancelled', 'waiting'].contains(task['state'])) {
    throw ApiFailure('这段安排已结束，或仍在等待结果。', 409);
  }
  if (sessions.any((s) => s['block_id'] == block['id'])) {
    throw ApiFailure('这段已有执行记录。', 409);
  }
  for (final id in task['dependency_ids'] as List? ?? []) {
    if (_executionRecord(state, 'tasks', id)['state'] != 'done') {
      throw ApiFailure('前置任务尚未完成。', 409);
    }
  }
  final at = _eventTime(p, now), mode = p['mode'] ?? 'keep_duration';
  if (!['keep_duration', 'keep_end'].contains(mode)) {
    throw ApiFailure('未知开始模式。', 422);
  }
  final expected = mode == 'keep_end'
      ? DateTime.parse(block['end_at'])
      : at.add(
          DateTime.parse(block['end_at'])
              .difference(DateTime.parse(block['start_at'])),
        );
  if (!expected.isAfter(at)) throw ApiFailure('原定结束时间已过，请保留原时长。', 409);
  sessions.add({
    'id': p['id'],
    'block_id': block['id'],
    'task_id': task['id'],
    'state': 'running',
    'actual_start_at': at.toIso8601String(),
    'actual_end_at': null,
    'last_event_at': at.toIso8601String(),
    'start_mode': mode,
    'expected_end_at': expected.toUtc().toIso8601String(),
    'planned_seconds': expected.difference(at).inSeconds,
    'version': 1,
    'intervals': [
      {'start_at': at.toIso8601String(), 'end_at': null},
    ],
  });
  task['state'] = 'in_progress';
  task['version']++;
}

void _controlSession(Json state, String kind, Json p, DateTime now) {
  final session = _executionRecord(state, 'sessions', p['id']);
  final intervals = session['intervals'] as List;
  final at = _eventTime(p, now, session['last_event_at']);
  if (session['ended_by'] == 'timer' &&
      (kind == 'session.end' ||
          p['occurred_at'] != null &&
              !at.isAfter(DateTime.parse(session['actual_end_at'])))) {
    session.addAll({'state': 'running', 'actual_end_at': null});
    intervals.last['end_at'] = null;
    session.remove('ended_by');
  }
  if (kind == 'session.resume') {
    if (session['state'] != 'paused') throw ApiFailure('当前状态不能继续。', 409);
    session['expected_end_at'] = DateTime.parse(session['expected_end_at'])
        .add(at.difference(DateTime.parse(session['paused_at'])))
        .toUtc()
        .toIso8601String();
    intervals.add({'start_at': at.toIso8601String(), 'end_at': null});
    session['state'] = 'running';
  } else {
    if (!['session.pause', 'session.end'].contains(kind) ||
        !['running', 'paused'].contains(session['state'])) {
      throw ApiFailure('当前状态不能暂停或结束。', 409);
    }
    if (intervals.isNotEmpty && intervals.last['end_at'] == null) {
      intervals.last['end_at'] = at.toIso8601String();
    }
    session['state'] = kind == 'session.pause' ? 'paused' : 'awaiting_feedback';
    if (kind == 'session.pause') {
      session['paused_at'] = at.toIso8601String();
    } else {
      session['actual_end_at'] = at.toIso8601String();
      session['ended_by'] = 'user';
    }
  }
  session['last_event_at'] = at.toIso8601String();
  session['version']++;
}

void _extendSession(Json state, Json p, DateTime now) {
  if (p['minutes'] is! int || p['minutes'] < 5 || p['minutes'] > 120) {
    throw ApiFailure('续时请选择 5 至 120 分钟。', 422);
  }
  final session = _executionRecord(state, 'sessions', p['id']);
  final task = _executionRecord(state, 'tasks', session['task_id']);
  if (['done', 'cancelled', 'waiting'].contains(task['state'])) {
    throw ApiFailure('请先确认任务可继续投入。', 409);
  }
  final at = _eventTime(p, now, session['last_event_at']);
  var end = DateTime.parse(session['expected_end_at']);
  final intervals = session['intervals'] as List;
  if (session['state'] == 'running' && !at.isBefore(end)) {
    if (intervals.last['end_at'] == null) {
      intervals.last['end_at'] = end.toIso8601String();
    }
    session.addAll({
      'state': 'awaiting_feedback',
      'ended_by': 'timer',
      'actual_end_at': end.toIso8601String(),
    });
  }
  if (session['state'] == 'awaiting_feedback') {
    if (session['ended_by'] != 'timer' ||
        at.isAfter(end.add(const Duration(minutes: 30)))) {
      throw ApiFailure('这段已结束，请反馈后安排下一段。', 409);
    }
    if ((state['sessions'] as List).any(
      (s) =>
          s['id'] != session['id'] &&
          ['running', 'paused'].contains(s['state']),
    )) {
      throw ApiFailure('请先结束另一段投入。', 409);
    }
    if (!at.isAfter(end)) {
      intervals.last['end_at'] = null;
    } else {
      intervals.add({'start_at': at.toIso8601String(), 'end_at': null});
      end = at;
    }
    session.addAll({'state': 'running', 'actual_end_at': null});
    session.remove('ended_by');
  } else if (!['running', 'paused'].contains(session['state'])) {
    throw ApiFailure('已提交结果的执行段不能续时。', 409);
  }
  final block = _executionRecord(state, 'blocks', session['block_id']);
  final base = DateTime.parse(block['end_at'])
      .difference(DateTime.parse(block['start_at']))
      .inSeconds;
  session['planned_seconds'] =
      (session['planned_seconds'] ?? base) + p['minutes'] * 60;
  session['extension_minutes'] =
      (session['extension_minutes'] ?? 0) + p['minutes'];
  session['expected_end_at'] = end
      .add(Duration(minutes: p['minutes']))
      .toUtc()
      .toIso8601String();
  session['last_event_at'] = at.toIso8601String();
  session['version']++;
  if (task['state'] != 'in_progress') {
    task['state'] = 'in_progress';
    task['version']++;
  }
}
