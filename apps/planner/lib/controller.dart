import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

typedef Json = Map<String, dynamic>;

abstract class LocalStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<String?> readToken();
  Future<void> writeToken(String token);
}

class MemoryStore implements LocalStore {
  final values = <String, String>{};
  String? token;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> readToken() async => token;
  @override
  Future<void> writeToken(String value) async {
    token = value;
  }
}

class DeviceStore implements LocalStore {
  final _secure = const FlutterSecureStorage();
  String? _webToken;
  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String key, String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, value)) {
      throw StateError('本地记录保存失败，请检查设备空间');
    }
  }

  // Browser testing keeps the credential in memory. Native devices use OS secure storage.
  @override
  Future<String?> readToken() async =>
      kIsWeb ? _webToken : _secure.read(key: 'planner_token');
  @override
  Future<void> writeToken(String token) async {
    if (kIsWeb) {
      _webToken = token;
    } else {
      await _secure.write(key: 'planner_token', value: token);
    }
  }
}

class ApiFailure implements Exception {
  ApiFailure(this.message, this.status);
  final String message;
  final int status;
  @override
  String toString() => message;
}

Json blankState() => {
  'revision': 0,
  'tasks': <Json>[],
  'blocks': <Json>[],
  'sessions': <Json>[],
  'feedbacks': <Json>[],
  'waiting_checks': <Json>[],
  'reviews': <Json>[],
  'projects': [
    {'id': 'code', 'name': '毕业 · 实验代码', 'color': '#2c7050'},
    {'id': 'learn', 'name': '秋招 · 转行自学', 'color': '#a95e32'},
    {'id': 'fab', 'name': 'Fab · 工艺实验', 'color': '#536b88'},
    {'id': 'personal', 'name': '个人安排', 'color': '#71658a'},
  ],
  'settings': {
    'timezone': 'America/Los_Angeles',
    'day_start': '09:00',
    'day_end': '22:00',
    'daily_review_time': '21:30',
  },
};

class PlannerController extends ChangeNotifier {
  PlannerController({required this.storage, http.Client? transport})
    : transport = transport ?? http.Client();
  final LocalStore storage;
  final http.Client transport;
  Json state = blankState();
  List<Json> pending = [];
  List<Json> preservedConflicts = [];
  String serverUrl = 'http://127.0.0.1:8787';
  String _token = '';
  String? conflict;
  String? connectionError;
  DateTime? lastSync;
  bool syncing = false;
  bool connected = false;
  bool _disposed = false;
  Timer? _poll;
  Future<void>? _syncFuture;
  Future<void> _saveTail = Future.value();

  List<Json> get tasks => (state['tasks'] as List).cast<Json>();
  List<Json> get blocks => (state['blocks'] as List).cast<Json>();
  List<Json> get sessions => (state['sessions'] as List).cast<Json>();
  List<Json> get feedbacks => (state['feedbacks'] as List).cast<Json>();
  List<Json> get reviews => (state['reviews'] as List).cast<Json>();
  List<Json> get projects =>
      (state['projects'] as List? ?? blankState()['projects']).cast<Json>();
  Json get settings => state['settings'] as Json;
  bool get configured => _token.isNotEmpty;
  Json? get activeSession => sessions
      .where((s) => ['running', 'paused'].contains(s['state']))
      .firstOrNull;

  Future<void> initialize() async {
    final cached = await storage.read('planner_state');
    if (cached != null) {
      final value = jsonDecode(cached) as Json;
      state = {...blankState(), ...value['state'] as Json};
      pending = (value['pending'] as List? ?? []).cast<Json>();
      preservedConflicts = (value['preserved_conflicts'] as List? ?? [])
          .cast<Json>();
      serverUrl = value['server_url'] as String? ?? serverUrl;
      lastSync = DateTime.tryParse(value['last_sync'] as String? ?? '');
    }
    _token = await storage.readToken() ?? '';
    _notify();
  }

