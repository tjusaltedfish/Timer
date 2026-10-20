part of '../home.dart';

extension _AssistantPage on _PlannerHomeState {
  Widget assistantPage() => AssistantPanel(
    key: ValueKey('assistant-${c.configured}'),
    controller: c,
    onOpenSettings: () => update(() => page = 5),
  );
}

/// Letter-paper conversation with the assistant. Clear requests are carried
/// out at once and can be undone; with "改动前先问我" they wait as drafts.
class AssistantPanel extends StatefulWidget {
  const AssistantPanel({
    super.key,
    required this.controller,
    required this.onOpenSettings,
  });
  final PlannerController controller;
  final VoidCallback onOpenSettings;
  @override
  State<AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends State<AssistantPanel> {
  final input = TextEditingController();
  final scroll = ScrollController();
  List<Json> messages = [];
  Json? config;
  String? problem;
  bool loading = true, sending = false;
  final busyDrafts = <String>{};
  PlannerController get c => widget.controller;

  static const prompts = [
    '明天上午帮我排两小时写实验代码',
    '我迟到了 20 分钟，后面怎么挪？',
    '今天就到这，还剩什么没确认？',
    '这周还能挤出多少时间准备秋招？',
  ];

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (!c.configured) {
      setState(() => loading = false);
      return;
    }
    try {
      final values = await Future.wait([
        c.assistantConfig(),
        c.assistantMessages().then((m) => {'messages': m}),
      ]);
      if (!mounted) return;
      setState(() {
        config = values[0];
        messages = (values[1]['messages'] as List).cast<Json>();
        problem = null;
        loading = false;
      });
      _toBottom();
    } catch (error) {
      if (mounted) {
        setState(() {
          problem = error.toString();
          loading = false;
        });
      }
    }
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients) {
      scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: InkMetrics.transition,
        curve: InkMetrics.settle,
      );
    }
  });

  Future<void> send([String? preset]) async {
    final text = (preset ?? input.text).trim();
    if (text.isEmpty || sending) return;
    setState(() {
      sending = true;
      problem = null;
      messages = [
        ...messages,
        {'id': 'local', 'role': 'user', 'text': text, 'drafts': <Json>[]},
      ];
      input.clear();
    });
    _toBottom();
    try {
      final reply = await c.sendAssistant(text);
      if (!mounted) return;
      setState(() {
        messages = [...messages.where((m) => m['id'] != 'local'), ...reply];
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        messages = messages.where((m) => m['id'] != 'local').toList();
        input.text = text;
        problem = error.toString();
      });
    } finally {
      if (mounted) setState(() => sending = false);
      _toBottom();
    }
  }

  Future<void> showMemories() async {
    final memoryText = TextEditingController();
    String? error;
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('助手记住的事'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('只保存你明确提供的偏好。日程、回顾和材料另作为事实来源。'),
                  for (final m
                      in (c.state['memories'] as List? ?? []).cast<Json>())
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(m['text']),
                      trailing: IconButton(
                        tooltip: '删除记忆',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          try {
                            await c.submit('memory.delete', {'id': m['id']});
                            if (context.mounted) setDialog(() {});
                          } catch (e) {
                            if (context.mounted) {
                              setDialog(() => error = e.toString());
                            }
                          }
                        },
                      ),
                    ),
                  TextField(
                    controller: memoryText,
                    maxLength: 1000,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '偏好或长期目标',
                      hintText: '例如：上午优先做实验，回答简短',
                    ),
                  ),
                  if (error != null) Text(error!),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: () async {
                if (memoryText.text.trim().isEmpty) return;
                try {
                  await c.submit('memory.save', {
                    'id': const Uuid().v4(),
                    'text': memoryText.text.trim(),
                  });
                  memoryText.clear();
                  if (context.mounted) setDialog(() => error = null);
                } catch (e) {
                  if (context.mounted) setDialog(() => error = e.toString());
                }
              },
              child: const Text('记住'),
            ),
          ],
        ),
      ),
    );
    memoryText.dispose();
  }

  Future<void> undo(Json draft) async {
    setState(() => busyDrafts.add(draft['id']));
    try {
      await c.undoDraft(draft['id']);
      if (!mounted) return;
      setState(() {
        draft['status'] = 'undone';
        draft['undoable'] = false;
      });
    } catch (error) {
      if (mounted) setState(() => problem = error.toString());
    } finally {
      if (mounted) setState(() => busyDrafts.remove(draft['id']));
    }
  }

  Future<void> decide(Json draft, bool accept) async {
    setState(() => busyDrafts.add(draft['id']));
    try {
      accept
          ? await c.applyDraft(draft['id'])
          : await c.dismissDraft(draft['id']);
      if (!mounted) return;
      setState(() => draft['status'] = accept ? 'applied' : 'dismissed');
      if (accept) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('已照此办理，日程已更新。')));
      }
    } catch (error) {
      if (mounted) setState(() => problem = error.toString());
    } finally {
      if (mounted) setState(() => busyDrafts.remove(draft['id']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    if (loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 1.5));
    }
    Widget notice(String title, String body, {Widget? action}) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: EdgeInsets.all(narrow ? 20 : 32),
          child: InkCard(
            focused: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 10),
                Text(body),
                if (action != null) ...[const SizedBox(height: 18), action],
              ],
            ),
          ),
        ),
      ),
    );
    if (!c.configured) {
      return notice(
        '助手住在电脑上',
        '它借电脑上的模型服务帮你排日程、追问结果。先在设置里连接电脑，这里就能和它说话。',
        action: FilledButton(
          onPressed: widget.onOpenSettings,
          child: const Text('去连接电脑'),
        ),
      );
    }
    if (config != null && config!['configured'] != true) {
      final desktop = c.state['device']?['role'] == 'desktop';
      return notice(
        '还差一把钥匙',
        desktop
            ? '在设置的「助手」里填上服务地址、模型名和 API Key（DeepSeek 或 OpenAI 中转站都可以），就能开始用了。Key 只保存在这台电脑上。'
            : '助手还没在电脑上配置好。到电脑端「设置 · 助手」填好服务地址、模型和 API Key 后，手机就能直接用。',
        action: desktop
            ? FilledButton(
                onPressed: widget.onOpenSettings,
                child: const Text('去填写'),
              )
            : null,
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('assistant.memory'),
                onPressed: showMemories,
                icon: const Icon(Icons.bookmark_outline, size: 18),
                label: const Text('记忆'),
              ),
            ),
            Expanded(
              child: messages.isEmpty
                  ? ListView(
                      padding: EdgeInsets.all(narrow ? 20 : 32),
                      children: [
                        Text('想调整什么，直接说。', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 8),
                        Text(
                          '它会先给出「拟办」，你点「照此办理」才会改动日程。',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 20),
                        for (final p in prompts)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: ActionChip(
                                label: Text(p),
                                onPressed: () => send(p),
                              ),
                            ),
                          ),
                      ],
                    )
                  : ListView.builder(
                      controller: scroll,
                      padding: EdgeInsets.fromLTRB(
                        narrow ? 16 : 28,
                        12,
                        narrow ? 16 : 28,
                        12,
                      ),
                      itemCount: messages.length + (sending ? 1 : 0),
                      itemBuilder: (context, i) => i == messages.length
                          ? const _Thinking()
                          : _MessageView(
                              message: messages[i],
                              busy: busyDrafts,
                              onDecide: decide,
                              onUndo: undo,
                            ),
                    ),
            ),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  problem!,
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                narrow ? 12 : 28,
                8,
                narrow ? 12 : 28,
                narrow ? 8 : 20,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('assistant.input'),
                      controller: input,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 4000,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => send(),
                      decoration: const InputDecoration(
                        hintText: '比如：下午的实验推迟到四点',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: '发送',
                    onPressed: sending ? null : () => send(),
                    style: IconButton.styleFrom(
                      backgroundColor: context.inkPalette.inkJiao,
                      foregroundColor: context.inkPalette.paper,
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.message,
    required this.busy,
    required this.onDecide,
    required this.onUndo,
  });
  final Json message;
  final Set<String> busy;
  final void Function(Json draft, bool accept) onDecide;
  final void Function(Json draft) onUndo;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    final theme = Theme.of(context);
    final mine = message['role'] == 'user';
    final drafts = (message['drafts'] as List? ?? []).cast<Json>();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * .78,
            ),
            child: mine
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: p.washStrong,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                        bottomLeft: Radius.circular(20),
                        bottomRight: Radius.circular(6),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: SelectableText(message['text']),
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 4, right: 10),
                        child: Seal('助', label: '助手', size: 22),
                      ),
                      Flexible(child: SelectableText(message['text'])),
                    ],
                  ),
          ),
          for (final draft in drafts)
            Padding(
              padding: const EdgeInsets.only(top: 10, left: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: InkCard(
                  radius: 18,
                  padding: const EdgeInsets.fromLTRB(18, 14, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              draft['status'] == 'pending'
                                  ? '拟办 · ${draft['summary']}'
                                  : draft['summary'],
                              style: theme.textTheme.titleSmall?.copyWith(
                                decoration: draft['status'] == 'undone'
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                          if (draft['status'] == 'applied')
                            const Seal('办', label: '已办'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      for (final line in (draft['lines'] as List))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            line,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: p.inkNong,
                            ),
                          ),
                        ),
                      const SizedBox(height: 4),
                      if (draft['status'] == 'pending')
                        Wrap(
                          spacing: 8,
                          children: [
                            FilledButton(
                              onPressed: busy.contains(draft['id'])
                                  ? null
                                  : () => onDecide(draft, true),
                              child: const Text('照此办理'),
                            ),
                            TextButton(
                              onPressed: busy.contains(draft['id'])
                                  ? null
                                  : () => onDecide(draft, false),
                              child: const Text('不必'),
                            ),
                          ],
                        )
                      else if (draft['status'] == 'applied' &&
                          draft['undoable'] == true)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '已改好日程',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            TextButton(
                              key: ValueKey('draft.undo.${draft['id']}'),
                              onPressed: busy.contains(draft['id'])
                                  ? null
                                  : () => onUndo(draft),
                              child: const Text('撤销'),
                            ),
                          ],
                        )
                      else
                        Text(switch (draft['status']) {
                          'applied' => '已办',
                          'undone' => '已撤销',
                          _ => '已放下',
                        }, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Thinking extends StatefulWidget {
  const _Thinking();
  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Seal('助', label: '助手', size: 22),
          const SizedBox(width: 12),
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) => Row(
              children: [
                for (var i = 0; i < 3; i++)
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: p.inkZhong.withValues(
                        alpha:
                            .25 +
                            .6 *
                                (((controller.value * 3 - i) % 3) < 1
                                    ? 1 - ((controller.value * 3 - i) % 1)
                                    : 0),
                      ),
                    ),
                  ),
                Text('在想', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
