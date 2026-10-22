import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

/// Minimal fake of the v2 API for the onboarding flow. The `/me` handler can
/// omit the `onboarding` field to stand in for a pre-v2 account, and
/// [failWrites] keeps reads working while PATCH/operations fail (offline).
class _Backend {
  _Backend({this.hasOnboarding = true});

  final bool hasOnboarding;
  bool failWrites = false;
  final List<http.Request> requests = [];
  final List<Json> patches = [];

  Json user() => {
    'id': 'u1',
    'username': 'alice',
    'display_name': 'Alice',
    'role': 'member',
    if (hasOnboarding)
      'onboarding': {
        'version': 2,
        'step': 0,
        'done': <String>[],
        'skipped': <String>[],
      },
  };

  Iterable<http.Request> get patchRequests =>
      requests.where((request) => request.method == 'PATCH');

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    switch (request.url.path) {
      case '/api/v1/me':
        if (request.method == 'PATCH') {
          if (failWrites) {
            return _json({'code': 'UNREACHABLE', 'message': '连不上电脑'}, 503);
          }
          final body = jsonDecode(request.body) as Json;
          patches.add(body);
          final merged = user();
          if (body['display_name'] != null) {
            merged['display_name'] = body['display_name'];
          }
          if (body['onboarding'] != null) {
            merged['onboarding'] = body['onboarding'];
          }
          return _json({'user': merged});
        }
        return _json({
          'user': user(),
          'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'member'},
        });
      case '/api/v1/snapshot':
        return _json({
          ...blankState(),
          'revision': 1,
          'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'member'},
        });
      case '/api/v1/operations':
        if (failWrites) {
          return _json({'code': 'UNREACHABLE', 'message': '连不上电脑'}, 503);
        }
        return _json({'revision': 2, 'entity': null});
      default:
        return _json({'code': 'NOT_FOUND', 'message': '没有这条路由'}, 404);
    }
  });
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

