part of '../home.dart';

/// 助手记住的事：看、加、删（删了能撤销）。助手页和设置里的助手卡片共用。
Future<void> showMemoryDialog(BuildContext context, PlannerController c) =>
    showOwnedDialog(
      context: context,
      builder: (_) => _MemoryDialog(controller: c),
    );

class _MemoryDialog extends StatefulWidget {
  const _MemoryDialog({required this.controller});
  final PlannerController controller;
  @override
  State<_MemoryDialog> createState() => _MemoryDialogState();
}

class _MemoryDialogState extends State<_MemoryDialog> {
  static const limit = 50;
  final text = TextEditingController();
  String? error;

  /// The last deleted memory, offered back once.
  Json? removed;

  PlannerController get c => widget.controller;
  List<Json> get memories =>
      (c.state['memories'] as List? ?? []).cast<Json>();

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _delete(Json memory) => _run(() async {
    await c.submit('memory.delete', {'id': memory['id']});
    removed = memory;
  });

  Future<void> _undo() => _run(() async {
    final memory = removed;
    if (memory == null) return;
    await c.submit('memory.save', {
      'id': memory['id'],
      'text': memory['text'],
      'source': memory['source'] ?? 'user',
    });
    removed = null;
  });

  Future<void> _add() async {
    final value = text.text.trim();
    if (value.isEmpty) return;
    await _run(() async {
      await c.submit('memory.save', {'id': const Uuid().v4(), 'text': value});
      text.clear();
      removed = null;
    });
  }

  String _date(Json memory) {
    final at = DateTime.tryParse(memory['created_at'] as String? ?? '');
    if (at == null) return '';
    final local = at.toLocal();
    return ' · ${local.month}月${local.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.inkPalette;
    final items = memories;
    final full = items.length >= limit;
    return AlertDialog(
      title: const Text('助手记住的事'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${items.length}/$limit 条。「你说的」是你让它记的；'
                '「助手记下」是它从聊天里听出来的习惯，不对就删掉。'
                '日程、复盘和材料不在这里，它们本身就是事实来源。',
                style: theme.textTheme.bodySmall,
              ),
              if (removed case final gone?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '已删除「${gone['text']}」',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        key: const Key('memory.undo'),
                        onPressed: _undo,
                        child: const Text('撤销'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '还没有记住什么。在下面写一句，或在聊天里说「记住：……」。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              for (final m in items)
                ListTile(
                  key: ValueKey('memory.${m['id']}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(m['text'] as String),
                  subtitle: Text(
                    '${m['source'] == 'assistant' ? '助手记下' : '你说的'}${_date(m)}',
                    style: TextStyle(fontSize: 12, color: p.inkZhong),
                  ),
                  trailing: IconButton(
                    key: ValueKey('memory.delete.${m['id']}'),
                    tooltip: '删除这条',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(m),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('memory.input'),
                controller: text,
                enabled: !full,
                maxLength: 1000,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: '偏好或长期目标',
                  hintText: '例如：上午优先做实验，回答简短',
                  helperText: full ? '已经 $limit 条了，先删掉不用的再加。' : null,
                ),
              ),
              if (error != null)
                Text(error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          key: const Key('memory.save'),
          onPressed: full ? null : _add,
          child: const Text('记住'),
        ),
      ],
    );
  }
}
