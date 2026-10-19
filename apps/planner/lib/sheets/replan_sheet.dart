part of '../home.dart';

extension _ReplanSheet on _PlannerHomeState {
  Future<void> replanDialog(Json t) async {
    await attempt(() async {
      final from = now.toUtc();
      final plan = await c.onlineRequest('/api/v1/plan/proposals', {
        'task_id': t['id'],
        'from_at': from.toIso8601String(),
        'until_at': from.add(const Duration(days: 7)).toIso8601String(),
      });
      if (!mounted) return;
      final confirmed = await showOwnedDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('给剩余工作找个位置'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(plan['reason']),
                  const SizedBox(height: 14),
                  for (final b in plan['new_blocks'] as List)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(b['title']),
                      subtitle: Text(
                        '${dateKey(local(b['start_at']))}  ${hm(local(b['start_at']))}—${hm(local(b['end_at']))}',
                      ),
                    ),
                  for (final item in plan['unscheduled_items'] as List)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        '尚未安排：${item['title']} ${item['minutes']} 分钟\n${item['reason']}',
                        style: TextStyle(color: palette.accent),
                      ),
                    ),
                  Text('固定预约、保护时段和已有执行记录保留。', style: TextStyle(color: green)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('先保持原样'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('应用调整'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await c.applyProposal(plan['id']);
        message('已更新安排。');
      }
    });
  }
}