MemoryStore _seededStore() {
  final storage = MemoryStore();
  storage.token = 'tok-1';
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

PlannerController _controller(LocalStore storage, http.Client transport) =>
    PlannerController(
      storage: storage,
      transport: transport,
      clock: () => DateTime.utc(2026, 10, 19, 16),
    );

void _primeView(WidgetTester tester) {
  tzdata.initializeTimeZones();
  tester.view.physicalSize = const Size(1280, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Pumps the app on a seeded session and returns the controller so the test can
/// dispose it (and, for restart tests, build a second one over the same store).
Future<PlannerController> _pumpApp(
  WidgetTester tester,
  _Backend backend,
  MemoryStore storage,
) async {
  final controller = _controller(storage, backend.client);
  await controller.initialize();
  await tester.pumpWidget(
    PlannerApp(controller: controller, requireLogin: true),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapNext(WidgetTester tester) =>
    _tap(tester, find.byKey(const Key('onboarding.next')));

Future<void> _finishSetup(WidgetTester tester, {String name = '小满'}) async {
  await tester.enterText(find.byKey(const Key('setup.name')), name);
  await _tap(tester, find.byKey(const Key('setup.submit')));
}

Future<void> _stop(WidgetTester tester, PlannerController controller) async {
  await tester.pumpWidget(const SizedBox());
  controller.dispose();
}

void main() {
  testWidgets('首次进入先做基础设置', (tester) async {
    _primeView(tester);
    final backend = _Backend();
    final controller = await _pumpApp(tester, backend, _seededStore());

    expect(find.text('先说说你想怎么用它。'), findsOneWidget);
    expect(find.byKey(const Key('setup.name')), findsOneWidget);
    expect(find.byKey(const Key('setup.timezone')), findsOneWidget);
    expect(find.byKey(const Key('setup.start')), findsOneWidget);
    expect(find.byKey(const Key('setup.end')), findsOneWidget);
    expect(find.byKey(const Key('setup.confirm')), findsOneWidget);
    expect(find.byKey(const Key('onboarding.overlay')), findsNothing);

    await _stop(tester, controller);
  });

  testWidgets('不想填设置也能先跳过，之后在设置里改', (tester) async {
    _primeView(tester);
    final backend = _Backend();
    final storage = _seededStore();
    final controller = await _pumpApp(tester, backend, storage);

    expect(find.byKey(const Key('setup.skip')), findsOneWidget);
    await _tap(tester, find.byKey(const Key('setup.skip')));

    expect(find.text('先说说你想怎么用它。'), findsNothing);
    expect(find.byKey(const Key('onboarding.overlay')), findsOneWidget);
    expect(find.text('第 1 / 10 步'), findsOneWidget);

    final saved = jsonDecode(storage.values['onboarding_v2']!) as Json;
    expect(saved['setup_done'], isTrue);
    expect(backend.patches, isNotEmpty);

    await _stop(tester, controller);
  });

  testWidgets('确认设置会 PATCH /api/v1/me 并进入第一步教程', (tester) async {
    _primeView(tester);
    final backend = _Backend();
    final storage = _seededStore();
    final controller = await _pumpApp(tester, backend, storage);

    await _finishSetup(tester);

    expect(find.byKey(const Key('onboarding.overlay')), findsOneWidget);
    expect(find.text('今天从这里开始'), findsOneWidget);
    expect(find.text('第 1 / 10 步'), findsOneWidget);

    final patch = backend.patches.last;
    expect(patch['display_name'], '小满');
    expect(patch['timezone'], isNotNull);
    expect(patch['onboarding'], isA<Map>());
    expect(storage.values['onboarding_v2'], isNotNull);

    await _stop(tester, controller);
  });

  testWidgets('教程可以上一步、下一步', (tester) async {
    _primeView(tester);
    final backend = _Backend();
    final controller = await _pumpApp(tester, backend, _seededStore());
    await _finishSetup(tester);

    await _tapNext(tester);
    expect(find.text('先安排一件事'), findsOneWidget);
    expect(find.text('第 2 / 10 步'), findsOneWidget);

    await _tapNext(tester);
    expect(find.text('开始 · 暂停 · 结束'), findsOneWidget);
    expect(find.byKey(const Key('onboarding.next')), findsOneWidget);

    await _tap(tester, find.byKey(const Key('onboarding.previous')));
    expect(find.text('先安排一件事'), findsOneWidget);

    await _stop(tester, controller);
  });

  testWidgets('教程高亮处的按钮能真的点开', (tester) async {
    _primeView(tester);
    final controller = await _pumpApp(tester, _Backend(), _seededStore());
    await _finishSetup(tester);

    // 第 1 步指向「今日」标签，第 2 步指向新增按钮。
    await _tapNext(tester);
    expect(find.text('先安排一件事'), findsOneWidget);

    // 蒙层不该挡住高亮位置：点 FAB 要真的打开安排表单。
    await _tap(tester, find.byKey(const Key('action.create')));
    expect(find.byKey(const Key('action.save-task')), findsOneWidget);

    await _stop(tester, controller);
  });

  testWidgets('跳过教程后不再出现', (tester) async {
    _primeView(tester);
    final backend = _Backend();
    final storage = _seededStore();
    final controller = await _pumpApp(tester, backend, storage);
    await _finishSetup(tester);

    await _tap(tester, find.byKey(const Key('onboarding.skip')));
    expect(find.byKey(const Key('onboarding.overlay')), findsNothing);
    expect(find.text('今日尚空。先落一笔有结果的事。'), findsOneWidget);

    await _stop(tester, controller);

    // Restart on the same device: the skip is remembered locally.
    final restarted = await _pumpApp(tester, _Backend(), storage);
    expect(find.byKey(const Key('onboarding.overlay')), findsNothing);
    expect(find.byKey(const Key('setup.name')), findsNothing);

    await _stop(tester, restarted);
  });

  testWidgets('走完十步后结束，设置里可以重新看', (tester) async {
    _primeView(tester);
    final backend = _Backend();
    final controller = await _pumpApp(tester, backend, _seededStore());
    await _finishSetup(tester);

    for (var i = 0; i < 10; i++) {
      await _tapNext(tester);
    }
    expect(find.byKey(const Key('onboarding.overlay')), findsNothing);
    expect(find.text('今日尚空。先落一笔有结果的事。'), findsOneWidget);

    await _tap(tester, find.byTooltip('设置').first);
    expect(find.byKey(const Key('settings.replay-onboarding')), findsOneWidget);
    await _tap(tester, find.byKey(const Key('settings.replay-onboarding')));
    expect(find.byKey(const Key('onboarding.overlay')), findsOneWidget);
    expect(find.text('第 1 / 10 步'), findsOneWidget);

    await _stop(tester, controller);
  });

  testWidgets('重启后从上次的步骤继续', (tester) async {
    _primeView(tester);
    final backend = _Backend();
    final storage = _seededStore();
    final controller = await _pumpApp(tester, backend, storage);
    await _finishSetup(tester);

    await _tapNext(tester);
    await _tapNext(tester);
    expect(find.text('第 3 / 10 步'), findsOneWidget);
    await _stop(tester, controller);

    final restarted = await _pumpApp(tester, _Backend(), storage);
    expect(find.byKey(const Key('onboarding.overlay')), findsOneWidget);
    expect(find.text('第 3 / 10 步'), findsOneWidget);
    expect(find.text('开始 · 暂停 · 结束'), findsOneWidget);

    await _stop(tester, restarted);
  });

  testWidgets('离线也能完成引导，不阻塞、不抛错', (tester) async {
    _primeView(tester);
    final backend = _Backend()..failWrites = true;
    final controller = await _pumpApp(tester, backend, _seededStore());

    await _finishSetup(tester);
    expect(find.byKey(const Key('onboarding.overlay')), findsOneWidget);
    expect(backend.patches, isEmpty, reason: '写不出去的时候静默保留本地进度');

    for (var i = 0; i < 10; i++) {
      await _tapNext(tester);
    }
    expect(find.byKey(const Key('onboarding.overlay')), findsNothing);
    expect(find.text('今日尚空。先落一笔有结果的事。'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Back online: the first successful sync retries the progress push once.
    backend.failWrites = false;
    await controller.sync();
    await tester.pumpAndSettle();
    expect(backend.patches, isNotEmpty);
    expect(backend.patches.last['onboarding'], isA<Map>());

    await _stop(tester, controller);
  });

  testWidgets('窄屏（360）也能完成设置并看到第一步', (tester) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final backend = _Backend();
    final controller = await _pumpApp(tester, backend, _seededStore());

    await tester.enterText(find.byKey(const Key('setup.name')), '小满');
    await tester.ensureVisible(find.byKey(const Key('setup.submit')));
    await _tap(tester, find.byKey(const Key('setup.submit')));

    expect(find.byKey(const Key('onboarding.overlay')), findsOneWidget);
    expect(find.text('今天从这里开始'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _stop(tester, controller);
  });

  testWidgets('没有 onboarding 字段的老账号不弹引导', (tester) async {
    _primeView(tester);
    final backend = _Backend(hasOnboarding: false);
    final controller = await _pumpApp(tester, backend, _seededStore());

    expect(find.byKey(const Key('onboarding.overlay')), findsNothing);
    expect(find.byKey(const Key('setup.name')), findsNothing);
    expect(find.text('今日尚空。先落一笔有结果的事。'), findsOneWidget);
    expect(backend.patchRequests, isEmpty);

    await _stop(tester, controller);
  });
}
