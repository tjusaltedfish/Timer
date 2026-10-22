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

/// Persists the device credential and local cache.
///
/// Neither storage path is allowed to decide whether an operation succeeds:
/// Android release packages have been seen with a plugin mismatch that made
/// every shared-preferences call throw `NoSuchMethodError`, and a secure
/// storage backend can fail on specific OEM keystores. Both are treated as
/// "cache unavailable" — the call still succeeds, the next request just
/// starts from the server instead of the local copy.
class DeviceStore implements LocalStore {
  static const _tokenKey = 'planner_token';
  static const _fallbackKey = 'planner_token_plain';
  final _secure = const FlutterSecureStorage();
  String? _webToken;
  String? _memoryToken;

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (error) {
      debugPrint('[store] shared preferences unavailable: ${error.runtimeType}');
      return null;
    }
  }

  @override
  Future<String?> read(String key) async {
    try {
      return (await _prefs())?.getString(key);
    } catch (error) {
      debugPrint('[store] read $key failed: ${error.runtimeType}');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await (await _prefs())?.setString(key, value);
    } catch (error) {
      debugPrint('[store] write $key failed: ${error.runtimeType}');
    }
  }

  // Browser testing keeps the credential in memory. Native devices use OS secure storage.
  @override
  Future<String?> readToken() async {
    if (kIsWeb) return _webToken ?? _memoryToken;
    if (_memoryToken != null) return _memoryToken;
    try {
      final value = await _secure.read(key: _tokenKey);
      if (value != null && value.isNotEmpty) {
        _memoryToken = value;
        return value;
      }
    } catch (error) {
      // 个别机型（尤其 release 包的 keystore 后端）会读不出密文；退回明文备份，
      // 至少不让「登录成功却进不去」这种事再发生。
      debugPrint('[store] secure read failed: ${error.runtimeType}: $error');
    }
    try {
      final value = (await _prefs())?.getString(_fallbackKey);
      if (value != null && value.isNotEmpty) _memoryToken = value;
      return value;
    } catch (error) {
      debugPrint('[store] plain read failed: ${error.runtimeType}: $error');
      return null;
    }
  }

  @override
  Future<void> writeToken(String token) async {
    _memoryToken = token;
    if (kIsWeb) {
      _webToken = token;
      return;
    }
    final prefs = await _prefs();
    try {
      await _secure.write(key: _tokenKey, value: token);
      // 系统加密存储写成功后清掉明文备份。
      try {
        if (prefs != null && prefs.containsKey(_fallbackKey)) {
          await prefs.remove(_fallbackKey);
        }
      } catch (_) {}
      return;
    } catch (error) {
      debugPrint('[store] secure write failed: ${error.runtimeType}: $error');
    }
    try {
      await prefs?.setString(_fallbackKey, token);
    } catch (error) {
      // 内存里已经有 token，本次会话照常可用；只是重启后要重新登录。
      debugPrint('[store] plain write failed: ${error.runtimeType}: $error');
    }
  }
}
