part of '../home.dart';

extension _TasksPage on _PlannerHomeState {
  Widget taskPage() => SingleChildScrollView(
    child: padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading('每件事，都有下一步。', '任务目标、已经投入的时间和等待结果分别记录。'),
          for (final check
              in (c.state['waiting_checks'] as List).cast<Json>().where(
                (w) => w['resolved_at'] == null,
              ))
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: panel(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '等待结果 · ${task(check['task_id'])?['title'] ?? '任务'}',
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '检查时间 ${dateKey(local(check['check_at']))} ${hm(local(check['check_at']))}',
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => resolveWaiting(check),
                      child: const Text('结果已返回'),
                    ),
                  ],
                ),
                color: palette.paperRaised,
              ),
            ),
          if (c.tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('还没有任务，先安排一件具体的事。'),
            ),
          for (final t in c.tasks.reversed)
            Card(
              color: palette.paperRaised,
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            t['title'],
                            style: const TextStyle(fontSize: 17),
                          ),
                        ),
                        chip(taskState(t['state']), t['project_id']),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(t['outcome_criteria'] ?? ''),
                    const SizedBox(height: 8),
                    Text(
                      '剩余投入 ${t['remaining_minutes'] ?? 0} 分钟',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (!['done', 'cancelled'].contains(t['state'])) ...[
                          TextButton(
                            onPressed: () => taskDialog(existing: t),
                            child: const Text('安排下一段'),
                          ),
                          TextButton(
                            onPressed: () => replanDialog(t),
                            child: const Text('弹性安排'),
                          ),
                        ],
                        TextButton(
                          onPressed: () => editTask(t),
                          child: const Text('编辑任务'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 70),
        ],
      ),
    ),
  );
}
