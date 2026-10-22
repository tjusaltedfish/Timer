part of '../home.dart';

/// Model service settings. Editable only on the computer, where the key is
/// stored; the phone sees status only. The key is never sent back.
class AssistantSettingsPanel extends StatefulWidget {
  const AssistantSettingsPanel({super.key, required this.controller});
  final PlannerController controller;
  @override
  State<AssistantSettingsPanel> createState() => _AssistantSettingsState();
}

class _AssistantSettingsState extends State<AssistantSettingsPanel> {
  final url = TextEditingController(),
      model = TextEditingController(),
      key = TextEditingController(),
      limit = TextEditingController();
  Json? config;
  String? note;
  bool busy = false, loaded = false, showKey = false;
  List<String> models = [];
  PlannerController get c => widget.controller;
  bool get desktop => c.state['device']?['role'] == 'desktop';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final field in [url, model, key, limit]) {
      field.dispose();
    }
    super.dispose();
  }

  void _fill(Json value) {
    config = value;
    url.text = value['base_url'] ?? '';
    model.text = value['model'] ?? '';
    limit.text = '${value['daily_limit'] ?? 200}';
    key.clear();
  }

  Future<void> _load() async {
    if (!c.configured) {
      setState(() => loaded = true);
      return;
    }
    try {
      final value = await c.assistantConfig();
      if (mounted) setState(() => _fill(value));
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

  Future<void> _save({bool clear = false}) => _run(() async {
    final value = await c.saveAssistantConfig({
      'base_url': url.text.trim(),
      'model': model.text.trim(),
      if (key.text.trim().isNotEmpty && !clear) 'api_key': key.text.trim(),
      if (clear) 'clear_key': true,
      if (int.tryParse(limit.text.trim()) != null)
        'daily_limit': int.parse(limit.text.trim()),
    });
    if (!mounted) return;
    setState(() {
      _fill(value);
      note = clear ? 'Key 已从这台电脑删除。' : '已保存在这台电脑上。';
    });
  });

  Future<void> _test() => _run(() async {
    final value = await c.testAssistant();
    if (!mounted) return;
    final fixed = value['fixed_base_url'] as String?;
    if (fixed != null) url.text = fixed;
    setState(
      () => note =
          '${fixed == null ? '' : '服务地址缺了 /v1，已自动改为 $fixed。\n'}'
          '连上了：${value['model']} 回复「${value['reply']}」，用时 ${value['latency_ms']} 毫秒。',
    );
  });

  Future<void> _models() => _run(() async {
    final value = await c.assistantModels();
    if (!mounted) return;
    setState(() {
      models = value;
      note = value.isEmpty ? '这个服务没有提供模型列表，请按服务商文档填写模型名。' : null;
    });
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = config?['configured'] == true;
    return SizedBox(
      width: double.infinity,
      child: InkCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('助手', style: theme.textTheme.titleMedium)),
                if (ready) const Seal('通', label: '已配置'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              !c.configured
                  ? '连接你的账号后，在这台设备上填写模型服务即可。'
                  : ready
                  ? '已接入 ${config!['model']} · 今天用了 ${config!['used_today']}/${config!['daily_limit']} 次'
                  : '还没有配置模型服务。填好下面三项就能开始用。',
              style: theme.textTheme.bodySmall,
            ),
            if (!loaded)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (c.configured && loaded) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    label: const Text('DeepSeek'),
                    onPressed: () => setState(() {
                      url.text = 'https://api.deepseek.com';
                      if (model.text.isEmpty) model.text = 'deepseek-chat';
                    }),
                  ),
                  ActionChip(
                    label: const Text('OpenAI 中转站'),
                    onPressed: () => setState(() {
                      url.text = 'https://';
                      note = '中转站地址一般以 /v1 结尾，例如 https://你的中转站域名/v1';
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('assistant.url'),
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '服务地址',
                  hintText: 'https://api.deepseek.com 或 https://中转站/v1',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('assistant.model'),
                controller: model,
                decoration: InputDecoration(
                  labelText: '模型名',
                  hintText: '例如 deepseek-chat，以服务商文档为准',
                  suffixIcon: TextButton(
                    onPressed: busy || (config?['key_hint'] ?? '').isEmpty
                        ? null
                        : _models,
                    child: const Text('可用模型'),
                  ),
                ),
              ),
              if (models.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final id in models)
                        ChoiceChip(
                          label: Text(id),
                          selected: model.text == id,
                          onSelected: (_) => setState(() => model.text = id),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('assistant.key'),
                controller: key,
                obscureText: !showKey,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: (config?['key_hint'] ?? '').isEmpty
                      ? 'sk-…'
                      : '已保存 ${config!['key_hint']}，留空则不改',
                  suffixIcon: IconButton(
                    tooltip: showKey ? '隐藏' : '显示',
                    onPressed: () => setState(() => showKey = !showKey),
                    icon: Icon(
                      showKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 200,
                child: TextField(
                  controller: limit,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '每日调用上限'),
                ),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                key: const Key('assistant.confirm-first'),
                contentPadding: EdgeInsets.zero,
                value: config?['confirm_first'] == true,
                title: const Text('改动前先问我'),
                subtitle: const Text('关闭时助手直接改好日程，每次都能一键撤销。'),
                onChanged: busy
                    ? null
                    : (value) => _run(() async {
                        final saved = await c.saveAssistantConfig({
                          'confirm_first': value,
                        });
                        if (mounted) setState(() => config = saved);
                      }),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    key: const Key('assistant.save'),
                    onPressed: busy ? null : _save,
                    child: Text(busy ? '请稍候…' : '保存'),
                  ),
                  OutlinedButton(
                    onPressed: busy || !ready ? null : _test,
                    child: const Text('测试连接'),
                  ),
                  if ((config?['key_hint'] ?? '').isNotEmpty &&
                      config?['key_source'] == 'file')
                    TextButton(
                      onPressed: busy ? null : () => _save(clear: true),
                      child: const Text('删除 Key'),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                config?['key_source'] == 'env'
                    ? 'Key 来自环境变量 PLANNER_LLM_API_KEY。'
                    : 'Key 只保存在这台电脑的数据目录里，不会同步到手机，也不会显示出来。',
                style: theme.textTheme.bodySmall,
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
