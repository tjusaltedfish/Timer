part of '../home.dart';

extension _EditTaskSheet on _PlannerHomeState {
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
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('返回'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  await c.submit('task.update', {
                    'id': t['id'],
                    'version': t['version'],
                    'state': ['done', 'cancelled'].contains(t['state'])
                        ? 'ready'
                        : 'cancelled',
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (e) {
                  setDialog(() => error = e.toString());
                }
              },
              child: Text(
                ['done', 'cancelled'].contains(t['state']) ? '明确重新打开' : '取消任务',
              ),
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
