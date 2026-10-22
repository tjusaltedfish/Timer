import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

/// 手机整链冒烟：登录 → 首次设置 → 跳过教程 → 新增待办 → 一周 → 助手。
///
/// 每个用户真正会走的第一遍路线，专门抓「单页测试都过、连起来就点不动」这类
/// 集成 bug（引导蒙层吞点击就是这么被抓到的）。390×844，接近主流手机。
void main() {
  Json user({Map<String, Object?>? onboarding}) => {
    'id': 'u1',
    'username': 'alice',
    'display_name': 'Alice',
    'role': 'member',
    'timezone': 'Asia/Shanghai',
    'onboarding':
        onboarding ??
        {'version': 2, 'step': 0, 'done': <String>[], 'skipped': <String>[]},
  };

  Json me = user();
  final List<String> operations = [];
  final Json serverState = blankState();
  var revision = 1;

  MockClient backend() => MockClient((request) async {
    final path = request.url.path;
    switch (path) {
      case '/api/v1/auth/login':
        return _json({
          'token': 'tok-1',
          'user': me,
          'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'phone'},
        });
      case '/api/v1/me':
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Json;
          me = {
            ...me,
            if (body['display_name'] != null)
              'display_name': body['display_name'],
            if (body['onboarding'] != null) 'onboarding': body['onboarding'],
          };
          return _json({'user': me});
        }
        return _json({
          'user': me,
          'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'phone'},
        });
      case '/api/v1/snapshot':
        return _json({
          ...serverState,
          'revision': revision,
          'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'phone'},
        });
      case '/api/v1/operations':
        final body = jsonDecode(request.body) as Json;
        final kind = body['kind'] as String;
        final payload = (body['payload'] as Json?) ?? <String, dynamic>{};
        operations.add(kind);
        if (kind == 'task.create') {
          final created = {
            'id': 't${revision + 1}',
            'title': payload['title'],
            'state': 'ready',
            'remaining_minutes': payload['remaining_minutes'] ?? 60,
            'outcome_criteria': payload['outcome_criteria'] ?? '',
          };
          serverState['tasks'] = <Json>[...?serverState['tasks'], created];
          revision += 1;
        }
        return _json({'revision': revision, 'entity': null});
      case '/api/v1/assistant/config':
        return _json({
          'configured': true,
          'base_url': 'https://api.deepseek.com',
          'model': 'deepseek-chat',
          'daily_limit': 200,
          'used_today': 0,
          'confirm_first': false,
          'persona': '大肥鱼',
          'key_source': 'user',
          'key_hint': '····abcd',
        });
      case '/api/v1/assistant/messages':
        return _json({'messages': <Json>[]});
      case '/api/v1/channels/bindings':
        return _json({'items': <Json>[]});
      case '/api/v1/wechat/config':
        return _json({'configured': false, 'bound': false});
      case '/api/v1/wechat/outbox':
        return _json({'messages': <Json>[]});
      case '/api/v1/app/latest':
        return _json({'version': '1.2.8', 'build': 18});
      default:
        return _json(<Json>{});
    }
  });

  testWidgets('手机首启：登录→设置→跳过教程→排第一件事→切页', (tester) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final storage = MemoryStore();
    final c = PlannerController(
      storage: storage,
      transport: backend(),
      clock: () => DateTime.utc(2026, 10, 19, 17, 30),
    );
    await c.initialize();
    await tester.pumpWidget(PlannerApp(controller: c, requireLogin: true));
    await tester.pumpAndSettle();

    // 1) 登录（手机上默认就是公网地址，这里换成本机 mock）。
    expect(find.byKey(const Key('login.submit')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('login.server-url')),
      'http://127.0.0.1:8787',
    );
    await tester.enterText(find.byKey(const Key('login.username')), 'alice');
    await tester.enterText(
      find.byKey(const Key('login.password')),
      'alice-secret',
    );
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pumpAndSettle();

    // 2) 首次设置页：填名字，点「开始使用」（`setup.confirm` 是「先问再做」开关）。
    expect(find.byKey(const Key('setup.name')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('setup.name')), '小满');
    // 390×844 上按钮在首屏折叠线以下，先滚它进视口再点（真机也一样）。
    await tester.ensureVisible(find.byKey(const Key('setup.submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('setup.submit')));
    await tester.pumpAndSettle();

    // 3) 教程出现，可以直接跳过（跳过按钮必须点得到）。
    expect(find.byKey(const Key('onboarding.overlay')), findsOneWidget);
    expect(find.byKey(const Key('onboarding.skip')), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding.skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('onboarding.overlay')), findsNothing);

    // 4) 首页：点 FAB 排第一件事。
    expect(find.text('今日尚空。先落一笔有结果的事。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('action.create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '写报告');
    // 表单要求同时写「做到什么程度算完成」，否则保存按钮只会提示、不提交。
    await tester.enterText(find.byType(TextField).at(1), '一份能发出去的初稿');
    await tester.tap(find.text('保存安排'));
    await tester.pumpAndSettle();
    debugPrint('CONNECTED=${c.connected} PENDING=${c.pending.length}');
    debugPrint(
      'SHEET_TEXTS=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().where((t) => t.length > 2).toList()}',
    );
    await c.sync();
    await tester.pumpAndSettle();
    expect(operations, contains('task.create'));
    // 新建的任务落进本地状态（首页是否立即可见取决于排期，这里看数据层）。
    expect(c.tasks.map((task) => task['title']), contains('写报告'));

    // 5) 切到「一周」「助手」，页面能渲染、不抛异常。
    await tester.tap(find.text('一周'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.overview')), findsOneWidget);

    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('assistant.input')), findsOneWidget);

    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('手机弹层的保存按钮留在屏幕内', (tester) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 每个用例独立的服务器状态（上一个用例会 PATCH /me 改掉全局 `me`）。
    me = user(
      onboarding: {
        'version': 2,
        'step': 10,
        'done': ['welcome', 'setup', 'finish'],
        'skipped': <String>[],
      },
    );
    final storage = MemoryStore();
    storage.token = 'tok-1';
    storage.values['auth_session'] = jsonEncode({
      'base_url': 'http://127.0.0.1:8787',
      'user': me,
      'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'phone'},
    });
    final c = PlannerController(
      storage: storage,
      transport: backend(),
      clock: () => DateTime.utc(2026, 10, 19, 17, 30),
    );
    await c.initialize();
    await tester.pumpWidget(PlannerApp(controller: c, requireLogin: true));
    await tester.pumpAndSettle();

    // 睡眠记录弹层：两个时间轮盘叠起来，最容易把动作按钮挤出去。
    // 首次设置页先「开始使用」，才进到主页。
    await tester.tap(find.byTooltip('睡眠记录'));
    await tester.pumpAndSettle();
    final save = tester.getRect(find.text('记下'));
    expect(save.bottom, lessThanOrEqualTo(844.0));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('手机五个主页面与设置页都能打开、不抛异常', (tester) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    me = user(
      onboarding: {
        'version': 2,
        'step': 10,
        'done': ['welcome', 'setup', 'finish'],
        'skipped': <String>[],
      },
    );
    final storage = MemoryStore();
    storage.token = 'tok-1';
    storage.values['auth_session'] = jsonEncode({
      'base_url': 'http://127.0.0.1:8787',
      'user': me,
      'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'phone'},
    });
    final c = PlannerController(
      storage: storage,
      transport: backend(),
      clock: () => DateTime.utc(2026, 10, 19, 17, 30),
    );
    await c.initialize();
    await tester.pumpWidget(PlannerApp(controller: c, requireLogin: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home.clock')), findsOneWidget);
    for (final label in ['一周', '诸事', '回顾', '助手', '今日']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '切到「$label」就抛异常');
    }

    // 设置页（账号 / 助手 / 公众号 / 外观都在这里）。
    await tester.tap(find.byTooltip('设置').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('助手'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump(const Duration(seconds: 1));
  });
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
