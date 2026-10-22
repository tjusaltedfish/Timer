import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

/// Minimal fake of the v2 API. Tests can override the login/me handlers and
/// flip status codes to simulate expired tokens or a dead network.
class _Backend {
  final List<http.Request> requests = [];
  Future<http.Response> Function(http.Request request)? login;
  Future<http.Response> Function(http.Request request)? me;
  int snapshotStatus = 200;
  int logoutStatus = 200;

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    switch (request.url.path) {
      case '/api/v1/auth/login':
        return (login ?? _defaultLogin)(request);
      case '/api/v1/me':
        return (me ?? _defaultMe)(request);
      case '/api/v1/auth/logout':
        return _json({'revoked': true}, logoutStatus);
      case '/api/v1/snapshot':
        if (snapshotStatus >= 400) {
          return _json(
            {'code': 'TOKEN_REVOKED', 'message': '登录已失效'},
            snapshotStatus,
          );
        }
        return _json({
          ...blankState(),
          'revision': 1,
          'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'desktop'},
        });
      case '/api/v1/operations':
        return _json({
          'revision': 2,
          'entity': null,
        });
      default:
        return _json({'code': 'NOT_FOUND', 'message': '没有这条路由'}, 404);
    }
  });

  static Future<http.Response> _defaultLogin(http.Request request) async {
    final body = jsonDecode(request.body) as Json;
    final device = body['device'] as Json? ?? <String, dynamic>{};
    return _json({
      'token': 'tok-1',
      'user': {
        'id': 'u1',
        'username': body['username'],
        'display_name': 'Alice',
        'role': 'member',
      },
      'device': {'id': 'd1', 'role': 'member', ...device},
    });
  }

  static Future<http.Response> _defaultMe(http.Request request) async {
    return _json({
      'user': {
        'id': 'u1',
        'username': 'alice',
        'display_name': 'Alice',
        'role': 'member',
      },
      'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'member'},
    });
  }
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// A store that already holds a signed-in session, as a returning user would.
MemoryStore _seededStore({String token = 'tok-1'}) {
  final storage = MemoryStore();
  storage.token = token;
  storage.values['auth_session'] = jsonEncode({
    'base_url': 'http://127.0.0.1:8765',
    'user': {
      'id': 'u1',
      'username': 'alice',
      'display_name': 'Alice',
      'role': 'member',
    },
    'device': {'id': 'd1', 'name': '瞬时客户端'},
  });
  return storage;
}

PlannerController _controller(
  LocalStore storage,
  http.Client transport, {
  DateTime? now,
}) => PlannerController(
  storage: storage,
  transport: transport,
  clock: () => now ?? DateTime.utc(2026, 10, 19, 16),
);

void _primeView(WidgetTester tester) {
  tzdata.initializeTimeZones();
  tester.view.physicalSize = const Size(1280, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('设置').first);
  await tester.pumpAndSettle();
}

