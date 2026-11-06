import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';

/// 聊天里的撤回、修改、删除：入口在每条消息下方，手机上不用长按也找得到。
void main() {
  late List<Json> messages;
  late List<String> calls;
  String? editedText;
  String? refusal;

  Json message(String id, String role, String text, [List<Json>? drafts]) => {
    'id': id,
    'role': role,
    'text': text,
    'created_at': '2026-10-19T16:00:00Z',
    'meme': '',
    'drafts': drafts ?? <Json>[],
  };

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  final user = <String, dynamic>{
    'id': 'u1',
    'username': 'alice',
    'display_name': 'Alice',
    'role': 'member',
    'onboarding': {
      'version': 2,
      'step': 10,
      'done': <String>['welcome', 'finish'],
      'skipped': <String>[],
    },
  };

  MockClient backend() => MockClient((request) async {
    final path = request.url.path;
    final action = RegExp(
      r'^/api/v1/assistant/messages/([^/]+)/(\w+)$',
    ).firstMatch(path);
    if (action != null) {
      final id = action[1]!, verb = action[2]!;
      calls.add('$verb:$id');
      if (refusal != null) return json({'message': refusal}, 409);
      final at = messages.indexWhere((m) => m['id'] == id);
      if (verb == 'delete') {
        messages.removeAt(at);
        return json({'deleted': true});
      }
      messages.removeRange(at, at + 2);
      if (verb == 'withdraw') return json({'withdrawn': true, 'undone': 1});
      editedText = (jsonDecode(request.body) as Json)['text'] as String;
      messages
        ..add(message('new', 'user', editedText!))
        ..add(message('new-reply', 'assistant', '改好了。'));
      return json({'messages': messages.sublist(messages.length - 2)});
    }
    return json(switch (path) {
      '/api/v1/me' => {
        'user': user,
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
      '/api/v1/assistant/messages' => {'messages': messages},
      _ => <Json>{},
    });
  });

  Future<PlannerController> open(WidgetTester tester) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStore()..token = 'tok-1';
    storage.values['auth_session'] = jsonEncode({
      'base_url': 'http://127.0.0.1:8787',
      'user': user,
      'device': {'id': 'd1', 'name': '瞬时客户端', 'role': 'mobile'},
    });
    final c = PlannerController(storage: storage, transport: backend());
    await c.initialize();
    await tester.pumpWidget(PlannerApp(controller: c, requireLogin: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> close(WidgetTester tester, PlannerController c) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> menu(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('message.menu.$id')));
    await tester.pumpAndSettle();
  }

  setUp(() {
    calls = [];
    editedText = null;
    refusal = null;
    messages = [
      message('m1', 'user', '第一句'),
      message('r1', 'assistant', '好的。'),
      message('m2', 'user', '排到下午两点'),
      message('r2', 'assistant', '排好了。', [
        {
          'id': 'd2',
          'summary': '排一段',
          'status': 'applied',
          'lines': ['14:00 实验'],
          'undoable': true,
        },
      ]),
    ];
  });

  testWidgets('只有最后一条自己的消息能修改，助手的话只能删除', (tester) async {
    final c = await open(tester);

    await menu(tester, 'm2');
    expect(find.byKey(const Key('message.withdraw')), findsOneWidget);
    expect(find.byKey(const Key('message.edit')), findsOneWidget);
    expect(find.byKey(const Key('message.delete')), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await menu(tester, 'm1');
    expect(find.byKey(const Key('message.withdraw')), findsOneWidget);
    expect(find.byKey(const Key('message.edit')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await menu(tester, 'r2');
    expect(find.byKey(const Key('message.withdraw')), findsNothing);
    expect(find.byKey(const Key('message.edit')), findsNothing);
    expect(find.byKey(const Key('message.delete')), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await close(tester, c);
  });

  testWidgets('撤回前说清楚会连改动一起撤，确认后消息消失', (tester) async {
    final c = await open(tester);
    await menu(tester, 'm2');
    await tester.tap(find.byKey(const Key('message.withdraw')));
    await tester.pumpAndSettle();
    expect(find.textContaining('改动会一起撤销'), findsOneWidget);
    await tester.tap(find.byKey(const Key('message.confirm')));
    await tester.pumpAndSettle();

    expect(calls, ['withdraw:m2']);
    expect(find.text('排到下午两点'), findsNothing);
    expect(find.text('排好了。'), findsNothing);
    expect(find.text('第一句'), findsOneWidget);
    await close(tester, c);
  });

  testWidgets('取消撤回什么都不发生', (tester) async {
    final c = await open(tester);
    await menu(tester, 'm2');
    await tester.tap(find.byKey(const Key('message.withdraw')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.text('排到下午两点'), findsOneWidget);
    await close(tester, c);
  });

  testWidgets('撤回失败时消息还在，并说明原因', (tester) async {
    refusal = '之后日程又有变化，没法整体撤销';
    final c = await open(tester);
    await menu(tester, 'm2');
    await tester.tap(find.byKey(const Key('message.withdraw')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message.confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('没法整体撤销'), findsOneWidget);
    expect(find.text('排到下午两点'), findsOneWidget);
    await close(tester, c);
  });

  testWidgets('删除只去掉这一条', (tester) async {
    final c = await open(tester);
    await menu(tester, 'r1');
    await tester.tap(find.byKey(const Key('message.delete')));
    await tester.pumpAndSettle();
    expect(find.textContaining('日程不会变'), findsOneWidget);
    await tester.tap(find.byKey(const Key('message.confirm')));
    await tester.pumpAndSettle();

    expect(calls, ['delete:r1']);
    expect(find.text('好的。'), findsNothing);
    expect(find.text('第一句'), findsOneWidget);
    await close(tester, c);
  });

  testWidgets('修改时带着原文，改完重新发给助手', (tester) async {
    final c = await open(tester);
    await menu(tester, 'm2');
    await tester.tap(find.byKey(const Key('message.edit')));
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('message.edit.field'));
    expect(tester.widget<TextField>(field).controller!.text, '排到下午两点');
    await tester.enterText(field, '排到下午四点');
    await tester.tap(find.byKey(const Key('message.edit.send')));
    await tester.pumpAndSettle();

    expect(calls, ['edit:m2']);
    expect(editedText, '排到下午四点');
    expect(find.text('排到下午四点'), findsOneWidget);
    expect(find.text('改好了。'), findsOneWidget);
    expect(find.text('排到下午两点'), findsNothing);
    await close(tester, c);
  });

  testWidgets('内容没改就不重新发送', (tester) async {
    final c = await open(tester);
    await menu(tester, 'm2');
    await tester.tap(find.byKey(const Key('message.edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message.edit.send')));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await close(tester, c);
  });
}
