part of '../home.dart';

extension _InquirySheet on _PlannerHomeState {
  Future<void> feedbackDialog(Json block) async {
    final s = session(block['id']);
    if (s == null) return;
    final text = TextEditingController();
    var choice = 'done', remaining = 30;
    final opened = now;
    var check = InkDateTimeWheel.ceilTo(
      opened.add(const Duration(hours: 2)),
      5,
    );
    var pickedWhen = '2 小时后';
    String? error;
    final t = task(block['task_id']);
    const choices = {
      'done': ('完成了', '达到了说好的结果'),
      'partial': ('部分完成', '还要再留些时间'),
      'waiting': ('等待结果', '交出去了，等回音'),
      'interrupted': ('被打断', '没能按计划进行'),
    };
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) {
          final p = context.inkPalette;
          DateTime wall(DateTime v) =>
              DateTime(v.year, v.month, v.day, v.hour, v.minute);
          final tonight = DateTime(opened.year, opened.month, opened.day, 20);
          final tomorrow = DateTime(
            opened.year,
            opened.month,
            opened.day + 1,
            9,
          );
          final quick = {
            '2 小时后': InkDateTimeWheel.ceilTo(
              wall(opened).add(const Duration(hours: 2)),
              5,
            ),
            if (tonight.isAfter(wall(opened).add(const Duration(minutes: 30))))
              '今晚 20:00': tonight,
            '明早 9:00': tomorrow,
          };
          return AlertDialog(
            title: const Text('这一段，进展如何？'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      block['title'],
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (t != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '说好的结果：${t['outcome_criteria']}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    const SizedBox(height: 16),
                    for (final row in [
                      choices.entries.take(2),
                      choices.entries.skip(2),
                    ]) ...[
                      Row(
                        children: [
                          for (final (i, entry) in row.indexed) ...[
                            if (i > 0) const SizedBox(width: 10),
                            Expanded(
                              child: _ChoiceTile(
                                key: ValueKey('feedback.${entry.key}'),
                                title: entry.value.$1,
                                hint: entry.value.$2,
                                selected: choice == entry.key,
                                onTap: () =>
                                    setDialog(() => choice = entry.key),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],
                    AnimatedSize(
                      duration: InkMetrics.micro,
                      alignment: Alignment.topCenter,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (choice == 'partial' ||
                              choice == 'interrupted') ...[
                            const SizedBox(height: 18),
                            Text(
                              '还需要多久？',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final m in [15, 30, 45, 60, 90, 120])
                                  ChoiceChip(
                                    label: Text('$m 分钟'),
                                    selected: remaining == m,
                                    onSelected: (_) =>
                                        setDialog(() => remaining = m),
                                  ),
                              ],
                            ),
                          ],
                          if (choice == 'waiting') ...[
                            const SizedBox(height: 18),
                            Text(
                              '什么时候去看结果？',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final entry in quick.entries)
                                  ChoiceChip(
                                    label: Text(entry.key),
                                    selected: pickedWhen == entry.key,
                                    onSelected: (_) => setDialog(() {
                                      pickedWhen = entry.key;
                                      check = entry.value;
                                    }),
                                  ),
                                ChoiceChip(
                                  label: const Text('自己挑'),
                                  selected: pickedWhen == 'custom',
                                  onSelected: (_) =>
                                      setDialog(() => pickedWhen = 'custom'),
                                ),
                              ],
                            ),
                            if (pickedWhen == 'custom')
                              Padding(
                                padding: const EdgeInsets.only(top: 14),
                                child: Center(
                                  child: InkDateTimeWheel(
                                    initial: check,
                                    today: opened,
                                    minimum: opened,
                                    days: 60,
                                    onChanged: (d, h, m) => check = DateTime(
                                      d.year,
                                      d.month,
                                      d.day,
                                      h,
                                      m,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: text,
                      maxLines: 2,
                      maxLength: 4000,
                      decoration: const InputDecoration(
                        labelText: '留下了什么，或卡在哪里（可选）',
                        hintText: '文件名、链接、数据，或一句卡点',
                      ),
                    ),
                    if (error != null)
                      Text(error!, style: TextStyle(color: p.accent)),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('稍后再说'),
              ),
              FilledButton(
                key: const Key('action.save-feedback'),
                onPressed: () async {
                  try {
                    tz.TZDateTime? checkAt;
                    if (choice == 'waiting') {
                      checkAt = await resolvePlannedTime(
                        check,
                        TimeOfDay(hour: check.hour, minute: check.minute),
                      );
                      if (!checkAt.isAfter(now)) {
                        throw ApiFailure('请选择一个还没到来的检查时间。', 422);
                      }
                    }
                    await c.submit('feedback.create', {
                      'session_id': s['id'],
                      'choice': choice,
                      'outcome_text': text.text.trim(),
                      if (choice == 'partial' || choice == 'interrupted')
                        'remaining_minutes': remaining,
                      if (checkAt != null)
                        'check_at': checkAt.toUtc().toIso8601String(),
                    });
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                    if ((choice == 'partial' || choice == 'interrupted') &&
                        mounted) {
                      await replanDialog(task(block['task_id'])!);
                    }
                  } catch (value) {
                    if (context.mounted) {
                      setDialog(() => error = value.toString());
                    }
                  }
                },
                child: const Text('记录这一段'),
              ),
            ],
          );
        },
      ),
    );
    text.dispose();
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    super.key,
    required this.title,
    required this.hint,
    required this.selected,
    required this.onTap,
  });
  final String title, hint;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.inkPalette;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? p.inkJiao : p.wash,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'WenKai',
                    fontSize: 17,
                    color: selected ? p.paper : p.inkJiao,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected
                        ? p.paper.withValues(alpha: .8)
                        : p.inkZhong,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
