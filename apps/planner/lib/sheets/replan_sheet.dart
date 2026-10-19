part of '../home.dart';

extension _ReplanSheet on _PlannerHomeState {
  Future<void> replanDialog(Json t) => attempt(() async {
    final from = c.nowUtc;
    final plan = await c.onlineRequest('/api/v1/plan/proposals', {
      'task_id': t['id'],
      'from_at': from.toIso8601String(),
      'until_at': from.add(const Duration(days: 7)).toIso8601String(),
    });
    if (mounted) await showPlanProposal(plan);
  });

  Future<void> showPlanProposal(Json plan) async {
    final allowed = plan['status'] == 'draft';
    Widget timeBlock(dynamic b) => ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(b['title']),
      subtitle: Text(
        '${dateKey(local(b['start_at']))}  ${hm(local(b['start_at']))}—${hm(local(b['end_at']))}',
      ),
    );
    final confirmed = await showOwnedDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(allowed ? '给后续安排找个位置' : '这次调整需要手动处理'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan['reason']),
                const SizedBox(height: 16),
                if ((plan['old_blocks'] as List).isNotEmpty) ...[
                  Text('原安排', style: Theme.of(context).textTheme.titleMedium),
                  for (final b in plan['old_blocks'] as List) timeBlock(b),
                  const SizedBox(height: 12),
                ],
                if ((plan['new_blocks'] as List).isNotEmpty) ...[
                  Text('调整后', style: Theme.of(context).textTheme.titleMedium),
                  for (final b in plan['new_blocks'] as List) timeBlock(b),
                ],
                for (final item in plan['unscheduled_items'] as List)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      '尚需处理：${item['title']} ${item['minutes']} 分钟\n${item['reason']}',
                    ),
                  ),
                const Text('本次实际投入单独保留，确认后只调整未来的安排。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(allowed ? '先保持原样' : '关闭'),
          ),
          if (allowed)
            FilledButton(
              key: const Key('plan.confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('应用调整'),
            ),
        ],
      ),
    );
    if (confirmed == true) {
      await attempt(() async {
        await c.applyProposal(plan['id']);
        message('已更新后续安排。');
      });
    }
  }
}
