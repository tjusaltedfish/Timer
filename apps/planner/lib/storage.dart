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
  static const _stateKey = 'planner_local_state';
  final _secure = const FlutterSecureStorage();
  String? _webToken;
  String? _memoryToken;
  Map<String, String>? _values;

  /// 本机键值状态优先存进系统加密存储，不再依赖 shared_preferences：
  /// 部分 Android release 包上插件类版本错位，任何 prefs 调用都会抛
  /// `NoSuchMethodError`，表现为提醒开关、离线改动都存不下来。
  Future<Map<String, String>> _local() async {
    final cached = _values;
    if (cached != null) return cached;
    final loaded = <String, String>{};
    try {
      final raw = await _secure.read(key: _stateKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is String && value is String) loaded[key] = value;
          });
        }
      }
    } catch (error) {
      debugPrint('[store] local state read failed: ${error.runtimeType}: $error');
    }
    _values = loaded;
    return loaded;
  }

  Future<void> _persist(Map<String, String> values) async {
    _values = values;
    try {
      await _secure.write(key: _stateKey, value: jsonEncode(values));
    } catch (error) {
      debugPrint('[store] local state write failed: ${error.runtimeType}: $error');
    }
  }

  @override
  Future<String?> read(String key) async => (await _local())[key];

  @override
  Future<void> write(String key, String value) async {
    final values = Map<String, String>.from(await _local());
    values[key] = value;
    await _persist(values);
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
    final value = (await _local())[_fallbackKey];
    if (value != null && value.isNotEmpty) _memoryToken = value;
    return value;
  }

  @override
  Future<void> writeToken(String token) async {
    _memoryToken = token;
    if (kIsWeb) {
      _webToken = token;
      return;
    }
    try {
      await _secure.write(key: _tokenKey, value: token);
      // 系统加密存储写成功后清掉明文备份。
      final values = Map<String, String>.from(await _local());
      if (values.remove(_fallbackKey) != null) await _persist(values);
      return;
    } catch (error) {
      debugPrint('[store] secure write failed: ${error.runtimeType}: $error');
    }
    // 内存里已经有 token，本次会话照常可用；只是重启后要重新登录。
    final values = Map<String, String>.from(await _local());
    values[_fallbackKey] = token;
    await _persist(values);
  }
}