  void startPolling() {
    _poll ??= Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(sync()),
    );
  }

  Future<void> connect(String url, String token) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ApiFailure('请输入有效的服务地址', 422);
    }
    serverUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    _token = token.trim();
    await storage.writeToken(_token);
    await _save();
    await sync();
  }

  Future<void> pair(String url, String code, String name) async {
    final previous = serverUrl;
    serverUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final value = await request('POST', '/api/v1/pairing/confirm', {
        'code': code.trim().toUpperCase(),
        'name': name,
      }, false);
      await connect(serverUrl, value['token'] as String);
    } catch (_) {
      serverUrl = previous;
      rethrow;
    }
  }

  Future<Json> request(
    String method,
    String path, [
    Json? body,
    bool authenticated = true,
  ]) async {
    final uri = Uri.parse('$serverUrl$path');
    final headers = {
      'Content-Type': 'application/json',
      if (authenticated) 'Authorization': 'Bearer $_token',
    };
    final response =
        await (method == 'GET'
                ? transport.get(uri, headers: headers)
                : transport.post(uri, headers: headers, body: jsonEncode(body)))
            .timeout(const Duration(seconds: 10));
    Json value;
    try {
      value = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
    } catch (_) {
      throw ApiFailure('电脑服务返回了无效响应', response.statusCode);
    }
    if (response.statusCode >= 400) {
      throw ApiFailure(
        value['message'] as String? ?? '操作未完成，请检查输入或连接',
        response.statusCode,
      );
    }
    return value;
  }

  Future<void> submit(String kind, Json payload) async {
    final operation = <String, dynamic>{
      'operation_id': const Uuid().v4(),
      'kind': kind,
      'payload': payload,
    };
    final candidate = jsonDecode(jsonEncode(state)) as Json;
    _optimistic(candidate, operation);
    final previousState = state;
    state = candidate;
    pending.add(operation);
    try {
      await _save();
    } catch (_) {
      state = previousState;
      pending.remove(operation);
      rethrow;
    }
    _notify();
    // Persist first; networking is asynchronous and never required for a local execution record.
    if (configured) unawaited(sync());
  }

  Future<void> sync() => _syncFuture ??= _synchronize().whenComplete(() {
    _syncFuture = null;
  });

  Future<void> _synchronize() async {
    if (!configured || _disposed) return;
    syncing = true;
    conflict = null;
    _notify();
    try {
      while (pending.isNotEmpty) {
        final operation = pending.first;
        await request('POST', '/api/v1/operations', operation);
        pending.removeAt(0);
        await _save();
      }
      final snapshot = await request('GET', '/api/v1/snapshot');
      // A local action may have arrived while GET was in flight; preserve its optimistic view.
      for (final operation in pending) {
        _optimistic(snapshot, operation);
      }
      state = {...blankState(), ...snapshot};
      connected = true;
      connectionError = null;
      lastSync = DateTime.now();
      await _save();
    } on ApiFailure catch (error) {
      connected = false;
      connectionError = error.message;
      if ([409, 422, 404].contains(error.status) && pending.isNotEmpty) {
        conflict = error.message;
      }
    } catch (_) {
      connected = false;
      connectionError = '暂时连接不到电脑，本地记录会保留并稍后同步。';
    } finally {
      syncing = false;
      _notify();
    }
  }

  Future<void> preserveConflictAndRefresh() async {
    if (syncing) throw ApiFailure('正在同步，请稍后操作', 409);
    final remote = await request('GET', '/api/v1/snapshot');
    preservedConflicts.add({
      'saved_at': DateTime.now().toUtc().toIso8601String(),
      'operations': jsonDecode(jsonEncode(pending)),
      'local_state': state,
    });
    pending = [];
    state = {...blankState(), ...remote};
    conflict = null;
    connected = true;
    await _save();
    _notify();
  }

  Future<Json> onlineRequest(String path, [Json? body]) async {
    await sync();
    if (!connected || pending.isNotEmpty) {
      throw ApiFailure(conflict ?? '这项调整需要先与电脑同步。', 409);
    }
    return request(body == null ? 'GET' : 'POST', path, body);
  }

  Future<void> applyProposal(String id, {bool undo = false}) async {
    await sync();
    if (!connected || pending.isNotEmpty) {
      throw ApiFailure('请先完成同步，再应用调整。', 409);
    }
    await submit(undo ? 'plan.undo' : 'plan.apply', {'proposal_id': id});
    await sync();
    if (pending.isNotEmpty) {
      throw ApiFailure(conflict ?? '调整已保留，等待连接恢复后确认。', 409);
    }
  }

  Future<void> _save() {
    final serialized = jsonEncode({
      'state': state,
      'pending': pending,
      'preserved_conflicts': preservedConflicts,
      'server_url': serverUrl,
      'last_sync': lastSync?.toIso8601String(),
    });
    final result = _saveTail
        .catchError((Object _) {})
        .then((_) => storage.write('planner_state', serialized));
    _saveTail = result;
    return result;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    transport.close();
    super.dispose();
  }
}

