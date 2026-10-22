import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

void main() {
  testWidgets(
    'desktop configures the WeChat test account and gets a bind code',
    (tester) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final posted = <String, Json>{};
      var wechat = <String, dynamic>{
        'configured': false,
        'app_id': '',
        'secret_hint': '',
        'template_id': '',
        'callback_path': '/wechat/callback',
        'bound': false,
        'bound_hint': '',
        'token': 'TokenForWeChatPage0123456789abcd',
      };
      final snapshot = {
        ...blankState(),
        'device': {'id': 'desktop', 'role': 'desktop'},
      };
      final c = PlannerController(
        storage: MemoryStore(),
        transport: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST') {
            posted[path] = jsonDecode(request.body) as Json;
          }
          Json body = switch (path) {
            '/api/v1/snapshot' => snapshot,
            '/api/v1/assistant/config' => {'configured': false, 'key_hint': ''},
            '/api/v1/wechat/outbox' => {'messages': <Json>[]},
            '/api/v1/wechat/bind-code' => {
              'code': '482913',
              'expires_at': '2026-10-19T16:10:00Z',
            },
            '/api/v1/channels/bindings' => {'items': <Json>[]},
            '/api/v1/channels/wechat/bind-code' => {
              'code': '482913',
              'channel': 'wechat',
              'expires_at': '2026-10-19T16:10:00Z',
            },
            _ => {},
          };
          if (path == '/api/v1/wechat/config') {
            if (request.method == 'POST') {
              final sent = posted[path]!;
              wechat = {
                ...wechat,
                'configured': true,
                'app_id': sent['app_id'],
                'secret_hint': '····cdef',
              };
            }
            body = wechat;
          }
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await c.initialize();
      await c.connect('http://127.0.0.1:8787', 'desktop-token');
      await tester.pumpWidget(PlannerApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置').first);
      await tester.pumpAndSettle();
      expect(find.text('微信助手（旧通道）'), findsOneWidget);
      expect(find.text('TokenForWeChatPage0123456789abcd'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('wechat.app-id')),
        'wx0123456789abcdef',
      );
      await tester.enterText(
        find.byKey(const Key('wechat.secret')),
        '0123456789abcdef0123456789abcdef',
      );
      await tester.ensureVisible(find.byKey(const Key('wechat.save')));
      await tester.tap(find.byKey(const Key('wechat.save')));
      await tester.pumpAndSettle();
      expect(
        posted['/api/v1/wechat/config']!['app_secret'],
        '0123456789abcdef0123456789abcdef',
      );
      // The secret field is cleared and only a hint comes back.
      expect(find.text('0123456789abcdef0123456789abcdef'), findsNothing);
      expect(find.byKey(const Key('wechat.tutorial')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('wechat.bind-mine')));
      await tester.tap(find.byKey(const Key('wechat.bind-mine')));
      await tester.pumpAndSettle();
      expect(find.text('482913'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets('member only sees their own binding, not the owner-only error', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var ownerCalls = 0;
    final snapshot = {
      ...blankState(),
      'device': {'id': 'phone', 'role': 'mobile'},
      'user': {'id': 'u2', 'username': 'shidi', 'role': 'member'},
    };
    final c = PlannerController(
      storage: MemoryStore(),
      transport: MockClient((request) async {
        final path = request.url.path;
        if (path == '/api/v1/wechat/config') ownerCalls++;
        final body = switch (path) {
          '/api/v1/snapshot' => snapshot,
          '/api/v1/assistant/config' => {'configured': false, 'key_hint': ''},
          '/api/v1/wechat/outbox' => {'messages': <Json>[]},
          '/api/v1/channels/bindings' => {'items': <Json>[]},
          '/api/v1/channels/wechat/bind-code' => {
            'code': '482913',
            'channel': 'wechat',
            'expires_at': '2026-10-19T16:10:00Z',
          },
          '/api/v1/app/latest' => {'version': '1.2.14+24'},
          _ => {},
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
    expect(find.text('这个接口暂时只对主账号开放'), findsNothing);
    expect(find.textContaining('只对主账号开放'), findsNothing);
    expect(find.byKey(const Key('wechat.tutorial')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('wechat.bind-mine')));
    await tester.tap(find.byKey(const Key('wechat.bind-mine')));
    await tester.pumpAndSettle();
    expect(find.text('482913'), findsOneWidget);
    expect(ownerCalls, 0);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
