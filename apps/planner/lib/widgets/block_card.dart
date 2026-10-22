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
  /// Actual interval once the block has been started, with the planned one as
  /// the reference; untouched blocks keep their plan.
  ({String main, String? hint}) blockTime(Json block, Json? s) {
    final plannedStart = DateTime.parse(block['start_at'] as String);
    final plannedEnd = DateTime.parse(block['end_at'] as String);
    final span = blockSpan(block, s);
    final start = hm(local(span.start.toIso8601String()));
    final end = hm(local(span.end.toIso8601String()));
    final plan = '原定 ${hm(local(block['start_at']))}–${hm(local(block['end_at']))}';
    if (s == null || s['actual_start_at'] == null) {
      return (main: '$start — $end', hint: null);
    }
    final state = s['state'];
    if (state == 'running') {
      return (main: '$start 开始 · 预计 $end 收尾', hint: plan);
    }
    if (state == 'paused') {
      return (main: '$start 开始 · 暂停中', hint: plan);
    }
    final differs = span.start != plannedStart || span.end != plannedEnd;
    return (
      main: '$start — $end',
      hint: differs ? plan : null,
    );
  }

  Widget focusCard(Json block, {bool focused = true}) {
    final t = task(block['task_id']), s = session(block['id']);
    final state = s?['state'];
    final time = blockTime(block, s);
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
      label: '${time.main}，${block['title']}，${blockStatus(block)}',
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
                            time.main,
                            style: TextStyle(
                              fontFamily: 'WenKai',
                              fontSize: 16,
                              color: palette.inkZhong,
                            ),
                          ),
                        ),
                        if (seal != null) Seal(seal, label: blockStatus(block)),
                        if (focused && t != null)
                          PopupMenuButton<String>(
                            tooltip: '待办操作',
                            onSelected: (value) =>
                                value == 'edit' ? editTask(t) : deleteTask(t),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('编辑待办')),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('删除待办'),
                              ),
                            ],
                          ),
                      ],
                    ),
                    if (time.hint != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          time.hint!,
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.inkZhong.withValues(alpha: .8),
                          ),
                        ),
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
      feedbackDialog(block, followUp: true);
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
              if (mounted) await feedbackDialog(block, followUp: true);
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
            onPressed: () => feedbackDialog(block, followUp: true),
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
          if (DateTime.parse(block['end_at']).isAfter(c.nowUtc))
            FilledButton.icon(
              key: const Key('action.start'),
              onPressed: () => startBlock(block),
              icon: const Icon(Icons.play_arrow_outlined),
              label: const Text('开始这一段'),
            ),
          if (!DateTime.parse(block['end_at']).isAfter(c.nowUtc))
            FilledButton(
              onPressed: () => feedbackDialog(block),
              child: const Text('补记这一段的结果'),
            ),
          if (!DateTime.parse(block['end_at']).isAfter(c.nowUtc))
            OutlinedButton(
              key: const Key('action.reschedule'),
              onPressed: () => rescheduleDialog(block),
              child: const Text('挪到之后'),
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
          if (!c.connected) message('已增加 $minutes 分钟。后续安排将在同步后检查。');
        }),
        child: Text('再给我 $minutes 分钟'),
      ),
    TextButton(
      key: const Key('action.extend.custom'),
      onPressed: () => extendDialog(s),
      child: const Text('自定义…'),
    ),
  ];

  /// 5–120 分钟，默认 25；确认后与快捷续时走同一条 `session.extend`。
  Future<void> extendDialog(Json s) async {
    var minutes = 25;
    final chosen = await showOwnedDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('再给自己多久？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWheel(
                key: const Key('extend.wheel'),
                count: 24,
                index: minutes ~/ 5 - 1,
                looping: false,
                width: 140,
                semanticLabel: '续时时长',
                label: (i) => '${(i + 1) * 5} 分钟',
                onChanged: (i) => setDialog(() => minutes = (i + 1) * 5),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('extend.confirm'),
              onPressed: () => Navigator.pop(dialogContext, minutes),
              child: Text('加 $minutes 分钟'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await attempt(() async {
      await c.extendSession(s, chosen);
      if (!c.connected) message('已增加 $chosen 分钟。后续安排将在同步后检查。');
    });
  }

  /// 已过点却没开始的段：把原定这一整段挪到之后，时长不变。
  Future<void> rescheduleDialog(Json block) async {
    final opened = now;
    final wallNow = DateTime(
      opened.year,
      opened.month,
      opened.day,
      opened.hour,
      opened.minute,
      opened.second,
    );
    final duration = local(block['end_at']).difference(local(block['start_at']));
    final tonight = DateTime(opened.year, opened.month, opened.day, 20);
    final targets = <String, DateTime>{};
    if (tonight.isAfter(wallNow)) {
      targets['今晚 20:00'] = tonight;
    } else {
      targets['明晚 20:00'] = tonight.add(const Duration(days: 1));
    }
    targets['明早 9:00'] = DateTime(
      opened.year,
      opened.month,
      opened.day + 1,
      9,
    );
    var picked = targets.keys.first;
    var custom = InkDateTimeWheel.ceilTo(
      opened.add(const Duration(minutes: 30)),
      5,
    );
    DateTime target() => picked == 'custom' ? custom : targets[picked]!;
    final chosen = await showOwnedDialog<DateTime>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) {
          final at = target();
          return AlertDialog(
            title: const Text('把这一段挪到？'),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '原定 ${hm(local(block['start_at']))}—${hm(local(block['end_at']))}，'
                      '共 ${duration.inMinutes} 分钟。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in targets.entries)
                          ChoiceChip(
                            key: ValueKey(
                              entry.key.startsWith('今晚')
                                  ? 'reschedule.tonight'
                                  : entry.key.startsWith('明晚')
                                  ? 'reschedule.tomorrow-evening'
                                  : 'reschedule.tomorrow',
                            ),
                            label: Text(entry.key),
                            selected: picked == entry.key,
                            onSelected: (_) =>
                                setDialog(() => picked = entry.key),
                          ),
                        ChoiceChip(
                          key: const Key('reschedule.custom'),
                          label: const Text('自己选时间'),
                          selected: picked == 'custom',
                          onSelected: (_) => setDialog(() => picked = 'custom'),
                        ),
                      ],
                    ),
                    if (picked == 'custom')
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Center(
                          child: InkDateTimeWheel(
                            initial: custom,
                            today: opened,
                            minimum: opened,
                            days: 60,
                            onChanged: (d, h, m) => custom = DateTime(
                              d.year,
                              d.month,
                              d.day,
                              h,
                              m,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 14),
                    Text(
                      '挪到 ${at.month}月${at.day}日 ${hm(at)}—'
                      '${hm(at.add(duration))}，共 ${duration.inMinutes} 分钟。',
                      key: const Key('reschedule.preview'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('reschedule.confirm'),
                onPressed: () => Navigator.pop(dialogContext, at),
                child: const Text('确认挪动'),
              ),
            ],
          );
        },
      ),
    );
    if (chosen == null || !mounted) return;
    await attempt(() async {
      final at = await resolvePlannedTime(
        chosen,
        TimeOfDay(hour: chosen.hour, minute: chosen.minute),
      );
      await c.submit('block.move', {
        'id': block['id'],
        'version': block['version'],
        'start_at': at.toUtc().toIso8601String(),
        'end_at': at.add(duration).toUtc().toIso8601String(),
        if (block['kind'] != 'flexible') 'allow_fixed': true,
      });
      if (mounted) {
        message('已挪到 ${chosen.month}月${chosen.day}日 ${hm(chosen)}。');
      }
    });
  }

  /// 今天还没开始、排在本段之后的下一段。
  Json? nextBlockToday(Json block) {
    final opened = now;
    final today = tz.TZDateTime(zone, opened.year, opened.month, opened.day);
    final tomorrow = today.add(const Duration(days: 1));
    final start = DateTime.parse(block['start_at'] as String);
    final candidates = c.blocks.where((b) {
      if (b['id'] == block['id'] || b['status'] != 'scheduled') return false;
      final t = task(b['task_id']);
      if (t == null || ['done', 'cancelled', 'waiting'].contains(t['state'])) {
        return false;
      }
      final at = local(b['start_at']);
      return DateTime.parse(b['start_at'] as String).isAfter(start) &&
          !at.isBefore(today) &&
          at.isBefore(tomorrow);
    }).toList()..sort(
      (a, b) => DateTime.parse(
        a['start_at'] as String,
      ).compareTo(DateTime.parse(b['start_at'] as String)),
    );
    return candidates.firstOrNull;
  }

  /// 反馈之后只问一句「接下来干什么」，最多三个按钮。
  Future<void> nextStepDialog(Json block) async {
    if (c.activeSession != null) return;
    final next = nextBlockToday(block);
    if (next == null || !mounted) return;
    final at = local(next['start_at']);
    final action = await showOwnedDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('接下来做点什么？'),
        content: Text('${hm(at)} 还有「${next['title']}」。'),
        actions: [
          TextButton(
            key: const Key('action.next.dismiss'),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('先这样'),
          ),
          TextButton(
            key: const Key('action.next.break'),
            onPressed: () => Navigator.pop(dialogContext, 'break'),
            child: const Text('休息 10 分钟'),
          ),
          FilledButton(
            key: const Key('action.next.start'),
            onPressed: () => Navigator.pop(dialogContext, 'start'),
            child: const Text('立刻开始下一段'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'start') {
      await startBlock(next);
      return;
    }
    update(() => selectedBlock = next['id']);
    message('好，先歇十分钟。${hm(at)} 再开始「${next['title']}」。');
  }

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
    await attempt(() async {
      await c.startBlock(block, mode: mode);
      if (!mounted) return;
      update(() {
        page = 0;
        selectedBlock = block['id'];
      });
      unawaited(HapticFeedback.mediumImpact());
      final session = c.activeSession;
      showFocusEntry(
        context,
        block['title'],
        session == null
            ? '已进入专注'
            : '预计 ${hm(local(session['expected_end_at']))} 收尾 · 到点会提醒你',
      );
    });
  }

  Widget blockTile(Json block) {
    final t = task(block['task_id']);
    final s = session(block['id']);
    final span = blockSpan(block, s);
    final plannedStart = DateTime.parse(block['start_at'] as String);
    final plannedEnd = DateTime.parse(block['end_at'] as String);
    final start = hm(local(span.start.toIso8601String()));
    final end = hm(local(span.end.toIso8601String()));
    final differs =
        s != null && (span.start != plannedStart || span.end != plannedEnd);
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
                  start,
                  style: TextStyle(
                    fontFamily: 'WenKai',
                    fontSize: 16,
                    color: palette.inkJiao,
                  ),
                ),
                Text(
                  end,
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
            '${t?['outcome_criteria'] ?? '保护时段'}'
            '${differs ? '\n原定 ${hm(local(block['start_at']))}–${hm(local(block['end_at']))}' : ''}',
            maxLines: 3,
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
