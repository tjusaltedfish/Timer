import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../theme/tokens.dart';
import '../widgets/ink_card.dart';
import '../widgets/paper_background.dart';
import '../widgets/seal.dart';

/// v2 account gate: server address, username, password.
///
/// A second mode turns the same card into self-service registration: the owner
/// opens sign-ups in the admin console (or the server is brand new) and the
/// person can pick their own username and password.
///
/// The caret submits the form; [SingleChildScrollView] plus the default
/// `resizeToAvoidBottomInset` keeps the fields above the soft keyboard.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.controller});
  final PlannerController controller;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _url = TextEditingController(
    text: widget.controller.serverUrl,
  );
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();
  bool _busy = false;
  bool _registerMode = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    _confirm.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  void _toggleMode() {
    if (_busy) return;
    setState(() {
      _registerMode = !_registerMode;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final url = _url.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    final invalid = switch ((url.isEmpty, username.isEmpty, password.isEmpty)) {
      (true, _, _) => '请填写服务器地址',
      (_, true, _) => '请填写用户名',
      (_, _, true) => '请填写密码',
      _ => _registerMode && _confirm.text != password ? '两次输入的密码不一样' : null,
    };
    if (invalid == null && _registerMode && password.length < 10) {
      setState(
        () => _error = '密码至少 10 位（字母、数字或符号都行）',
      );
      return;
    }
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_registerMode) {
        await widget.controller.register(
          url,
          username,
          password,
          displayName: _displayName.text,
        );
      } else {
        await widget.controller.login(url, username, password);
      }
      TextInput.finishAutofillContext();
      // The gate swaps this page for the planner on the next notification.
    } on ApiFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _describe(error);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '连不上服务器，请检查地址和网络。';
      });
    }
  }

  String _describe(ApiFailure error) {
    final code = error.code;
    return switch (code) {
      'INVALID_CREDENTIALS' => '用户名或密码不对（$code）',
      'AUTH_FAILED' => '用户名或密码不对（$code）',
      'RATE_LIMITED' => '尝试太频繁，请稍后再试（$code）',
      'ACCOUNT_DISABLED' => '账号已停用，请联系站长（$code）',
      'REGISTRATION_CLOSED' => '这个服务器还没开注册，请让站长在电脑上开一下。',
      'USERNAME_TAKEN' => '这个用户名已经有人用了，换一个。',
      'WEAK_PASSWORD' => '密码至少 10 位，再长一点。',
      'INVALID_USERNAME' => '用户名用 2–24 位字母、数字、下划线或短横线。',
      _ => code == null ? error.message : '${error.message}（$code）',
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.inkPalette;
    return Scaffold(
      body: PaperBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: Seal('瞬', label: '瞬时', size: 42)),
                      const SizedBox(height: 20),
                      Text(
                        '瞬时',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2,
                          color: palette.inkJiao,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _registerMode
                            ? '自己开一个账号，安排在多台设备之间同步。'
                            : '登录你的账号，安排在多台设备之间同步。',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: palette.inkZhong),
                      ),
                      const SizedBox(height: 26),
                      InkCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              key: const Key('login.server-url'),
                              controller: _url,
                              enabled: !_busy,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                labelText: '服务器地址',
                                hintText: 'https://timer.example.com',
                              ),
                              onSubmitted: (_) => _usernameFocus.requestFocus(),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              key: const Key('login.username'),
                              controller: _username,
                              focusNode: _usernameFocus,
                              enabled: !_busy,
                              autofillHints: const [AutofillHints.username],
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                labelText: '用户名',
                                helperText: '2–24 位字母、数字、下划线或短横线',
                              ),
                              onSubmitted: (_) => _passwordFocus.requestFocus(),
                            ),
                            if (_registerMode) ...[
                              const SizedBox(height: 14),
                              TextField(
                                key: const Key('login.display-name'),
                                controller: _displayName,
                                enabled: !_busy,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: '你的名字（可留空）',
                                ),
                                onSubmitted: (_) =>
                                    _passwordFocus.requestFocus(),
                              ),
                            ],
                            const SizedBox(height: 14),
                            TextField(
                              key: const Key('login.password'),
                              controller: _password,
                              focusNode: _passwordFocus,
                              enabled: !_busy,
                              obscureText: true,
                              autofillHints: _registerMode
                                  ? const [AutofillHints.newPassword]
                                  : const [AutofillHints.password],
                              textInputAction: _registerMode
                                  ? TextInputAction.next
                                  : TextInputAction.done,
                              onSubmitted: (_) => _registerMode
                                  ? _confirmFocus.requestFocus()
                                  : _submit(),
                              decoration: InputDecoration(
                                labelText: '密码',
                                helperText: _registerMode ? '至少 10 位' : null,
                              ),
                            ),
                            if (_registerMode) ...[
                              const SizedBox(height: 14),
                              TextField(
                                key: const Key('login.password-confirm'),
                                controller: _confirm,
                                focusNode: _confirmFocus,
                                enabled: !_busy,
                                obscureText: true,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _submit(),
                                decoration: const InputDecoration(
                                  labelText: '再输一次密码',
                                ),
                              ),
                            ],
                            if (_error != null) ...[
                              const SizedBox(height: 14),
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                  _error!,
                                  key: const Key('login.error'),
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 22),
                            SizedBox(
                              height: 48,
                              child: FilledButton(
                                key: const Key('login.submit'),
                                onPressed: _busy ? null : _submit,
                                child: _busy
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.8,
                                        ),
                                      )
                                    : Text(_registerMode ? '注册并进入' : '登录'),
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextButton(
                              key: const Key('login.toggle-mode'),
                              onPressed: _busy ? null : _toggleMode,
                              child: Text(
                                _registerMode ? '已有账号？去登录' : '没有账号？自己注册',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: palette.inkZhong,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _registerMode
                            ? '如果服务器已经有账号，注册开关要站长在电脑上打开。'
                            : '账号由站长在服务器上创建；忘记密码请联系站长。',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: palette.inkDan),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
