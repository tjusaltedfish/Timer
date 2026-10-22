import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

/// 「点输入框，键盘要能弹出来」——手机 360dp、真实焦点链路上的回归测试。
///
/// 用户反馈过「无法调动起输入法」，这两个入口是他登录后最先碰到的：
/// 首次进入的资料页、助手对话输入框。
void main() {
  Json user({required bool onboardingDone}) => {
    'id': 'u1',
    'username': 'alice',
    'display_name': 'Alice',
    'role': 'member',
    'onboarding': {
      'version': 2,
      'step': onboardingDone ? 10 : 0,
      'done': onboardingDone ? <String>['welcome', 'finish'] : <String>[],
      'skipped': <String>[],
    },
  };

  MockClient backend({required bool onboardingDone}) => MockClient((request) async {
    final path = request.url.path;
    final body = switch (path) {
      '/api/v1/me' => {
        'user': user(onboardingDone: onboardingDone),
        'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'mobile'},
      },
      '/api/v1/snapshot' => {
        ...blankState(),
        'device': {'id': 'd1', 'role': 'mobile'},
      },
      '/api/v1/assistant/config' => {
        'configured': true,
        'base_url': 'https://api.deepseek.com',
        'model': 'deepseek-chat',
        'daily_limit': 200,
        'used_today': 0,
        'confirm_first': false,
        'persona': '大肥鱼',
        'key_source': 'user',
        'key_hint': '····abcd',
      },
      '/api/v1/assistant/messages' => {'messages': <Json>[]},
      '/api/v1/channels/bindings' => {'items': <Json>[]},
      '/api/v1/wechat/config' => {'configured': false, 'bound': false},
      '/api/v1/wechat/outbox' => {'messages': <Json>[]},
      '/api/v1/app/latest' => {'version': '1.2.7', 'build': 17},
      _ => <Json>{},
    };
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  Future<PlannerController> setup(
    WidgetTester tester, {
    required bool onboardingDone,
  }) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStore();
    storage.token = 'tok-1';
    storage.values['auth_session'] = jsonEncode({
      'base_url': 'http://127.0.0.1:8787',
      'user': user(onboardingDone: onboardingDone),
      'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'mobile'},
    });
    final c = PlannerController(
      storage: storage,
      transport: backend(onboardingDone: onboardingDone),
    );
    await c.initialize();
    await tester.pumpWidget(PlannerApp(controller: c, requireLogin: true));
    await tester.pumpAndSettle();
    return c;
  }

  /// Tears the app down the same way it shuts down in production, so the
  /// 20-second sync poll from `home.dart` does not outlive the test.
  Future<void> teardown(WidgetTester tester, PlannerController c) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the first-run setup name field opens the keyboard', (tester) async {
    final c = await setup(tester, onboardingDone: false);
    final field = find.byKey(const Key('setup.name'));
    expect(field, findsOneWidget);
    await tester.tap(field);
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(tester.takeException(), isNull);
    await teardown(tester, c);
  });

  testWidgets('the assistant input opens the keyboard on a phone', (tester) async {
    final c = await setup(tester, onboardingDone: true);
    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('assistant.input'));
    expect(input, findsOneWidget);
    await tester.tap(input);
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(tester.takeException(), isNull);
    await teardown(tester, c);
  });
}
