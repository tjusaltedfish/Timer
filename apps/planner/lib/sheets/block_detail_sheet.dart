part of '../home.dart';

extension _BlockDetailSheet on _PlannerHomeState {
  Future<void> blockDetails(Json block) async {
    final t = task(block['task_id']);
    await showOwnedDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(block['title']),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${dateKey(local(block['start_at']))}  ${hm(local(block['start_at']))}—${hm(local(block['end_at']))}',
              ),
              const SizedBox(height: 14),
              Text(t?['outcome_criteria'] ?? '保护时段'),
              if (t != null) ...[
                const SizedBox(height: 12),
                Text(
                  '状态：${taskState(t['state'])} · 剩余投入 ${t['remaining_minutes']} 分钟',
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (t != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                editTask(t);
              },
              child: const Text('编辑待办'),
            ),
          if (t != null && t['state'] != 'cancelled')
            TextButton(
              key: ValueKey('task.delete.${t['id']}'),
              onPressed: () {
                Navigator.pop(context);
                deleteTask(t);
              },
              child: const Text('删除待办'),
            ),

          if (t != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                replanDialog(t);
              },
              child: const Text('弹性调整'),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              update(() {
                selectedDay = local(block['start_at']);
                selectedBlock = block['id'];
                page = 0;
              });
            },
            child: const Text('查看卡片'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
