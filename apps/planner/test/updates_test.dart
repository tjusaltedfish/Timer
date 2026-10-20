import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';
import 'package:time_planner/updates.dart';

class FakePlatform implements UpdatePlatform {
  FakePlatform({this.allowed = true});
  bool allowed;
  final files = <String, List<int>>{};
  final installed = <String>[];
  var openedSettings = 0;
  @override
  bool get supported => true;
  @override
  Future<String> downloadDir() async => '/cache/updates';
  @override
  Future<void> save(String path, Stream<List<int>> bytes) async {
    files[path] = [await for (final chunk in bytes) ...chunk];
  }

  @override
  Future<String> sha256(String path) async => sha256Of(files[path]!);
  @override
  Future<void> delete(String path) async => files.remove(path);
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<void> openInstallSettings() async => openedSettings++;
  @override
  Future<void> install(String path) async => installed.add(path);
}

/// Stand-in digest for the fake platform; the real one is SHA-256 in Kotlin.
String sha256Of(List<int> bytes) =>
    'len${bytes.length}-sum${bytes.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff)}';

final apk = utf8.encode('pretend apk ' * 500);

Json release({int build = 5, int minBuild = 0, String? digest}) => {
  'version': '1.0.0+$build',
  'name': '1.0.0',
  'build': build,
  'size': apk.length,
  'sha256': digest ?? sha256Of(apk),
  'min_build': minBuild,
  'published_at': '2026-10-20T03:00:00+00:00',
};

Future<PlannerController> connected(Json latest, {List<int>? body}) async {
  final c = PlannerController(
    storage: MemoryStore(),
    transport: MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer phone-token');
      return switch (request.url.path) {
        '/api/v1/snapshot' => http.Response(
          jsonEncode({
            ...blankState(),
            'server_version': '1.0.0+5',
            'app_latest': latest,
            'device': {'id': 'p1', 'role': 'phone'},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
        '/api/v1/app/latest' => http.Response(jsonEncode(latest), 200),
        '/api/v1/app/download' => http.Response.bytes(body ?? apk, 200),
        _ => http.Response('{}', 404),
      };
    }),
  );
  await c.initialize();
  await c.connect('https://timer.example', 'phone-token');
  return c;
}

void main() {
  test('versions parse and compare by build number', () {
    expect(AppVersion.parse('1.2.3+45').build, 45);
    expect(AppVersion.parse('1.2.3').build, 0);
    expect(AppVersion.parse(null).toString(), '0.0.0+0');
  });

  test('a newer published build is offered; an older one is not', () async {
    final c = await connected(release(build: 5));
    final newer = UpdateService(
      controller: c,
      platform: FakePlatform(),
      current: AppVersion.parse('1.0.0+4'),
    );
    expect(newer.available, isTrue);
    expect(newer.required, isFalse);
    final same = UpdateService(
      controller: c,
      platform: FakePlatform(),
      current: AppVersion.parse('1.0.0+5'),
    );
    await same.check();
    expect(same.available, isFalse);
    expect(same.status, '已是最新版本');
    final required = UpdateService(
      controller: await connected(release(build: 6, minBuild: 6)),
      platform: FakePlatform(),
      current: AppVersion.parse('1.0.0+5'),
    );
    expect(required.required, isTrue);
  });

  test('a verified download goes to the installer', () async {
    final platform = FakePlatform();
    final u = UpdateService(
      controller: await connected(release()),
      platform: platform,
      current: AppVersion.parse('1.0.0+4'),
    );
    await u.downloadAndInstall();
    expect(u.problem, isNull);
    expect(platform.installed, ['/cache/updates/timer-1.0.0-5.apk']);
    expect(platform.files.values.single, apk);
  });

  test('a corrupted download is deleted and never installed', () async {
    final platform = FakePlatform();
    final u = UpdateService(
      controller: await connected(release(), body: utf8.encode('truncated')),
      platform: platform,
      current: AppVersion.parse('1.0.0+4'),
    );
    await u.downloadAndInstall();
    expect(u.problem, contains('校验失败'));
    expect(platform.installed, isEmpty);
    expect(platform.files, isEmpty);
  });

  test(
    'without install permission the user is sent to system settings',
    () async {
      final platform = FakePlatform(allowed: false);
      final u = UpdateService(
        controller: await connected(release()),
        platform: platform,
        current: AppVersion.parse('1.0.0+4'),
      );
      await u.downloadAndInstall();
      expect(platform.openedSettings, 1);
      expect(platform.installed, isEmpty);
      expect(u.problem, contains('允许'));
    },
  );

  testWidgets('the home shows the update bar only when a newer build waits', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    final c = await connected(release(build: 5));
    final u = UpdateService(
      controller: c,
      platform: FakePlatform(),
      current: AppVersion.parse('1.0.0+4'),
    );
    await tester.pumpWidget(PlannerApp(controller: c, updates: u));
    await tester.pump();
    expect(find.byKey(const Key('update.banner')), findsOneWidget);
    expect(find.text('有新版本 1.0.0+5'), findsOneWidget);
    expect(find.text('下载并安装'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final current = UpdateService(
      controller: c,
      platform: FakePlatform(),
      current: AppVersion.parse('1.0.0+5'),
    );
    await tester.pumpWidget(PlannerApp(controller: c, updates: current));
    await tester.pump();
    expect(find.byKey(const Key('update.banner')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
