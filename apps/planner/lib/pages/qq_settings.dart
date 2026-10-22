part of '../home.dart';

/// QQ 官方机器人：填 AppID/AppSecret、生成绑定码、发测试消息、看最近的发送
/// 队列。凭据只能在电脑端编辑，手机端只读；AppSecret 从不回显。
class QqSettingsPanel extends StatefulWidget {
  const QqSettingsPanel({super.key, required this.controller});
  final PlannerController controller;
  @override
  State<QqSettingsPanel> createState() => _QqSettingsState();
}

class _QqSettingsState extends State<QqSettingsPanel> {
  final appId = TextEditingController(), secret = TextEditingController();
  Json? config;
  List<Json> outbox = [];
  Json? bindCode;
  List<Json> bindings = [];
  String? note;
  bool busy = false, loaded = false;
  PlannerController get c => widget.controller;
  bool get desktop => c.state['device']?['role'] == 'desktop';
  // QQ 机器人的凭据同样是站长在电脑上配的。
  bool get owner => (c.state['user']?['role'] ?? 'admin') == 'admin';

  /// 当前账号自己绑定的那条 QQ（人人都有，不只是站长）。
  Json? get mine {
    for (final item in bindings) {
      if (item['channel'] == 'qq') return item;
    }
    return null;
  }