void _optimistic(Json state, Json operation) {
  final p = operation['payload'] as Json;
  final kind = operation['kind'];
  final tasks = (state['tasks'] as List).cast<Json>();
  final blocks = (state['blocks'] as List).cast<Json>();
  final sessions = (state['sessions'] as List).cast<Json>();
  Json find(List<Json> values, dynamic id) => values.firstWhere(
    (v) => v['id'] == id,
    orElse: () => throw ApiFailure('记录不存在，请同步后重试', 404),
  );
  if (kind == 'task.create') {
    if (tasks.any((t) => t['id'] == p['id'])) return;
    tasks.add({
      'state': 'ready',
      'version': 1,
      'project_id': 'personal',
      'min_chunk_minutes': 15,
      'splittable': true,
      'priority': 2,
      'deadline': null,
      'dependency_ids': <String>[],
      ...p,
    });
  } else if (kind == 'task.update') {
    final task = find(tasks, p['id']);
    task.addAll({...p, 'version': (task['version'] as int) + 1});
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
  } else if (kind == 'session.start') {
    if (sessions.any((s) => ['running', 'paused'].contains(s['state']))) {
      throw ApiFailure('请先结束当前投入。', 409);
    }
    final block = find(blocks, p['block_id']);
    final task = find(tasks, block['task_id']);
    if (['done', 'cancelled'].contains(task['state'])) {
      throw ApiFailure('任务已经结束。', 409);
    }
    final at = DateTime.parse(p['occurred_at']);
    sessions.add({
      'id': p['id'],
      'block_id': block['id'],
      'task_id': task['id'],
      'state': 'running',
      'actual_start_at': p['occurred_at'],
      'actual_end_at': null,
      'last_event_at': p['occurred_at'],
      'expected_end_at': at
          .add(
            DateTime.parse(block['end_at'])
                .difference(DateTime.parse(block['start_at'])),
          )
          .toUtc()
          .toIso8601String(),
      'version': 1,
      'intervals': [
        {'start_at': p['occurred_at'], 'end_at': null},
      ],
    });
    task['state'] = 'in_progress';
    task['version']++;
  } else if (kind.toString().startsWith('session.')) {
    final session = find(sessions, p['id']);
    final intervals = session['intervals'] as List;
    final at = p['occurred_at'];
    if (kind == 'session.resume') {
      if (session['state'] != 'paused') throw ApiFailure('当前状态不能继续。', 409);
      session['expected_end_at'] = DateTime.parse(session['expected_end_at'])
          .add(
            DateTime.parse(at).difference(DateTime.parse(session['paused_at'])),
          )
          .toUtc()
          .toIso8601String();
      intervals.add({'start_at': at, 'end_at': null});
      session['state'] = 'running';
    } else {
      if (!['running', 'paused'].contains(session['state'])) {
        throw ApiFailure('当前状态不能暂停或结束。', 409);
      }
      if (intervals.isNotEmpty && intervals.last['end_at'] == null) {
        intervals.last['end_at'] = at;
      }
      session['state'] = kind == 'session.pause'
          ? 'paused'
          : 'awaiting_feedback';
      if (kind == 'session.pause') {
        session['paused_at'] = at;
      } else {
        session['actual_end_at'] = at;
      }
    }
    session['last_event_at'] = at;
    session['version']++;
  } else if (kind == 'feedback.create') {
    final session = p['session_id'] == null
        ? null
        : find(sessions, p['session_id']);
    final block = find(blocks, session?['block_id'] ?? p['block_id']);
    final task = find(tasks, block['task_id']);
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
    if (p['choice'] == 'partial') {
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
        'check_at': p['check_at'],
        'resolved_at': null,
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
    (state['reviews'] as List).add({
      'id': operation['operation_id'],
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'archive_status': 'pending',
      ...p,
    });
  } else if (kind == 'settings.update') {
    (state['settings'] as Json).addAll(p);
  } else if (kind == 'plan.apply' || kind == 'plan.undo') {
    // The proposal is stored before sending; the canonical snapshot supplies the result.
    return;
  } else {
    throw ApiFailure('这项操作需要连接电脑后执行。', 409);
  }
}
