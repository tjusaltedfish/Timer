import 'package:flutter_test/flutter_test.dart';
import 'package:time_planner/controller.dart';

void main() {
  Future<PlannerController> booted(String? savedToken) async {
    final c = PlannerController(storage: MemoryStore()..token = savedToken);
    await c.initialize();
    addTearDown(c.dispose);
    return c;
  }

  group('电脑启动时的 desktop-token', () {
    test('登录过账号后，重启不能把它换回本机主账号', () async {
      final c = await booted('zzxx-account-token');
      expect(c.desktopTokenApplies('desktop-token'), isFalse);
    });

    test('没登录过账号时，仍用它进入本机模式', () async {
      final c = await booted(null);
      expect(c.desktopTokenApplies('desktop-token'), isTrue);
    });

    test('上次用的就是它时，继续用它', () async {
      final c = await booted('desktop-token');
      expect(c.desktopTokenApplies('desktop-token'), isTrue);
    });

    test('命令行明确指定的令牌优先于保存的账号', () async {
      final c = await booted('zzxx-account-token');
      expect(c.desktopTokenApplies('fixture', explicit: true), isTrue);
    });

    test('没有令牌文件时不走本机模式', () async {
      final c = await booted(null);
      expect(c.desktopTokenApplies(null), isFalse);
      expect(c.desktopTokenApplies(''), isFalse);
    });
  });
}