  bool get boundMine => mine != null;

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
    for (final field in [appId, secret]) {
      field.dispose();
    }
    super.dispose();
  }

  void _fill(Json value) {
    config = value;
    appId.text = value['app_id'] ?? '';
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
      final value = await c.qqConfig();
      final messages = desktop ? await c.qqOutbox() : <Json>[];
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

  String _moment(Object? iso) {
    if (iso is! String || iso.isEmpty) return '';
    final value = DateTime.tryParse(iso)?.toLocal();
    return value == null ? '' : '${value.month}月${value.day}日 ${hm(value)}';
  }

  Future<void> _refreshMine() async {
    final linked = await c.channelBindings();
    if (mounted) setState(() => bindings = linked);
  }

  Future<void> _newCodeMine() => _run(() async {
    final value = await c.channelBindCode('qq');
    final linked = await c.channelBindings();
    if (!mounted) return;
    setState(() {
      bindCode = value;
      bindings = linked;
    });
  });

  Future<void> _unbindMine() => _run(() async {
    await c.channelUnbind('qq');
    final linked = await c.channelBindings();
    if (!mounted) return;
    setState(() {
      bindings = linked;
      bindCode = null;
    });
  });

  Future<void> _save() => _run(() async {
    await c.saveQqConfig({
      'app_id': appId.text.trim(),
      if (secret.text.trim().isNotEmpty) 'app_secret': secret.text.trim(),
    });
    final value = await c.qqConfig();
    if (!mounted) return;
    setState(() {
      _fill(value);
      note = '已保存';
    });
  });

  Future<void> _test() => _run(() async {
    await c.qqTest();
    final messages = desktop ? await c.qqOutbox() : <Json>[];
    if (!mounted) return;
    setState(() {
      outbox = messages;
      note = '已经排队，几秒内看 QQ';
    });
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = config?['configured'] == true;
    final bound = config?['bound'] == true;
    final hint = '${config?['secret_hint'] ?? ''}';
    return SizedBox(
      width: double.infinity,
      child: InkCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('QQ 助手（聊天入口）', style: theme.textTheme.titleMedium),
                ),
                if (bound) const Seal('Q', label: '已绑定 QQ'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              owner
                  ? '在 QQ 开放平台创建机器人后，把 AppID 和 AppSecret 填到这里。绑定后就能在 QQ 里跟助手说话，日程提醒也会发到 QQ。'
                  : '机器人由站长配置好了。这里只负责绑定你自己的 QQ，绑定后在 QQ 里就能安排日程。',
              style: theme.textTheme.bodySmall,
            ),
            if (!c.configured)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('连接电脑后，在电脑端设置。', style: theme.textTheme.bodySmall),
              ),
            if (loaded && config?['configured'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  config?['connected'] == true
                      ? 'QQ 通道：已连接'
                      : 'QQ 通道：未连接（后台正在重连，或 AppID/AppSecret 还没生效）',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (!loaded)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (c.configured && loaded && owner) ...[
              const SizedBox(height: 16),
              TextField(
                key: const Key('qq.app-id'),
                controller: appId,
                obscureText: false,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'AppID',
                  hintText: 'QQ 开放平台上机器人资料里的 AppID（一串数字）',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('qq.secret'),
                controller: secret,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'AppSecret',
                  hintText: hint.isEmpty
                      ? 'QQ 开放平台上机器人资料里的 AppSecret'
                      : '已保存 $hint',
                ),
              ),
              const SizedBox(height: 4),
              Text('AppSecret 留空表示不修改。', style: theme.textTheme.bodySmall),
              const SizedBox(height: 10),
              SwitchListTile(
                key: const Key('qq.proactive'),
                contentPadding: EdgeInsets.zero,
                title: const Text('到点提醒发到 QQ'),
                subtitle: const Text('日程到点时，提醒也会发到这个 QQ。'),
                value: config?['proactive_enabled'] as bool? ?? true,
                onChanged: busy
                    ? null
                    : (value) => _run(() async {
                        final updated = await c.saveQqConfig({
                          'proactive_enabled': value,
                        });
                        if (mounted) setState(() => config = updated);
                      }),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    key: const Key('qq.save'),
                    onPressed: busy ? null : _save,
                    child: Text(busy ? '请稍候…' : '保存'),
                  ),
                  if (!bound && ready)
                    OutlinedButton(
                      key: const Key('qq.bind-code'),
                      onPressed: busy
                          ? null
                          : () => _run(() async {
                              final code = await c.qqBindCode();
                              if (mounted) setState(() => bindCode = code);
                            }),
                      child: const Text('生成绑定码'),
                    ),
                  OutlinedButton(
                    key: const Key('qq.test'),
                    onPressed: busy || !ready || !bound ? null : _test,
                    child: const Text('发一条测试消息'),
                  ),
                  if (bound)
                    TextButton(
                      key: const Key('qq.unbind'),
                      onPressed: busy
                          ? null
                          : () => _run(() async {
                              final value = await c.qqUnbind();
                              if (mounted) {
                                setState(() {
                                  config = {...?config, ...value};
                                  bindCode = null;
                                });
                              }
                            }),
                      child: const Text('解除绑定'),
                    ),
                ],
              ),
              if (!bound && ready && bindCode == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '6 位数字，10 分钟内有效',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (bound)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '已绑定 ${config?['bound_hint'] ?? ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (!bound && ready && (config?['bind_hint'] ?? '') != '')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${config!['bind_hint']}',
                    style: theme.textTheme.bodySmall,
                  ),
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
                            bindCode!['code'],
                            style: const TextStyle(
                              fontFamily: 'WenKai',
                              fontSize: 30,
                              letterSpacing: 6,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '在 QQ 里找到这个机器人，给它发这句 6 位数字',
                            style: theme.textTheme.bodySmall,
                          ),
                          if (_moment(bindCode!['expires_at']).isNotEmpty)
                            Text(
                              '这个码到 ${_moment(bindCode!['expires_at'])} 前有效',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 18),
              Text('最近发送队列', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              if (outbox.isEmpty)
                Text('还没有发过消息', style: theme.textTheme.bodySmall)
              else
                for (final message in outbox.take(5))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${statusLabels[message['status']] ?? message['status']}'
                      '${_moment(message['created_at']) == '' ? '' : ' · ${_moment(message['created_at'])}'}'
                      ' · ${message['text']}'
                      '${message['last_error'] == null ? '' : '\n    ${message['last_error']}'}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
            ],
            if (c.configured && loaded && !owner) ...[
              const SizedBox(height: 16),
              Text(
                '绑定你的 QQ',
                key: const Key('qq.tutorial'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              for (final (i, step) in const [
                '在 QQ 里搜到站长给你的机器人，或从开放平台的「扫码聊天」进入对话',
                '点下面「生成绑定码」，记下 6 位数字',
                '在机器人的对话里把这 6 位数字发出去',
                '收到「绑定好了」就完成；之后在 QQ 里发消息，就是跟你的助手说话',
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
                    key: const Key('qq.bind-mine'),
                    onPressed: busy ? null : _newCodeMine,
                    child: Text(boundMine ? '换一个绑定码' : '生成绑定码'),
                  ),
                  OutlinedButton(
                    key: const Key('qq.refresh'),
                    onPressed: busy ? null : () => _run(_refreshMine),
                    child: const Text('刷新状态'),
                  ),
                  if (boundMine)
                    TextButton(
                      key: const Key('qq.unbind-mine'),
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
                            '把这个 6 位数字发到机器人对话里，10 分钟内有效。',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
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
