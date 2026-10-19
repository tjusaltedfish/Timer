part of '../home.dart';

extension _TasksPage on _PlannerHomeState {
  Widget taskPage() {
    final theme = Theme.of(context);
    final checks = (c.state['waiting_checks'] as List)
        .cast<Json>()
        .where((w) => w['resolved_at'] == null)
        .toList();
    // Groups follow the user's own categories; tasks without one come last.
    final groups = <String?, List<Json>>{};
    for (final p in c.projects) {
      groups[p['id']] = [];
    }
    groups[null] = [];
    for (final t in c.tasks.reversed) {
      final key = groups.containsKey(t['project_id']) ? t['project_id'] : null;
      groups[key]!.add(t);
    }
    const order = ['in_progress', 'ready', 'review', 'waiting'];
    Widget taskCard(Json t) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkCard(
        mark: markOf(t['project_id']),
        radius: 18,
        padding: const EdgeInsets.fromLTRB(20, 16, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(t['title'], style: theme.textTheme.titleMedium),
                ),
                Text(taskState(t['state']), style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            Text('求一个结果：${t['outcome_criteria'] ?? ''}'),
            const SizedBox(height: 2),
            Text(
              '还需投入 ${t['remaining_minutes'] ?? 0} 分钟',
              style: theme.textTheme.bodySmall,
            ),
            Wrap(
              spacing: 4,
              children: [
                if (!['done', 'cancelled'].contains(t['state'])) ...[
                  TextButton(
                    onPressed: () => taskDialog(existing: t),
                    child: const Text('再留一段'),
                  ),
                  TextButton(
                    onPressed: () => replanDialog(t),
                    child: const Text('弹性安排'),
                  ),
                ],
                TextButton(
                  onPressed: () => editTask(t),
                  child: const Text('编辑'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return SingleChildScrollView(
      child: padded(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (checks.isNotEmpty) ...[
              Text('等候结果', style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              for (final check in checks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InkCard(
                    radius: 18,
                    padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
                    child: Row(
                      children: [
                        const Seal('候', label: '等候结果'),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                task(check['task_id'])?['title'] ?? '任务',
                                style: theme.textTheme.titleSmall,
                              ),
                              Text(
                                '${local(check['check_at']).month}/${local(check['check_at']).day} ${hm(local(check['check_at']))} 去看看',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        FilledButton(
                          onPressed: () => resolveWaiting(check),
                          child: const Text('结果回来了'),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 14),
            ],
            if (c.tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  '还没有任务。点右下角，先落一笔具体的事。',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            for (final entry in groups.entries)
              if (entry.value.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 10),
                  child: Row(
                    children: [
                      if (markOf(entry.key) != null)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: markOf(entry.key),
                            shape: BoxShape.circle,
                          ),
                        ),
                      Text(
                        categoryName(entry.key) ?? '未归类',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${entry.value.where((t) => order.contains(t['state'])).length} 件进行中',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                for (final t
                    in entry.value
                        .where((t) => order.contains(t['state']))
                        .toList()
                      ..sort(
                        (a, b) => order
                            .indexOf(a['state'])
                            .compareTo(order.indexOf(b['state'])),
                      ))
                  taskCard(t),
                if (entry.value.any(
                  (t) => ['done', 'cancelled'].contains(t['state']),
                ))
                  Theme(
                    data: theme.copyWith(
                      dividerColor: palette.paper.withValues(alpha: 0),
                    ),
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: Text(
                        '已毕 ${entry.value.where((t) => ['done', 'cancelled'].contains(t['state'])).length} 件',
                        style: theme.textTheme.bodySmall,
                      ),
                      children: [
                        for (final t in entry.value.where(
                          (t) => ['done', 'cancelled'].contains(t['state']),
                        ))
                          Opacity(opacity: .7, child: taskCard(t)),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 70),
          ],
        ),
      ),
    );
  }
}
