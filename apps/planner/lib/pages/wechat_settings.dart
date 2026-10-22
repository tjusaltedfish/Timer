part of '../home.dart';

/// WeChat official-account test account: credentials, the Token to paste into
/// WeChat, binding the main account, and recent delivery states. The shared
/// bot credentials are editable on the computer only; every member can see the
/// binding steps and bind their own WeChat from the phone.
class WechatSettingsPanel extends StatefulWidget {
  const WechatSettingsPanel({super.key, required this.controller});
  final PlannerController controller;
  @override
  State<WechatSettingsPanel> createState() => _WechatSettingsState();
}

class _WechatSettingsState extends State<WechatSettingsPanel> {
  final appId = TextEditingController(),
      secret = TextEditingController(),
      template = TextEditingController();
  Json? config;
  List<Json> outbox = [];
  List<Json> bindings = [];
  Json? bindCode;
  String? note;
  bool busy = false, loaded = false;
  PlannerController get c => widget.controller;
  bool get desktop => c.state['device']?['role'] == 'desktop';
  // 公众号本身（AppID/Token）是站长在电脑上配的；普通成员只看自己的绑定。
  bool get owner => (c.state['user']?['role'] ?? 'admin') == 'admin';
  bool get mine =>
      bindings.any((item) => item['channel'] == 'wechat') ||
      config?['bound'] == true;

