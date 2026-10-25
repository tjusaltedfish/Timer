part of '../home.dart';

extension _EditTaskSheet on _PlannerHomeState {
  Future<void> deleteTask(Json t) async {
    final active = c.sessions
        .where(
          (s) =>
              s['task_id'] == t['id'] &&
              ['running', 'paused'].contains(s['state']),
        )
        .firstOrNull;
    final confirmed = await showOwnedDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这项待办？'),
        content: Text(
          '${active == null ? '' : '当前投入会先结束，已记录的时间会保留。'}「${t['title']}」及未来安排将被撤下，相关提醒会取消。已有投入和结果记录仍保留在历史中。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('保留'),
          ),
          FilledButton(
            key: const Key('task.confirm-delete'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(active == null ? '删除待办' : '结束并删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await attempt(() async {
      if (active != null) await c.controlSession(active, 'end');
      final latest = c.tasks.firstWhere((item) => item['id'] == t['id']);
      await c.submit('task.update', {
        'id': t['id'],
        'version': latest['version'],
        'state': 'cancelled',
      });
      message('已删除待办，未来安排和提醒已撤下。');
    });
  }

  /// The task's planned slots that have not started, each with its own
  /// 「改时间」 (start and length), plus a way to plan another slot.
  Widget taskTimeSection(
    Json t,
    BuildContext dialogContext,
    VoidCallback refresh,
  ) {
    final upcoming =
        c.blocks
            .where(
              (b) =>
                  b['task_id'] == t['id'] &&
                  b['status'] == 'scheduled' &&
                  !c.sessions.any((s) => s['block_id'] == b['id']),
            )
            .toList()
          ..sort((a, b) => (a['start_at'] as String).compareTo(b['start_at']));
    final open = !['done', 'cancelled'].contains(t['state']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('时间安排', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        if (upcoming.isEmpty)
          Text(
            open ? '还没有安排时间。' : '没有待开始的时间段。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        for (final block in upcoming)
          Row(
            children: [
              Expanded(
                child: Text(
                  '${local(block['start_at']).month}/${local(block['start_at']).day} '
                  '${weekdays[local(block['start_at']).weekday - 1]} '
                  '${hm(local(block['start_at']))}–${hm(local(block['end_at']))}'
                  '（${DateTime.parse(block['end_at']).difference(DateTime.parse(block['start_at'])).inMinutes} 分钟）',
                ),
              ),
              TextButton(
                key: ValueKey('task.edit.time.${block['id']}'),
                onPressed: () async {
                  await rescheduleDialog(block);
                  refresh();
                },
                child: const Text('改时间'),
              ),
            ],
          ),
        if (open)
          TextButton.icon(
            key: const Key('task.edit.add-time'),
            onPressed: () {
              Navigator.pop(dialogContext);
              taskDialog(existing: t);
            },
            icon: const Icon(Icons.add, size: 18),
            label: Text(upcoming.isEmpty ? '安排时间' : '再安排一段'),
          ),
      ],
    );
  }

  Future<void> editTask(Json t) async {
    final title = TextEditingController(text: t['title']),
        goal = TextEditingController(text: t['outcome_criteria']);
    String? error;
    String? project = t['project_id'] as String?;
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('编辑待办'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    maxLength: 200,
                    decoration: const InputDecoration(labelText: '任务名称'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: goal,
                    maxLines: 3,
                    maxLength: 2000,
                    decoration: const InputDecoration(labelText: '完成标准'),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: categoryChips(
                      project,
                      (value) => setDialog(() => project = value),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Time lives here too: this is where people look for it.
                  taskTimeSection(t, dialogContext, () => setDialog(() {})),
                  if (error != null) Text(error!),
                ],
              ),
            ),
          ),
          actions: [
            if (t['state'] == 'done')
              TextButton(
                onPressed: () => attempt(() async {
                  await c.submit('task.update', {
                    'id': t['id'],
                    'version': t['version'],
                    'state': 'ready',
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                }),
                child: const Text('明确重新打开'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('返回'),
            ),
            TextButton(
              key: ValueKey('task.delete.${t['id']}'),
              onPressed: () async {
                if (t['state'] == 'cancelled') {
                  await attempt(
                    () => c.submit('task.update', {
                      'id': t['id'],
                      'version': t['version'],
                      'state': 'ready',
                    }),
                  );
                } else {
                  Navigator.pop(dialogContext);
                  await deleteTask(t);
                }
              },
              child: Text(t['state'] == 'cancelled' ? '重新打开' : '删除待办'),
            ),
            FilledButton(
              onPressed: () async {
                if (title.text.trim().isEmpty || goal.text.trim().isEmpty) {
                  setDialog(() => error = '请保留名称和完成标准。');
                  return;
                }
                try {
                  await c.submit('task.update', {
                    'id': t['id'],
                    'version': t['version'],
                    'title': title.text.trim(),
                    'outcome_criteria': goal.text.trim(),
                    if (project != t['project_id']) 'project_id': project,
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (e) {
                  setDialog(() => error = e.toString());
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    goal.dispose();
  }
}
