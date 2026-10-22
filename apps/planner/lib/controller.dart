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
part 'auth/session.dart';

typedef Json = Map<String, dynamic>;

class ApiFailure implements Exception {
  ApiFailure(this.message, this.status, {this.code});
  final String message;
  final int status;

  /// Stable machine code from the v2 error envelope (`{"code","message"}`).
  final String? code;
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
  'memories': <Json>[],
  'materials': <Json>[],
  'analyses': <Json>[],
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
  String serverUrl = AuthSession.defaultBaseUrl;
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

  /// v2 account session (server address + token + cached user).
  late final AuthSession auth = AuthSession(
    storage: storage,
    transport: transport,
  );

  /// Whether the startup token check finished (see [bootstrapSession]).
  bool sessionChecked = false;
  bool checkingSession = false;

  /// True when [PlannerApp] runs behind the account gate; legacy desktop-token
  /// mode leaves it false so settings can hide account-only actions.
  bool requiresLogin = false;

  Json? get user => auth.user;
  bool get authenticated => auth.authenticated;

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
    await auth.restore();
    // A v2 login record owns the address; an old cache without one keeps the
    // legacy desktop address for the desktop-token/pairing path.
    if (auth.hasRecord) serverUrl = auth.baseUrl;
    _token = auth.token;
    // No token means the login page can be shown without a round trip.
    sessionChecked = _token.isEmpty;
    _notify();
  }

  /// Startup token check: `GET /api/v1/me`.
  ///
  /// 200 keeps the session, 401 clears the token (login page), and a network
  /// failure lets the cached offline data in — the old offline behavior stays.
  Future<void> bootstrapSession() async {
    if (sessionChecked || checkingSession || _disposed) return;
    checkingSession = true;
    _notify();
    try {
      if (_token.isEmpty) return;
      final status = await auth.verify();
      if (status == SessionStatus.expired) {
        await _sessionExpired();
      } else {
        _token = auth.token;
      }
    } finally {
      checkingSession = false;
      sessionChecked = true;
      _notify();
    }
    if (configured) unawaited(sync());
  }

  String normalizeServerUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ApiFailure('请输入有效的服务地址', 422);
    }
    return url.trim().replaceAll(RegExp(r'/+$'), '');
  }

  /// Signs in against the v2 server, persists the credential and loads data.
  Future<Json?> login(String url, String username, String password) async {
    final normalized = normalizeServerUrl(url);
    serverUrl = normalized;
    _token = '';
    await auth.login(normalized, username.trim(), password);
    return _adoptSession();
  }

  /// Creates the user's own account (the owner must have opened sign-ups) and
  /// continues into the app exactly like a login.
  Future<Json?> register(
    String url,
    String username,
    String password, {
    String displayName = '',
  }) async {
    final normalized = normalizeServerUrl(url);
    serverUrl = normalized;
    _token = '';
    await auth.register(
      normalized,
      username.trim(),
      password,
      displayName: displayName.trim(),
    );
    return _adoptSession();
  }

  Future<Json?> _adoptSession() async {
    serverUrl = auth.baseUrl;
    _token = auth.token;
    connected = false;
    connectionError = null;
    conflict = null;
    await _save();
    _notify();
    await sync();
    return auth.user;
  }

  /// Revokes the device token (best effort) and returns to the login page.
  /// Local cached entities and pending operations belong to the signed-in
  /// account, so they are dropped instead of leaking into the next login.
  Future<void> logout() async {
    await auth.logout();
    await _endLocalSession();
  }

  /// Changes the server address and forces a fresh login against it.
  Future<void> changeServer(String url) async {
    final normalized = normalizeServerUrl(url);
    serverUrl = normalized;
    await auth.changeServer(normalized);
    await _endLocalSession();
  }

  Future<void> _endLocalSession() async {
    _token = '';
    connected = false;
    connectionError = null;
    conflict = null;
    lastSync = null;
    state = blankState();
    pending = [];
    await _save();
    _notify();
  }

  void startPolling() {
    _poll ??= Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(sync()),
    );
  }

  Future<void> connect(String url, String token) async {
    serverUrl = normalizeServerUrl(url);
    _token = token.trim();
    await auth.adopt(serverUrl, _token);
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
    Json? value;
    try {
      value = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
    } catch (_) {
      value = null;
    }
    if (response.statusCode >= 400) {
      // A rejected token means the whole account session is gone: clear it so
      // the app routes back to the login page instead of retrying forever.
      if (response.statusCode == 401 && authenticated) {
        await _sessionExpired();
      }
      throw ApiFailure(
        value?['message'] as String? ?? '操作未完成，请检查输入或连接',
        response.statusCode,
        code: value?['code'] as String?,
      );
    }
    if (value == null) {
      throw ApiFailure('电脑服务返回了无效响应', response.statusCode);
    }
    return value;
  }

  Future<void> _sessionExpired() async {
    if (_token.isEmpty && !auth.authenticated) return;
    _token = '';
    await auth.clear();
    // Cached entities and queued operations belong to the account that just
    // lost its token; keeping them would replay them into the next login.
    connected = false;
    conflict = null;
    lastSync = null;
    state = blankState();
    pending = [];
    connectionError = '登录已过期，请重新登录。';
    await _save();
    _notify();
  }

  /// Streams a large authenticated download (the phone update package).
  Future<http.StreamedResponse> openDownload(String path) async {
    if (!configured) throw ApiFailure('请先在设置里连接电脑。', 409);
    final request = http.Request('GET', Uri.parse('$serverUrl$path'))
      ..headers['Authorization'] = 'Bearer $_token';
    final response = await transport
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode >= 400) {
      if (response.statusCode == 401) await _sessionExpired();
      String? message;
      try {
        message =
            (jsonDecode(await response.stream.bytesToString())
                    as Json)['message']
                as String?;
      } catch (_) {}
      throw ApiFailure(message ?? '下载没有成功', response.statusCode);
    }
    return response;
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
        try {
          await request('POST', '/api/v1/operations', operation);
        } on ApiFailure catch (error) {
          // 有些操作电脑永远不会接受（payload 不合法、引用的实体不存在、
          // 新版服务端规则更严）。把它留在队头会让之后所有操作都同步不了，
          // 所以隔离它、留下证据，让下面的 snapshot 把界面拉回电脑的真实状态。
          if (!_permanentRejection(error)) rethrow;
          await _quarantine(operation, error);
          continue;
        }
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
      connectionError = error.status == 401
          ? '登录已过期，请重新登录。'
          : error.message;
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

  static bool _permanentRejection(ApiFailure error) =>
      const {400, 403, 404, 422}.contains(error.status);

  static const Map<String, String> _operationLabels = {
    'task.create': '新建待办',
    'task.update': '修改待办',
    'block.create': '新增安排',
    'block.update': '修改安排',
    'block.delete': '删除安排',
    'session.start': '开始投入',
    'session.pause': '暂停投入',
    'session.resume': '继续投入',
    'session.end': '结束投入',
    'session.extend': '延长投入',
    'feedback.create': '记录结果',
    'waiting.resolve': '处理等待',
    'waiting.snooze': '稍后再问',
    'review.save': '保存复盘',
    'material.add': '添加材料',
    'memory.save': '记住偏好',
    'memory.delete': '忘记偏好',
    'settings.update': '修改设置',
    'project.save': '保存项目',
    'sleep.start': '记录睡眠',
    'sleep.end': '记录起床',
    'plan.apply': '应用调整',
    'plan.undo': '撤销调整',
  };

  /// 把永远不可能成功的操作从队列里拿出来，连同错误原因留档。
  Future<void> _quarantine(Json operation, ApiFailure error) async {
    pending.remove(operation);
    preservedConflicts.add({
      'saved_at': nowUtc.toIso8601String(),
      'operations': [operation],
      'reason': error.message,
      'status': error.status,
    });
    if (preservedConflicts.length > 20) {
      preservedConflicts.removeRange(0, preservedConflicts.length - 20);
    }
    final label =
        _operationLabels[operation['kind'] as String? ?? ''] ?? '这条操作';
    conflict = '「$label」电脑没有接受：${error.message}。副本已保留，不影响后面的操作。';
    await _save();
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
  Future<Json> uploadMaterial(
    String name,
    String day,
    String description,
    bool externalAllowed,
    List<int> bytes,
  ) async {
    if (!configured) throw ApiFailure('请先连接电脑，材料保存在电脑上。', 409);
    if (bytes.length > 8 * 1024 * 1024) {
      throw ApiFailure('文件超过 8 MB，请拆分后上传。', 422);
    }
    final uri = Uri.parse('$serverUrl/api/v1/materials/upload').replace(
      queryParameters: {
        'name': name,
        'day': day,
        'description': description,
        'external_allowed': '$externalAllowed',
      },
    );
    final response = await transport
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $_token',
            'Content-Type': 'application/octet-stream',
          },
          body: bytes,
        )
        .timeout(const Duration(seconds: 120));
    final result = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
    if (response.statusCode >= 400) {
      if (response.statusCode == 401) await _sessionExpired();
      throw ApiFailure(result['message'] ?? '材料上传失败', response.statusCode);
    }
    await sync();
    return result;
  }

  Future<Json> generateReview(
    String day,
    String text,
    List<String> materials,
    String requestId,
  ) async {
    await sync();
    if (!connected || pending.isNotEmpty) throw ApiFailure('请先完成与电脑的同步。', 409);
    final result = await request(
      'POST',
      '/api/v1/reviews/generate',
      {
        'date': day,
        'text': text,
        'material_ids': materials,
        'request_id': requestId,
      },
      true,
      const Duration(minutes: 10),
    );
    await sync();
    return result;
  }

  Future<Json> saveAssistantConfig(Json body) =>
      _assistant('POST', '/config', body);
  Future<Json> testAssistant() => _assistant('POST', '/test', {});
  Future<List<String>> assistantModels() async =>
      ((await _assistant('GET', '/models'))['models'] as List).cast<String>();
  Future<List<Json>> assistantMessages() async =>
      ((await _assistant('GET', '/messages'))['messages'] as List).cast<Json>();

  /// The assistant changes the schedule on the computer right away, so local
  /// records go up first and the result comes back down afterwards.
  Future<List<Json>> sendAssistant(String text) async {
    if (pending.isNotEmpty) await sync();
    final messages =
        ((await _assistant('POST', '/messages', {'text': text}))['messages']
                as List)
            .cast<Json>();
    if (messages.any(
      (m) => (m['drafts'] as List? ?? []).any((d) => d['status'] == 'applied'),
    )) {
      await sync();
    }
    return messages;
  }

  Future<void> undoDraft(String id) async {
    await sync();
    await _assistant('POST', '/drafts/$id/undo', {});
    await sync();
  }

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
      throw ApiFailure('助手在电脑上运行，请先在设置里连接电脑。', 409);
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

  // ---- QQ official-bot channel (configured on the computer) ----

  Future<Json> _qq(String method, String path, [Json? body]) async {
    if (!configured) {
      throw ApiFailure('QQ 机器人在电脑上运行，请先在设置里连接电脑。', 409);
    }
    return request(method, '/api/v1/qq$path', body);
  }

  Future<Json> qqConfig() => _qq('GET', '/config');
  Future<Json> saveQqConfig(Json body) => _qq('POST', '/config', body);
  Future<Json> qqBindCode() => _qq('POST', '/bind-code', {});
  Future<Json> qqUnbind() => _qq('POST', '/unbind', {});
  Future<Json> qqTest() => _qq('POST', '/test', {});
  Future<List<Json>> qqOutbox() async =>
      ((await _qq('GET', '/outbox'))['messages'] as List).cast<Json>();

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
