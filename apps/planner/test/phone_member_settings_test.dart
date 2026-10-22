import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

/// 成员（手机、role=mobile）也要能做两件以前只有电脑能做的事：
/// 1. 在「设置 · 助手」里填自己的 API Key；
/// 2. 在「设置 · 微信助手」里看到绑定教程，并生成自己的 6 位绑定码。
void main() {
  testWidgets('a phone member configures the assistant and binds WeChat', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final posted = <String, Json>{};
    final c = PlannerController(
      storage: MemoryStore(),
      transport: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST') {
          posted[path] = jsonDecode(request.body) as Json;
        }
        final body = switch (path) {
          '/api/v1/snapshot' => {
            ...blankState(),
            'device': {'id': 'phone', 'role': 'mobile'},
          },
          '/api/v1/assistant/config' => {
            'configured': false,
            'key_hint': '',
            'base_url': '',
            'model': '',
            'daily_limit': 200,
          },
          '/api/v1/channels/bindings' => {'items': <Json>[]},
          '/api/v1/wechat/config' => {
            'configured': true,
            'app_id': 'wx0123456789abcdef',
            'secret_hint': '····cdef',
            'template_id': '',
            'callback_path': '/wechat/callback',
            'bound': false,
            'bound_hint': '',
            'proactive_enabled': true,
            'token': 'TokenForWeChatPage0123456789abcd',
          },
          '/api/v1/wechat/outbox' => {'messages': <Json>[]},
          '/api/v1/channels/wechat/bind-code' => {
            'code': '123456',
            'channel': 'wechat',
            'expires_at': '2026-10-22T16:10:00Z',
          },
          _ => <Json>{},
        };
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await c.initialize();
    await c.connect('http://127.0.0.1:8787', 'phone-token');
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('assistant.url')), findsOneWidget);
    expect(find.byKey(const Key('assistant.key')), findsOneWidget);
    expect(find.byKey(const Key('wechat.tutorial')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('wechat.bind-mine')));
    await tester.tap(find.byKey(const Key('wechat.bind-mine')));
    await tester.pumpAndSettle();
    expect(find.text('123456'), findsOneWidget);
    expect(posted['/api/v1/channels/wechat/bind-code'], isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('tapping a field in the task sheet connects the keyboard', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = PlannerController(
      storage: MemoryStore(),
      transport: MockClient((request) async {
        final body = switch (request.url.path) {
          '/api/v1/snapshot' => {
            ...blankState(),
            'device': {'id': 'phone', 'role': 'mobile'},
          },
          '/api/v1/assistant/config' => {'configured': false, 'key_hint': ''},
          '/api/v1/channels/bindings' => {'items': <Json>[]},
          '/api/v1/wechat/config' => {'configured': false, 'bound': false},
          _ => <Json>{},
        };
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await c.initialize();
    await c.connect('http://127.0.0.1:8787', 'phone-token');
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    // 今日页空态的第一个入口就是新建待办；待办弹层里点名字输入框。
    await tester.tap(find.text('安排第一件事'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
