import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../theme/tokens.dart';
import '../widgets/ink_card.dart';
import '../widgets/paper_background.dart';
import '../widgets/seal.dart';

/// v2 account sign-in: server address, username, password.
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
  final _password = TextEditingController();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final url = _url.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    final invalid = switch ((
      url.isEmpty,
      username.isEmpty,
      password.isEmpty,
    )) {
      (true, _, _) => '请填写服务器地址',
      (_, true, _) => '请填写用户名',
      (_, _, true) => '请填写密码',
      _ => null,
    };
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.login(url, username, password);
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
      'RATE_LIMITED' => '尝试太频繁，请稍后再试（$code）',
      'ACCOUNT_DISABLED' => '账号已停用，请联系站长（$code）',
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
                        '登录你的账号，安排在多台设备之间同步。',
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
                                hintText: 'http://127.0.0.1:8765',
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
                              ),
                              onSubmitted: (_) => _passwordFocus.requestFocus(),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              key: const Key('login.password'),
                              controller: _password,
                              focusNode: _passwordFocus,
                              enabled: !_busy,
                              obscureText: true,
                              autofillHints: const [AutofillHints.password],
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _submit(),
                              decoration: const InputDecoration(
                                labelText: '密码',
                              ),
                            ),
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
                                    : const Text('登录'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '账号由站长在服务器上创建；忘记密码请联系站长。',
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
