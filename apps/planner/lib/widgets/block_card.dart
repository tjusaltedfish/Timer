part of '../home.dart';

extension _BlockCard on _PlannerHomeState {
  String blockStatus(Json block) {
    final s = session(block['id']);
    if (s?['state'] == 'awaiting_feedback') return '待回话';
    if (s?['state'] == 'running') return '进行中';
    if (s?['state'] == 'paused') return '已暂停';
    if (block['status'] == 'completed') return '已记录';
    if (block['status'] == 'skipped') return '未开始';
    if (block['kind'] == 'protected') return '保护时段';
    if (task(block['task_id'])?['state'] == 'waiting') return '等候结果';
    if (!local(block['end_at']).isAfter(now)) return '待回话';
    if (!local(block['start_at']).isAfter(now)) return '该开始了';
    return block['kind'] == 'fixed' ? '固定预约' : '尚未开始';
  }

  String? blockSeal(Json block) => switch (blockStatus(block)) {
    '待回话' => '问',
    '进行中' => '今',
    '等候结果' => '候',
    '固定预约' => '定',
    '保护时段' => '护',
    _ => null,
  };
  Widget focusCard(Json block, {bool focused = true}) {
    final t = task(block['task_id']), s = session(block['id']);
    final state = s?['state'];
    final planned =
        s?['planned_seconds'] as int? ??
        DateTime.parse(block['end_at'])
            .difference(DateTime.parse(block['start_at']))
            .inSeconds;
    var elapsed = 0;
    if (s != null) {
      for (final interval in s['intervals'] as List? ?? []) {
        elapsed += (DateTime.tryParse(interval['end_at'] ?? '') ?? c.nowUtc)
            .difference(DateTime.parse(interval['start_at']))
            .inSeconds;
      }
    }
    final remaining = s == null
        ? planned
        : state == 'paused'
        ? DateTime.parse(s['expected_end_at'])
              .difference(DateTime.parse(s['paused_at']))
              .inSeconds
        : DateTime.parse(s['expected_end_at']).difference(c.nowUtc).inSeconds;
    final seal = blockSeal(block);
    return Semantics(
      label:
          '${hm(local(block['start_at']))}至${hm(local(block['end_at']))}，${block['title']}，${blockStatus(block)}',
      child: InkCard(
        mark: markOf(t?['project_id']),
        focused: focused,
        inquiry: state == 'awaiting_feedback',
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                physics: focused ? null : const NeverScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${hm(local(block['start_at']))} — ${hm(local(block['end_at']))}',
                            style: TextStyle(
                              fontFamily: 'WenKai',
                              fontSize: 16,
                              color: palette.inkZhong,
                            ),
                          ),
                        ),
                        if (seal != null) Seal(seal, label: blockStatus(block)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      block['title'],
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      t == null
                          ? '为生活和休息留出的时间。'
                          : '求一个结果：${t['outcome_criteria']}',
                      maxLines: focused ? null : 2,
                      overflow: focused ? null : TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      blockStatus(block),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (focused) ...[
                      if (state == 'running' || state == 'paused')
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: EnsoTimer(
                              elapsed: elapsed,
                              planned: planned,
                              remaining: remaining,
                              paused: state == 'paused',
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            if (focused) ...[const SizedBox(height: 12), blockActions(block)],
          ],
        ),
      ),
    );
  }

  void activateBlock(Json block) {
    final s = session(block['id']);
    if (s?['state'] == 'awaiting_feedback') {
      feedbackDialog(block);
    } else if (s == null &&
        block['status'] == 'scheduled' &&
        task(block['task_id'])?['state'] == 'ready') {
      startBlock(block);
    } else {
      blockDetails(block);
    }
  }

  Widget blockActions(Json block) {
    final t = task(block['task_id']), s = session(block['id']);
    final state = s?['state'];
    if (state == 'running' || state == 'paused') {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
            key: const Key('action.pause'),
            onPressed: () => attempt(
              () =>
                  c.controlSession(s!, state == 'paused' ? 'resume' : 'pause'),
            ),
            child: Text(state == 'paused' ? '继续这一段' : '暂停'),
          ),
          OutlinedButton(
            key: const Key('action.end'),
            onPressed: () => attempt(() async {
              await c.controlSession(s!, 'end');
              if (mounted) await feedbackDialog(block);
            }),
            child: const Text('结束并反馈'),
          ),
          ...extensionActions(s!),
        ],
      );
    }
    if (state == 'awaiting_feedback') {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
            key: const Key('action.inquiry'),
            onPressed: () => feedbackDialog(block),
            child: const Text('这一段，进展如何？'),
          ),
          if (c.canExtendSession(s!)) ...extensionActions(s),
        ],
      );
    }
    if (t != null &&
        block['status'] == 'scheduled' &&
        !['done', 'cancelled', 'waiting'].contains(t['state'])) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            key: const Key('action.start'),
            onPressed: () => startBlock(block),
            icon: const Icon(Icons.play_arrow_outlined),
            label: const Text('开始这一段'),
          ),
          TextButton(
            onPressed: () => attempt(
              () => c.submit('feedback.create', {
                'block_id': block['id'],
                'choice': 'not_started',
              }),
            ),
            child: const Text('这段没有开始'),
          ),
        ],
      );
    }
    return Text(
      s == null ? taskState(t?['state']) : '本段已记录',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  List<Widget> extensionActions(Json s) => [
    for (final minutes in [15, 30])
      TextButton(
        key: ValueKey('action.extend.$minutes'),
        onPressed: () => attempt(() async {
          await c.extendSession(s, minutes);
          message('已增加 $minutes 分钟。后续安排将在同步后检查。');
        }),
        child: Text('再给我 $minutes 分钟'),
      ),
  ];

  Future<void> startBlock(Json block) async {
    var mode = 'keep_duration';
    if (c.nowUtc.difference(DateTime.parse(block['start_at'])).inMinutes > 5) {
      final end = DateTime.parse(block['end_at']);
      final duration = end.difference(DateTime.parse(block['start_at']));
      final chosen = await showOwnedDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('这一段现在开始，怎么安排？'),
          content: Text(
            '原计划 ${hm(local(block['start_at']))}—${hm(local(block['end_at']))}。可以保留原时长，或按原结束时刻收尾。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('稍后'),
            ),
            OutlinedButton(
              key: const Key('start.mode.keep_end'),
              onPressed: end.isAfter(c.nowUtc)
                  ? () => Navigator.pop(context, 'keep_end')
                  : null,
              child: Text(
                end.isAfter(c.nowUtc)
                    ? '按原结束 · 还剩 ${end.difference(c.nowUtc).inMinutes} 分钟'
                    : '原结束时刻已过',
              ),
            ),
            FilledButton(
              key: const Key('start.mode.keep_duration'),
              onPressed: () => Navigator.pop(context, 'keep_duration'),
              child: Text(
                '保留 ${duration.inMinutes} 分钟 · 到 ${hm(tz.TZDateTime.from(c.nowUtc.add(duration), zone))}',
              ),
            ),
          ],
        ),
      );
      if (chosen == null) return;
      mode = chosen;
    }
    await attempt(() => c.startBlock(block, mode: mode));
  }

  Widget blockTile(Json block) {
    final t = task(block['task_id']);
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          onTap: () => blockDetails(block),
          leading: SizedBox(
            width: 56,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  hm(local(block['start_at'])),
                  style: TextStyle(
                    fontFamily: 'WenKai',
                    fontSize: 16,
                    color: palette.inkJiao,
                  ),
                ),
                Text(
                  hm(local(block['end_at'])),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          title: Text(
            block['title'],
            style: Theme.of(context).textTheme.titleMedium,
          ),
          subtitle: Text(
            t?['outcome_criteria'] ?? '保护时段',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            blockStatus(block),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
