part of '../home.dart';

/// Compact always-on-top desktop widget: what is happening now, what comes
/// next today, and a quick way to add something. Same paper, same ink.
extension _WidgetPage on _PlannerHomeState {
  Widget widgetShell() {
    final today = now;
    if (dateKey(selectedDay) != dateKey(today)) {
      selectedDay = DateTime(today.year, today.month, today.day);
    }
    return PaperBackground(
      child: Scaffold(
        backgroundColor: palette.paper.withValues(alpha: 0),
        body: Column(
          children: [
            InkTitleBar(
              compact: true,
              title:
                  '${today.month}月${today.day}日 · ${weekdays[today.weekday - 1]}',
            ),
            Expanded(child: widgetPage()),
          ],
        ),
      ),
    );
  }

  Widget widgetPage() {
    final theme = Theme.of(context);
    final items = todaysBlocks;
    final active = items
        .where(
          (b) => [
            'running',
            'paused',
            'awaiting_feedback',
          ].contains(session(b['id'])?['state']),
        )
        .firstOrNull;
    final upcoming = items
        .where(
          (b) => b['status'] == 'scheduled' && local(b['end_at']).isAfter(now),
        )
        .toList();
    final focus = active ?? upcoming.firstOrNull;
    final later = upcoming.where((b) => b != focus).toList();
    final past = items
        .where((b) => b != active && !upcoming.contains(b))
        .length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 12),
          child: Text(daySummary, style: theme.textTheme.bodySmall),
        ),
        if (focus == null)
          InkCard(
            focused: true,
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('此刻没有安排', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text('喝口水，或者落一笔下一件事。', style: theme.textTheme.bodySmall),
              ],
            ),
          )
        else
          _miniFocus(focus),
        if (later.isNotEmpty) ...[
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text('接下来', style: theme.textTheme.titleSmall),
          ),
          for (final block in later) _miniRow(block),
        ],
        if (past > 0)
          Padding(
            padding: const EdgeInsets.only(top: 10, left: 2),
            child: Text('今天已过去 $past 段', style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => taskDialog(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('安排一件事'),
          ),
        ),
      ],
    );
  }

  Widget _miniFocus(Json block) {
    final theme = Theme.of(context);
    final s = session(block['id']);
    final state = s?['state'];
    final t = task(block['task_id']);
    final start = local(block['start_at']), end = local(block['end_at']);
    double progress = 0;
    String status = blockStatus(block);
    if (state == 'running' || state == 'paused') {
      final expected = DateTime.parse(s!['expected_end_at']);
      final total = end.difference(start).inSeconds;
      final left =
          (state == 'paused'
                  ? expected.difference(DateTime.parse(s['paused_at']))
                  : expected.difference(DateTime.now().toUtc()))
              .inSeconds;
      progress = total <= 0 ? 0 : (1 - left / total).clamp(0.0, 1.0);
      status = state == 'paused'
          ? '已暂停 · 还剩 ${(left / 60).ceil()} 分'
          : left > 0
          ? '进行中 · 还剩 ${(left / 60).ceil()} 分'
          : '时间到了';
    } else if (state == null && start.isAfter(now)) {
      final wait = start.difference(now);
      status = wait.inMinutes < 60
          ? '${wait.inMinutes + 1} 分钟后开始'
          : '${hm(start)} 开始';
    }
    return InkCard(
      focused: true,
      mark: markOf(t?['project_id']),
      inquiry: state == 'awaiting_feedback',
      padding: const EdgeInsets.fromLTRB(18, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${hm(start)} — ${hm(end)}',
            style: TextStyle(
              fontFamily: 'WenKai',
              fontSize: 13,
              color: palette.inkZhong,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            block['title'],
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
          if (t != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '求一个结果：${t['outcome_criteria']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 10),
          if (progress > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  color: palette.inkNong,
                  backgroundColor: palette.wash,
                ),
              ),
            ),
          Text(status, style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          blockActions(block),
        ],
      ),
    );
  }

  Widget _miniRow(Json block) {
    final start = local(block['start_at']);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => blockDetails(block),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 50,
              child: Text(
                hm(start),
                style: TextStyle(
                  fontFamily: 'WenKai',
                  fontSize: 14,
                  color: palette.inkJiao,
                ),
              ),
            ),
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: blockMark(block) ?? palette.inkQing,
                shape: BoxShape.circle,
              ),
            ),
            Expanded(
              child: Text(
                block['title'],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
