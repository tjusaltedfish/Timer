part of '../controller.dart';

/// Outcome of checking a persisted token against `GET /api/v1/me`.
enum SessionStatus {
  /// The server accepted the token.
  valid,

  /// The server rejected the token (401): it must be discarded.
  expired,

  /// The server could not be reached; cached data keeps working offline.
  offline,
}

/// v2 account session: base address, bearer token and the signed-in user.
///
/// The token still lives in the existing [LocalStore] secure slot so desktop
/// single-user mode keeps working. Everything else (address, user, device) is
/// one small JSON record in the existing shared-preferences slot, which keeps
/// [PlannerController.serverUrl] compatible with older caches.
class AuthSession {
  AuthSession({required this.storage, required this.transport});

  static const defaultBaseUrl = 'http://127.0.0.1:8765';
  static const _recordKey = 'auth_session';
  static const _timeout = Duration(seconds: 10);

  final LocalStore storage;
  final http.Client transport;

  String baseUrl = defaultBaseUrl;
  String token = '';
  Json? user;
  Json? device;

  /// True once a record was read (even a token-less one written by logout),
  /// so the login page remembers the last server address.
  bool hasRecord = false;

  bool get authenticated => token.isNotEmpty;
  String? get userId => user?['id'] as String?;
  String? get username => user?['username'] as String?;
  String? get displayName =>
      user?['display_name'] as String? ?? user?['username'] as String?;

  /// Loads the last address/user plus the token from secure storage.
  Future<void> restore() async {
    final raw = await storage.read(_recordKey);
    if (raw != null) {
      try {
        final value = jsonDecode(raw) as Json;
        final storedUrl = value['base_url'] as String?;
        if (storedUrl != null && storedUrl.trim().isNotEmpty) {
          baseUrl = storedUrl.trim();
        }
        user = value['user'] as Json?;
        device = value['device'] as Json?;
        hasRecord = true;
      } catch (_) {
        // A damaged record must not block startup; fall back to defaults.
      }
    }
    token = await storage.readToken() ?? '';
  }

  /// Signs in and persists the token together with its server address.
  Future<void> login(String url, String username, String password) async {
    final value = await _send(
      url,
      'POST',
      '/api/v1/auth/login',
      {
        'username': username,
        'password': password,
        'device': {'name': '瞬时客户端', 'platform': _platform()},
      },
    );
    await _adoptCredentials(url, value);
  }

  /// Creates a fresh account on a server whose owner opened sign-ups, then
  /// adopts the session exactly like a login would.
  Future<void> register(
    String url,
    String username,
    String password, {
    String displayName = '',
  }) async {
    final value = await _send(url, 'POST', '/api/v1/auth/register', {
      'username': username,
      'password': password,
      'display_name': displayName,
      'device': {'name': '瞬时客户端', 'platform': _platform()},
    });
    await _adoptCredentials(url, value);
  }

  Future<void> _adoptCredentials(String url, Json value) async {
    final issued = value['token'] as String?;
    if (issued == null || issued.isEmpty) {
      throw ApiFailure('服务器没有返回登录令牌', 500);
    }
    baseUrl = url;
    token = issued;
    user = value['user'] as Json?;
    device = value['device'] as Json?;
    hasRecord = true;
    await storage.writeToken(token);
    await _persist();
  }

  /// Adopts a token obtained outside the v2 login flow (desktop-token file or
  /// the legacy pairing code) so both paths keep working.
  Future<void> adopt(String url, String value) async {
    baseUrl = url;
    token = value;
    hasRecord = true;
    await storage.writeToken(token);
    await _persist();
  }

  /// `GET /api/v1/me` refreshes the cached user. A 401 clears the session.
  Future<Json?> currentUser() async {
    if (!authenticated) return null;
    try {
      final value = await _send(baseUrl, 'GET', '/api/v1/me');
      user = value['user'] as Json? ?? user;
      device = value['device'] as Json? ?? device;
      await _persist();
      return user;
    } on ApiFailure catch (error) {
      if (error.status == 401) await clear();
      rethrow;
    }
  }

  /// Startup check: 200 → valid, 401 → expired, anything else → stay offline.
  Future<SessionStatus> verify() async {
    if (!authenticated) return SessionStatus.expired;
    try {
      await currentUser();
      return SessionStatus.valid;
    } on ApiFailure catch (error) {
      return error.status == 401
          ? SessionStatus.expired
          : SessionStatus.offline;
    } catch (_) {
      return SessionStatus.offline;
    }
  }

  /// Revokes the current device token server-side (best effort) and forgets
  /// the local credential. The cached address is kept for the next login.
  Future<void> logout() async {
    if (authenticated) {
      try {
        await _send(baseUrl, 'POST', '/api/v1/auth/logout', const {});
      } catch (_) {
        // Logging out must succeed locally even when the server is gone.
      }
    }
    await clear();
  }

  /// Switches the server address and drops the credential (401 is implicit:
  /// a token is only valid for the server that issued it).
  Future<void> changeServer(String url) async {
    baseUrl = url;
    await clear();
  }

  Future<void> clear() async {
    token = '';
    user = null;
    device = null;
    await storage.writeToken('');
    await _persist();
  }

  Future<void> _persist() => storage.write(
    _recordKey,
    jsonEncode({
      'base_url': baseUrl,
      if (user != null) 'user': user,
      if (device != null) 'device': device,
    }),
  );

  Future<Json> _send(
    String url,
    String method,
    String path, [
    Json? body,
  ]) async {
    final uri = Uri.parse('$url$path');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    http.Response response;
    try {
      response = await (method == 'GET'
              ? transport.get(uri, headers: headers)
              : transport.post(uri, headers: headers, body: jsonEncode(body)))
          .timeout(_timeout);
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw ApiFailure('连不上服务器，请检查地址和网络。', 0);
    }
    Json value;
    try {
      value = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
    } catch (_) {
      throw ApiFailure('服务器返回了无效响应。', response.statusCode);
    }
    if (response.statusCode >= 400) {
      throw ApiFailure(
        value['message'] as String? ?? '操作未完成，请检查输入或连接。',
        response.statusCode,
        code: value['code'] as String?,
      );
    }
    return value;
  }

  static String _platform() {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.windows => 'windows',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }
}
