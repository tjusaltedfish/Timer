part of 'controller.dart';

abstract class LocalStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<String?> readToken();
  Future<void> writeToken(String token);
}

class MemoryStore implements LocalStore {
  final values = <String, String>{};
  String? token;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> readToken() async => token;
  @override
  Future<void> writeToken(String value) async {
    token = value;
  }
}

class DeviceStore implements LocalStore {
  final _secure = const FlutterSecureStorage();
  String? _webToken;
  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String key, String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, value)) {
      throw StateError('本地记录保存失败，请检查设备空间');
    }
  }

  // Browser testing keeps the credential in memory. Native devices use OS secure storage.
  @override
  Future<String?> readToken() async =>
      kIsWeb ? _webToken : _secure.read(key: 'planner_token');
  @override
  Future<void> writeToken(String token) async {
    if (kIsWeb) {
      _webToken = token;
    } else {
      await _secure.write(key: 'planner_token', value: token);
    }
  }
}
