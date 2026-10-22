import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

/// 一个只服务设置页所需接口的假后端。QQ 配置读写同一份 [qq] 里，
/// [messages] 是发送队列，POST /qq/test 会往队列里塞一条。
MockClient _backend({
  required Json qq,
  required List<Json> messages,
  required Map<String, Json> posted,
}) => MockClient((request) async {
  final path = request.url.path;
  if (request.method == 'POST') {
    posted[path] = jsonDecode(request.body) as Json;
  }
  Json body;
  switch (path) {
    case '/api/v1/snapshot':
      body = {
        ...blankState(),
        'device': {'id': 'desktop', 'role': 'desktop'},
      };
    case '/api/v1/assistant/config':
      body = {'configured': false, 'key_hint': ''};
    case '/api/v1/wechat/config':
      body = {
        'configured': false,
        'app_id': '',
        'secret_hint': '',
        'template_id': '',
        'callback_path': '/wechat/callback',
        'bound': false,
        'bound_hint': '',
        'proactive_enabled': true,
        'token': 'TokenForWeChatPage0123456789abcd',
      };
    case '/api/v1/wechat/outbox':
      body = {'messages': <Json>[]};
    case '/api/v1/qq/config':
      if (request.method == 'POST') {
        final sent = posted[path]!;
        if (sent['app_id'] != null) {
          qq['app_id'] = sent['app_id'];
          qq['configured'] = true;
          qq['secret_hint'] = '····cdef';
        }
        if (sent['proactive_enabled'] != null) {
          qq['proactive_enabled'] = sent['proactive_enabled'];
        }
      }
      body = qq;
    case '/api/v1/qq/bind-code':
      body = {'code': '135790', 'expires_at': '2026-10-21T16:10:00Z'};
    case '/api/v1/qq/unbind':
      qq['bound'] = false;
      qq['bound_hint'] = '';
      body = {'bound': false};
    case '/api/v1/qq/test':
      messages.insert(0, {
        'id': 'test-1',
        'text': '这是一条来自瞬时的测试消息。收到就说明电脑后台能通过 QQ 找到你了。',
        'status': 'queued',
        'attempts': 0,
        'last_error': null,
        'created_at': '2026-10-21T16:00:00Z',
        'sent_at': null,
      });
      body = {'queued': true};
    case '/api/v1/qq/outbox':
      body = {'messages': messages};
    default:
      body = {};
  }
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
});

Future<PlannerController> _openSettings(
  WidgetTester tester,
  http.Client backend,
) async {
  tzdata.initializeTimeZones();
  tester.view.physicalSize = const Size(1280, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = PlannerController(storage: MemoryStore(), transport: backend);
  await c.initialize();
  await c.connect('http://127.0.0.1:8787', 'desktop-token');
  await tester.pumpWidget(PlannerApp(controller: c));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('设置').first);
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('desktop fills QQ bot credentials, saves, and gets a bind code', (
    tester,
  ) async {
    final posted = <String, Json>{};
    final qq = <String, dynamic>{
      'proactive_enabled': true,
      'configured': false,
      'app_id': '',
      'secret_hint': '',
      'bound': false,
      'bound_hint': '',
      'bound_at': null,
      'bind_hint': '先在 QQ 里给机器人发一句「你好」，它会回你 6 位绑定码',
    };
    final c = await _openSettings(
      tester,
      _backend(qq: qq, messages: [], posted: posted),
    );
    expect(find.text('QQ 机器人'), findsOneWidget);
    expect(find.text('还没有发过消息'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('qq.app-id')), '1020304050');
    await tester.enterText(
      find.byKey(const Key('qq.secret')),
      'abcdef0123456789abcdef0123456789',
    );
    await tester.ensureVisible(find.byKey(const Key('qq.save')));
    await tester.tap(find.byKey(const Key('qq.save')));
    await tester.pumpAndSettle();
    expect(posted['/api/v1/qq/config']!['app_id'], '1020304050');
    expect(
      posted['/api/v1/qq/config']!['app_secret'],
      'abcdef0123456789abcdef0123456789',
    );
    expect(find.text('已保存'), findsOneWidget);
    // AppSecret 只回显提示，不再显示原文。
    expect(find.text('abcdef0123456789abcdef0123456789'), findsNothing);
    expect(find.text('6 位数字，10 分钟内有效'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('qq.bind-code')));
    await tester.tap(find.byKey(const Key('qq.bind-code')));
    await tester.pumpAndSettle();
    expect(posted.containsKey('/api/v1/qq/bind-code'), isTrue);
    expect(find.text('135790'), findsOneWidget);
    expect(find.text('在 QQ 里找到这个机器人，给它发这句 6 位数字'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('desktop sends a QQ test message and lists the outbox', (
    tester,
  ) async {
    final posted = <String, Json>{};
    final messages = <Json>[
      {
        'id': 'sent-1',
        'text': '这是一条来自瞬时的测试消息。',
        'status': 'sent',
        'attempts': 1,
        'last_error': null,
        'created_at': '2026-10-21T15:00:00Z',
        'sent_at': '2026-10-21T15:00:03Z',
      },
    ];
    final qq = <String, dynamic>{
      'proactive_enabled': true,
      'configured': true,
      'app_id': '1020304050',
      'secret_hint': '····cdef',
      'bound': true,
      'bound_hint': '····1234',
      'bound_at': '2026-10-21T15:00:00Z',
      'bind_hint': '',
    };
    final c = await _openSettings(
      tester,
      _backend(qq: qq, messages: messages, posted: posted),
    );
    expect(find.text('已绑定 ····1234'), findsOneWidget);
    expect(find.textContaining('已发出'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('qq.test')));
    await tester.tap(find.byKey(const Key('qq.test')));
    await tester.pumpAndSettle();
    expect(posted.containsKey('/api/v1/qq/test'), isTrue);
    expect(find.text('已经排队，几秒内看 QQ'), findsOneWidget);
    expect(find.textContaining('排队中'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