  static const statusLabels = {
    'queued': '排队中',
    'sending': '发送中',
    'sent': '已发出',
    'failed': '没发出去',
    'unknown': '不确定是否送达',
    'expired': '已过期',
    'cancelled': '已撤下',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final field in [appId, secret, template]) {
      field.dispose();
    }
    super.dispose();
  }

  void _fill(Json value) {
    config = value;
    appId.text = value['app_id'] ?? '';
    template.text = value['template_id'] ?? '';
    secret.clear();
  }

  Future<void> _load() async {
    if (!c.configured) {
      setState(() => loaded = true);
      return;
    }
    if (!owner) {
      try {
        final linked = await c.channelBindings();
        if (mounted) {
          setState(() {
            bindings = linked;
            loaded = true;
          });
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            note = error.toString();
            loaded = true;
          });
        }
      }
      return;
    }
    try {
      final value = await c.wechatConfig();
      final messages = desktop ? await c.wechatOutbox() : <Json>[];
      final linked = await c.channelBindings();
      if (mounted) {
        setState(() {
          _fill(value);
          outbox = messages;
          bindings = linked;
        });
      }
    } catch (error) {
      if (mounted) setState(() => note = error.toString());
    } finally {
      if (mounted) setState(() => loaded = true);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      note = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => note = error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save({bool regenerate = false}) => _run(() async {
    final value = await c.saveWechatConfig({
      'app_id': appId.text.trim(),
      if (secret.text.trim().isNotEmpty) 'app_secret': secret.text.trim(),
      'template_id': template.text.trim(),
      if (regenerate) 'regenerate_token': true,
    });
    if (!mounted) return;
    setState(() {
      _fill(value);
      note = regenerate ? '已换了新的 Token，记得同步更新到测试号页面的「接口配置信息」。' : '已保存在这台电脑上。';
    });
  });

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => note = '已复制$what。');
  }

  Future<void> _newCode() => _run(() async {
    final value = await c.channelBindCode('wechat');
    final linked = await c.channelBindings();
    if (!mounted) return;
    setState(() {
      bindCode = value;
      bindings = linked;
    });
  });

  Future<void> _unbindMine() => _run(() async {
    await c.channelUnbind('wechat');
    final linked = await c.channelBindings();
    if (mounted) setState(() => bindings = linked);
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = config?['configured'] == true;
    final bound = mine;
    return SizedBox(
      width: double.infinity,
      child: InkCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('微信助手（旧通道）', style: theme.textTheme.titleMedium),
                ),
                if (bound) const Seal('联', label: '已绑定微信'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              !c.configured
                  ? '连接账号后，在电脑端设置公众号测试号；手机也能绑定自己的微信。'
                  : bound
                  ? '已绑定你的微信，在测试号对话里就能安排和反馈。'
                  : !owner
                  ? '公众号由站长配置好了。这里只负责绑定你自己的微信。'
                  : ready
                  ? '测试号已填好，还差绑定你的微信。'
                  : '用公众号测试号和助手对话：电脑锁屏也能收发，改日程前都会先给你拟办。',
              style: theme.textTheme.bodySmall,
            ),
            if (!loaded)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (c.configured && loaded) ...[
              const SizedBox(height: 16),
              Text(
                '绑定步骤',
                key: const Key('wechat.tutorial'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              for (final (i, step) in const [
                '微信里搜索并关注测试号（管理员给的二维码，或测试号页面上的二维码）',
                '点下面「生成绑定码」，记下 6 位码',
                '在测试号的对话里把这 6 位码发出去',
                '收到「绑定好了」就完成了；之后在对话里发消息，就是跟你的助手说话',
              ].indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${i + 1}. $step',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    key: const Key('wechat.bind-mine'),
                    onPressed: busy ? null : _newCode,
                    child: Text(bound ? '换一个绑定码' : '生成绑定码'),
                  ),
                  OutlinedButton(
                    key: const Key('wechat.refresh'),
                    onPressed: busy
                        ? null
                        : () => _run(() async {
                            final linked = await c.channelBindings();
                            final value = owner
                                ? await c.wechatConfig()
                                : null;
                            if (mounted) {
                              setState(() {
                                if (value != null) _fill(value);
                                bindings = linked;
                              });
                            }
                          }),
                    child: const Text('刷新状态'),
                  ),
                  if (bound)
                    TextButton(
                      key: const Key('wechat.unbind-mine'),
                      onPressed: busy ? null : _unbindMine,
                      child: const Text('解除绑定'),
                    ),
                ],
              ),
              if (bindCode != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Material(
                    color: context.inkPalette.wash,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            '${bindCode!['code'] ?? ''}',
                            style: const TextStyle(
                              fontFamily: 'WenKai',
                              fontSize: 30,
                              letterSpacing: 6,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '把 6 位码发到测试号对话里，10 分钟内有效；绑定后只回应你的微信号。',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
            if (c.configured && loaded && owner) ...[
              const SizedBox(height: 16),
              TextField(
                key: const Key('wechat.app-id'),
                controller: appId,
                decoration: const InputDecoration(
                  labelText: 'appID',
                  hintText: '测试号页面上的 appID，wx 开头',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('wechat.secret'),
                controller: secret,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'appsecret',
                  hintText: (config?['secret_hint'] ?? '').isEmpty
                      ? '测试号页面上的 appsecret'
                      : '已保存 ${config!['secret_hint']}，留空则不改',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('wechat.template'),
                controller: template,
                decoration: const InputDecoration(
                  labelText: '提醒模板 ID（可不填）',
                  hintText: '超过 48 小时没互动时，提醒改用这个模板发送',
                ),
              ),
              const SizedBox(height: 14),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('主动提醒与日终收尾'),
                subtitle: const Text('新增待办、进入专注、到点问结果和等待检查点。超过互动窗口时需要配置模板。'),
                value: config?['proactive_enabled'] as bool? ?? true,
                onChanged: busy
                    ? null
                    : (value) => _run(() async {
                        final updated = await c.saveWechatConfig({
                          'proactive_enabled': value,
                        });
                        if (mounted) setState(() => config = updated);
                      }),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    key: const Key('wechat.save'),
                    onPressed: busy ? null : _save,
                    child: Text(busy ? '请稍候…' : '保存'),
                  ),
                  OutlinedButton(
                    onPressed: busy || !bound
                        ? null
                        : () => _run(() async {
                            await c.wechatTest();
                            await Future<void>.delayed(
                              const Duration(seconds: 2),
                            );
                            final messages = await c.wechatOutbox();
                            if (mounted) setState(() => outbox = messages);
                          }),
                    child: const Text('发一条测试消息'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text('填到测试号「接口配置信息」里', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              _CopyRow(
                label: 'URL',
                value:
                    'https://你的域名${config?['callback_path'] ?? '/wechat/callback'}',
                onCopy: () => _copy(
                  config?['callback_path'] ?? '/wechat/callback',
                  '回调路径',
                ),
              ),
              _CopyRow(
                label: 'Token',
                value: config?['token'] ?? '',
                onCopy: () => _copy(config?['token'] ?? '', ' Token'),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: busy ? null : () => _save(regenerate: true),
                  child: const Text('换一个 Token'),
                ),
              ),
              if (outbox.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('最近发出的消息', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                for (final message in outbox.take(5))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${statusLabels[message['status']] ?? message['status']}'
                      '${message['channel'] == 'template' ? '（模板）' : ''}'
                      ' · ${message['text']}'
                      '${message['last_error'] == null ? '' : '\n    ${message['last_error']}'}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ],
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(note!, style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });
  final String label, value;
  final VoidCallback onCopy;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 52,
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: SelectableText(
          value,
          maxLines: 1,
          style: const TextStyle(fontSize: 13.5),
        ),
      ),
      IconButton(
        tooltip: '复制$label',
        onPressed: onCopy,
        icon: const Icon(Icons.copy_outlined, size: 18),
      ),
    ],
  );
}
