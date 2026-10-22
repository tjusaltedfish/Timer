import 'package:flutter_test/flutter_test.dart';
import 'package:time_planner/controller.dart';

void main() {
  group('服务器地址规范化', () {
    test('公网地址的 http 自动升级为 https', () {
      expect(
        AuthSession.normalizeBaseUrl('http://timer.studydazi.top'),
        'https://timer.studydazi.top',
      );
      expect(
        AuthSession.normalizeBaseUrl(' http://timer.studydazi.top/ '),
        'https://timer.studydazi.top/',
      );
    });

    test('本机与局域网地址保持不变', () {
      expect(
        AuthSession.normalizeBaseUrl('http://127.0.0.1:8787'),
        'http://127.0.0.1:8787',
      );
      expect(
        AuthSession.normalizeBaseUrl('http://192.168.1.20:8787'),
        'http://192.168.1.20:8787',
      );
      expect(
        AuthSession.normalizeBaseUrl('http://10.25.154.5:8787'),
        'http://10.25.154.5:8787',
      );
    });

    test('已经是 https 的不动', () {
      expect(
        AuthSession.normalizeBaseUrl('https://timer.studydazi.top'),
        'https://timer.studydazi.top',
      );
    });
  });
}
