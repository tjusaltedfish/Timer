part of '../home.dart';

extension _EditTaskSheet on _PlannerHomeState {
  Future<void> deleteTask(Json t) async {
    final confirmed = await showOwnedDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这项待办？'),
        content: Text('「${t['title']}」及未来安排将被撤下，相关提醒会取消。已有投入和结果记录仍保留在历史中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('保留'),
          ),
          FilledButton(
            key: const Key('task.confirm-delete'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除待办'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await attempt(() async {
      await c.submit('task.update', {
        'id': t['id'],
        'version': t['version'],
        'state': 'cancelled',
      });
      message('已删除待办，未来安排和提醒已撤下。');
    });
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
          title: const Text('编辑任务'),
          content: SizedBox(
            width: 420,
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
                if (error != null) Text(error!),
              ],
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