void main() {
  group('登录页', () {
    testWidgets('空字段和非法地址都在本地拦下，不发请求', (tester) async {
      _primeView(tester);
      final backend = _Backend();
      final controller = _controller(MemoryStore(), backend.client);
      await controller.initialize();

      await tester.pumpWidget(
        PlannerApp(controller: controller, requireLogin: true),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('login.submit')), findsOneWidget);
      expect(
        find.text('http://127.0.0.1:8765'),
        findsWidgets,
        reason: '服务器地址默认取契约里的 8765',
      );

      await tester.tap(find.byKey(const Key('login.submit')));
      await tester.pumpAndSettle();
      expect(find.text('请填写用户名'), findsOneWidget);
      expect(find.byKey(const Key('login.error')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('login.username')), 'alice');
      await tester.tap(find.byKey(const Key('login.submit')));
      await tester.pumpAndSettle();
      expect(find.text('请填写密码'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('login.password')), 'secret');
      await tester.enterText(
        find.byKey(const Key('login.server-url')),
        'ftp://nope',
      );
      await tester.tap(find.byKey(const Key('login.submit')));
      await tester.pumpAndSettle();
      expect(find.text('请输入有效的服务地址'), findsOneWidget);

      expect(backend.requests, isEmpty);
      expect(controller.authenticated, isFalse);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('登录失败展示服务端 code', (tester) async {
      _primeView(tester);
      final backend = _Backend();
      var code = 'INVALID_CREDENTIALS';
      var detail = '用户名或密码不对';
      backend.login = (_) async => _json({'code': code, 'message': detail}, 401);

      final controller = _controller(MemoryStore(), backend.client);
      await controller.initialize();
      await tester.pumpWidget(
        PlannerApp(controller: controller, requireLogin: true),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('login.username')), 'alice');
      await tester.enterText(find.byKey(const Key('login.password')), 'oops');
      await tester.tap(find.byKey(const Key('login.submit')));
      await tester.pumpAndSettle();
      expect(find.text('用户名或密码不对（INVALID_CREDENTIALS）'), findsOneWidget);

      code = 'RATE_LIMITED';
      detail = '尝试太频繁';
      await tester.tap(find.byKey(const Key('login.submit')));
      await tester.pumpAndSettle();
      expect(find.text('尝试太频繁，请稍后再试（RATE_LIMITED）'), findsOneWidget);

      expect(find.byKey(const Key('login.submit')), findsOneWidget);
      expect(controller.authenticated, isFalse);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('登录成功持久化 token/地址/用户并进入首页', (tester) async {
      _primeView(tester);
      final storage = MemoryStore();
      final backend = _Backend();
      final controller = _controller(storage, backend.client);
      await controller.initialize();
      await tester.pumpWidget(
        PlannerApp(controller: controller, requireLogin: true),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('login.username')), 'alice');
      await tester.enterText(find.byKey(const Key('login.password')), 'secret');
      await tester.enterText(
        find.byKey(const Key('login.server-url')),
        'http://127.0.0.1:9000/',
      );
      await tester.tap(find.byKey(const Key('login.submit')));
      await tester.pumpAndSettle();

      expect(controller.authenticated, isTrue);
      expect(controller.serverUrl, 'http://127.0.0.1:9000');
      expect(storage.token, 'tok-1');

      final record =
          jsonDecode(storage.values['auth_session']!) as Map<String, dynamic>;
      expect(record['base_url'], 'http://127.0.0.1:9000');
      expect((record['user'] as Json)['username'], 'alice');

      final loginRequest = backend.requests.firstWhere(
        (request) => request.url.path == '/api/v1/auth/login',
      );
      final loginBody = jsonDecode(loginRequest.body) as Json;
      expect(loginBody['username'], 'alice');
      expect(loginBody['password'], 'secret');
      final device = loginBody['device'] as Json;
      expect(device['name'], isNotEmpty);
      expect(device['platform'], isNotEmpty);

      expect(
        backend.requests
            .where((request) => request.url.path == '/api/v1/snapshot')
            .map((request) => request.headers['Authorization']),
        contains('Bearer tok-1'),
        reason: '所有请求都要带 Bearer token',
      );
      expect(find.byKey(const Key('login.submit')), findsNothing);
      expect(find.text('今日尚空。先落一笔有结果的事。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });

  group('会话持久化', () {
    test('重启后恢复地址、token 和用户', () async {
      final storage = MemoryStore();
      final backend = _Backend();
      final first = _controller(storage, backend.client);
      await first.initialize();
      await first.login('http://127.0.0.1:9123', 'alice', 'secret');
      expect(first.authenticated, isTrue);
      expect(first.user!['display_name'], 'Alice');
      first.dispose();

      final second = _controller(storage, backend.client);
      await second.initialize();
      expect(second.authenticated, isTrue);
      expect(second.serverUrl, 'http://127.0.0.1:9123');
      expect(second.user!['username'], 'alice');
      second.dispose();
    });

    test('token 失效时丢弃旧账号队列，避免重放给下一个登录', () async {
      final storage = MemoryStore();
      final offline = _controller(
        storage,
        MockClient((_) async => throw http.ClientException('offline')),
      );
      await offline.initialize();
      await offline.connect('http://127.0.0.1:8765', 'tok-1');
      await offline.submit('task.create', {
        'id': 'draft-1',
        'title': '只有本地才有的记录',
        'outcome_criteria': '不应出现在下一个账号',
        'remaining_minutes': 30,
      });
      expect(offline.pending, hasLength(1));
      offline.dispose();

      final backend = _Backend();
      backend.me = (_) async =>
          _json({'code': 'TOKEN_REVOKED', 'message': '登录已失效'}, 401);
      final restarted = _controller(storage, backend.client);
      await restarted.initialize();
      expect(restarted.pending, isNotEmpty, reason: '离线缓存先恢复');
      await restarted.bootstrapSession();

      expect(restarted.authenticated, isFalse);
      expect(restarted.pending, isEmpty);
      expect(restarted.tasks, isEmpty);
      expect(storage.token, '');
      restarted.dispose();
    });

    testWidgets('启动时先显示进行中，再用缓存 token 校验 /me 后进入首页', (tester) async {
      _primeView(tester);
      final storage = _seededStore();
      final backend = _Backend();
      final gate = Completer<void>();
      String? meAuth;
      backend.me = (request) async {
        meAuth = request.headers['Authorization'];
        await gate.future;
        return _json({
          'user': {'id': 'u1', 'username': 'alice', 'display_name': 'Alice'},
          'device': {'id': 'd1', 'name': '瞬时客户端'},
        });
      };

      final controller = _controller(storage, backend.client);
      await controller.initialize();
      expect(controller.sessionChecked, isFalse);

      await tester.pumpWidget(
        PlannerApp(controller: controller, requireLogin: true),
      );
      await tester.pump();
      expect(find.text('正在进入瞬时'), findsOneWidget);
      expect(find.byKey(const Key('login.submit')), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      expect(meAuth, 'Bearer tok-1');
      expect(controller.sessionChecked, isTrue);
      expect(find.byKey(const Key('login.submit')), findsNothing);
      expect(find.text('今日尚空。先落一笔有结果的事。'), findsOneWidget);
      expect(storage.token, 'tok-1');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('启动校验 401 清掉 token 回登录页且不再重试', (tester) async {
      _primeView(tester);
      final storage = _seededStore();
      final backend = _Backend();
      backend.me = (_) async =>
          _json({'code': 'TOKEN_REVOKED', 'message': '登录已失效'}, 401);

      final controller = _controller(storage, backend.client);
      await controller.initialize();
      await tester.pumpWidget(
        PlannerApp(controller: controller, requireLogin: true),
      );
      await tester.pumpAndSettle();

      expect(controller.authenticated, isFalse);
      expect(storage.token, '');
      expect(controller.connectionError, '登录已过期，请重新登录。');
      expect(find.byKey(const Key('login.submit')), findsOneWidget);

      final requestsBefore = backend.requests.length;
      await controller.sync();
      await controller.sync();
      expect(backend.requests.length, requestsBefore,
          reason: '没有 token 时不能反复请求快照');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('使用中的 401 回到登录页', (tester) async {
      _primeView(tester);
      final storage = _seededStore();
      final backend = _Backend();
      final controller = _controller(storage, backend.client);
      await controller.initialize();
      await tester.pumpWidget(
        PlannerApp(controller: controller, requireLogin: true),
      );
      await tester.pumpAndSettle();
      expect(controller.connected, isTrue);

      backend.snapshotStatus = 401;
      await controller.sync();
      await tester.pumpAndSettle();

      expect(controller.authenticated, isFalse);
      expect(storage.token, '');
      expect(controller.connectionError, '登录已过期，请重新登录。');
      expect(find.byKey(const Key('login.submit')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('校验接口连不上时保留缓存并离线进入', (tester) async {
      _primeView(tester);
      final storage = _seededStore();

      final transport = MockClient(
        (_) async => throw http.ClientException('offline'),
      );
      final controller = _controller(storage, transport);
      await controller.initialize();
      await tester.pumpWidget(
        PlannerApp(controller: controller, requireLogin: true),
      );
      await tester.pumpAndSettle();

      expect(controller.authenticated, isTrue);
      expect(storage.token, 'tok-1');
      expect(find.byKey(const Key('login.submit')), findsNothing);
      expect(find.text('今日尚空。先落一笔有结果的事。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });

  group('账号设置', () {
    testWidgets('账号区块展示身份并能退出登录', (tester) async {
      _primeView(tester);
      final storage = _seededStore();
      final backend = _Backend();
      final controller = _controller(storage, backend.client);
      await controller.initialize();
      await tester.pumpWidget(
        PlannerApp(controller: controller, requireLogin: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login.submit')), findsNothing);

      await _openSettings(tester);
      expect(find.text('账号'), findsOneWidget);
      expect(find.text('Alice'), findsWidgets);
      expect(find.text('用户名：alice'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('account.logout')));
      await tester.tap(find.byKey(const Key('account.logout')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account.logout-confirm')), findsOneWidget);

      await tester.tap(find.byKey(const Key('account.logout-confirm')));
      await tester.pumpAndSettle();

      expect(controller.authenticated, isFalse);
      expect(storage.token, '');
      expect(
        backend.requests.where((request) => request.url.path == '/api/v1/auth/logout'),
        hasLength(1),
        reason: '退出登录应吊销当前设备',
      );
      expect(find.byKey(const Key('login.submit')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('修改服务器地址会清空会话并记住新地址', (tester) async {
      _primeView(tester);
      final storage = _seededStore();
      final backend = _Backend();
      final controller = _controller(storage, backend.client);
      await controller.initialize();
      await tester.pumpWidget(
        PlannerApp(controller: controller, requireLogin: true),
      );
      await tester.pumpAndSettle();

      await _openSettings(tester);
      await tester.ensureVisible(find.byKey(const Key('account.server')));
      await tester.tap(find.byKey(const Key('account.server')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('account.server-field')),
        'http://127.0.0.1:9100',
      );
      await tester.tap(find.byKey(const Key('account.server-save')));
      await tester.pumpAndSettle();

      expect(controller.authenticated, isFalse);
      expect(storage.token, '');
      final record =
          jsonDecode(storage.values['auth_session']!) as Map<String, dynamic>;
      expect(record['base_url'], 'http://127.0.0.1:9100');
      expect(find.byKey(const Key('login.submit')), findsOneWidget);
      expect(find.text('http://127.0.0.1:9100'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });
}
