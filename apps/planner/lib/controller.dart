import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

part 'operations.dart';
part 'execution.dart';
part 'storage.dart';

typedef Json = Map<String, dynamic>;

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
  'projects': <Json>[],
  'sleeps': <Json>[],
  'settings': {
    'timezone': 'America/Los_Angeles',
    'day_start': '09:00',
    'day_end': '22:00',
    'daily_review_time': '21:30',
    'auto_adjust': true,
  },
};

class PlannerController extends ChangeNotifier {
  PlannerController({
    required this.storage,
    http.Client? transport,
    DateTime Function()? clock,
  }) : transport = transport ?? http.Client(),
       clock = clock ?? DateTime.now;
  final DateTime Function() clock;
  DateTime get nowUtc => clock().toUtc();
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
  List<Json> get projects => (state['projects'] as List? ?? []).cast<Json>();
  List<Json> get activeProjects =>
      projects.where((p) => p['archived'] != true).toList();
  List<Json> get sleeps => (state['sleeps'] as List? ?? []).cast<Json>();
  Json? get openSleep => sleeps.where((s) => s['woke_at'] == null).firstOrNull;
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
    Duration timeout = const Duration(seconds: 10),
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
            .timeout(timeout);
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

  Future<void> startBlock(Json block, {String mode = 'keep_duration'}) =>
      submit('session.start', {
        'id': const Uuid().v4(),
        'block_id': block['id'],
        'mode': mode,
        'defer_adjustment': !connected || pending.isNotEmpty,
        'occurred_at': nowUtc.toIso8601String(),
      });
  Future<void> controlSession(Json session, String action) {
    if (!['pause', 'resume', 'end'].contains(action)) {
      throw ApiFailure('未知执行操作', 422);
    }
    return submit('session.$action', {
      'defer_adjustment': !connected || pending.isNotEmpty,
      'id': session['id'],
      'occurred_at': nowUtc.toIso8601String(),
    });
  }

  Future<void> extendSession(Json session, int minutes) =>
      submit('session.extend', {
        'defer_adjustment': !connected || pending.isNotEmpty,
        'id': session['id'],
        'minutes': minutes,
        'occurred_at': nowUtc.toIso8601String(),
      });
  bool canExtendSession(Json session) {
    if (['running', 'paused'].contains(session['state'])) return true;
    return session['state'] == 'awaiting_feedback' &&
        session['ended_by'] == 'timer' &&
        !nowUtc.isAfter(
          DateTime.parse(session['expected_end_at'])
              .add(const Duration(minutes: 30)),
        ) &&
        (activeSession == null || activeSession!['id'] == session['id']);
  }

  Future<void> snoozeWaiting(Json check, DateTime when) =>
      submit('waiting.snooze', {
        'id': check['id'],
        'version': check['version'] ?? 1,
        'check_at': when.toUtc().toIso8601String(),
      });

  Future<void> submit(String kind, Json payload) async {
    final operation = <String, dynamic>{
      'operation_id': const Uuid().v4(),
      'kind': kind,
      'payload': payload,
    };
    final candidate = jsonDecode(jsonEncode(state)) as Json;
    _optimistic(candidate, operation, now: nowUtc);
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
        _optimistic(snapshot, operation, now: nowUtc);
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

  // ---- Assistant (lives on the computer; needs a connection) ----------

  Future<Json> _assistant(String method, String path, [Json? body]) async {
    if (!configured) {
      throw ApiFailure('助手在电脑上运行，请先在设置里连接电脑。', 409);
    }
    return request(
      method,
      '/api/v1/assistant$path',
      body,
      true,
      const Duration(seconds: 120),
    );
  }

  Future<Json> assistantConfig() => _assistant('GET', '/config');
  Future<Json> saveAssistantConfig(Json body) =>
      _assistant('POST', '/config', body);
  Future<Json> testAssistant() => _assistant('POST', '/test', {});
  Future<List<String>> assistantModels() async =>
      ((await _assistant('GET', '/models'))['models'] as List).cast<String>();
  Future<List<Json>> assistantMessages() async =>
      ((await _assistant('GET', '/messages'))['messages'] as List).cast<Json>();
  Future<List<Json>> sendAssistant(String text) async =>
      ((await _assistant('POST', '/messages', {'text': text}))['messages']
              as List)
          .cast<Json>();
  Future<void> dismissDraft(String id) =>
      _assistant('POST', '/drafts/$id/dismiss', {});

  /// Confirmed drafts change the schedule on the computer; pull it back here.
  Future<void> applyDraft(String id) async {
    await sync();
    if (pending.isNotEmpty) {
      throw ApiFailure('还有本地记录没同步，同步完成后再确认拟办。', 409);
    }
    await _assistant('POST', '/drafts/$id/apply', {});
    await sync();
  }

  // ---- WeChat official-account channel (configured on the computer) ----

  Future<Json> _wechat(String method, String path, [Json? body]) async {
    if (!configured) {
      throw ApiFailure('微信助手在电脑上运行，请先在设置里连接电脑。', 409);
    }
    return request(method, '/api/v1/wechat$path', body);
  }

  Future<Json> wechatConfig() => _wechat('GET', '/config');
  Future<Json> saveWechatConfig(Json body) => _wechat('POST', '/config', body);
  Future<Json> wechatBindCode() => _wechat('POST', '/bind-code', {});
  Future<Json> wechatUnbind() => _wechat('POST', '/unbind', {});
  Future<Json> wechatTest() => _wechat('POST', '/test', {});
  Future<List<Json>> wechatOutbox() async =>
      ((await _wechat('GET', '/outbox'))['messages'] as List).cast<Json>();

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
