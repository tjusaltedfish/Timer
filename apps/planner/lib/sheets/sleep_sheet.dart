part of '../home.dart';

String sleepLength(Json sleep, [DateTime? until]) {
  final end = sleep['woke_at'] == null
      ? (until ?? DateTime.now())
      : DateTime.parse(sleep['woke_at']);
  final minutes = end.difference(DateTime.parse(sleep['slept_at'])).inMinutes;
  return minutes < 60
      ? '$minutes 分钟'
      : '${minutes ~/ 60} 小时${minutes % 60 == 0 ? '' : ' ${minutes % 60} 分'}';
}

const sleepQuality = ['很差', '一般', '还行', '不错', '很好'];

/// Sleep you record yourself: "去睡了" / "醒了" in the moment, or fill in a
/// past night. Times can never be in the future.
extension _SleepSheet on _PlannerHomeState {
  Json? get lastNight {
    final done = c.sleeps.where((s) => s['woke_at'] != null).toList()
      ..sort((a, b) => a['woke_at'].compareTo(b['woke_at']));
    return done.lastOrNull;
  }

  Future<void> goToSleep() => attempt(
    () => c.submit('sleep.log', {'id': const Uuid().v4(), 'slept_at': utcNow}),
  );

  Future<void> wakeUp(Json open) async {
    await attempt(
      () => c.submit('sleep.log', {
        'id': open['id'],
        'slept_at': open['slept_at'],
        'woke_at': utcNow,
        if (open['quality'] != null) 'quality': open['quality'],
        'note': open['note'] ?? '',
      }),
    );
    final saved = c.sleeps.where((s) => s['id'] == open['id']).firstOrNull;
    if (!mounted || saved == null || saved['woke_at'] == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$greeting，睡了 ${sleepLength(saved)}。'),
        action: SnackBarAction(
          label: '评一下',
          onPressed: () => sleepDialog(existing: saved),
        ),
      ),
    );
  }

  /// Today page strip: sleeping now, a bedtime nudge, or last night.
  Widget sleepBar() {
    final theme = Theme.of(context);
    final open = c.openSleep;
    final hour = now.hour;
    final last = lastNight;
    final lastIsRecent =
        last != null &&
        now.difference(DateTime.parse(last['woke_at'])).inHours < 18;
    Widget pill(IconData icon, String text, VoidCallback onTap, {Key? key}) =>
        ActionChip(
          key: key,
          avatar: Icon(icon, size: 17),
          label: Text(text),
          onPressed: onTap,
        );
    if (open != null) {
      return Material(
        color: palette.wash,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.bedtime_outlined, size: 20, color: palette.inkZhong),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${hm(local(open['slept_at']))} 睡下，已经 ${sleepLength(open)}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              FilledButton(
                key: const Key('sleep.wake'),
                onPressed: () => wakeUp(open),
                child: const Text('醒了'),
              ),
            ],
          ),
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (hour >= 20 || hour < 4)
          pill(
            Icons.bedtime_outlined,
            '去睡了',
            goToSleep,
            key: const Key('sleep.start'),
          ),
        if (lastIsRecent)
          pill(
            Icons.nights_stay_outlined,
            '昨晚睡了 ${sleepLength(last)}'
            '${last['quality'] == null ? '' : ' · ${sleepQuality[last['quality'] - 1]}'}',
            () => sleepDialog(existing: last),
          )
        else if (hour >= 4 && hour < 20)
          pill(Icons.nights_stay_outlined, '记一下昨晚的睡眠', () => sleepDialog()),
      ],
    );
  }

  Future<void> sleepDialog({Json? existing}) async {
    final current = now;
    DateTime wall(DateTime v) =>
        DateTime(v.year, v.month, v.day, v.hour, v.minute);
    final nowWall = wall(current);
    var slept = existing == null
        ? DateTime(nowWall.year, nowWall.month, nowWall.day - 1, 23, 30)
        : wall(local(existing['slept_at']));
    var woke = existing?['woke_at'] == null
        ? (existing == null
              ? DateTime(nowWall.year, nowWall.month, nowWall.day, 7, 30)
              : nowWall)
        : wall(local(existing!['woke_at']));
    if (woke.isAfter(nowWall)) woke = nowWall;
    if (!slept.isBefore(woke)) slept = woke.subtract(const Duration(hours: 7));
    int? quality = existing?['quality'];
    final note = TextEditingController(text: existing?['note'] ?? '');
    String? error;
    final firstDay = DateTime(nowWall.year, nowWall.month, nowWall.day - 13);
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(existing == null ? '记一下睡眠' : '这一觉'),
          content: ConstrainedBox(
            constraints: sheetBodyConstraints(context),
            child: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label('什么时候睡下'),
                    Center(
                      child: InkDateTimeWheel(
                        key: const Key('sleep.slept'),
                        initial: slept,
                        today: nowWall,
                        firstDay: firstDay,
                        days: 14,
                        maximum: nowWall,
                        onChanged: (d, h, m) =>
                            slept = DateTime(d.year, d.month, d.day, h, m),
                      ),
                    ),
                    label('什么时候醒来'),
                    Center(
                      child: InkDateTimeWheel(
                        key: const Key('sleep.woke'),
                        initial: woke,
                        today: nowWall,
                        firstDay: firstDay,
                        days: 14,
                        maximum: nowWall,
                        onChanged: (d, h, m) =>
                            woke = DateTime(d.year, d.month, d.day, h, m),
                      ),
                    ),
                    label('睡得怎么样（可不填）'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < 5; i++)
                          ChoiceChip(
                            label: Text(sleepQuality[i]),
                            selected: quality == i + 1,
                            onSelected: (on) =>
                                setDialog(() => quality = on ? i + 1 : null),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: note,
                      maxLength: 500,
                      decoration: const InputDecoration(
                        labelText: '备注（可不填）',
                        hintText: '半夜醒了一次、睡前喝了咖啡…',
                      ),
                    ),
                    if (error != null)
                      Text(error!, style: TextStyle(color: palette.accent)),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () async {
                  await attempt(
                    () => c.submit('sleep.delete', {'id': existing['id']}),
                  );
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                },
                child: const Text('删掉这条'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('算了'),
            ),
            FilledButton(
              key: const Key('sleep.save'),
              onPressed: () async {
                try {
                  final a = await resolvePlannedTime(
                    slept,
                    TimeOfDay(hour: slept.hour, minute: slept.minute),
                  );
                  final b = await resolvePlannedTime(
                    woke,
                    TimeOfDay(hour: woke.hour, minute: woke.minute),
                  );
                  final hours = b.difference(a).inMinutes / 60;
                  if (hours <= 0) {
                    throw ApiFailure('醒来要晚于睡下。', 422);
                  }
                  if (hours > 20) {
                    throw ApiFailure('一次睡眠不超过 20 小时，看看日期是不是选错了。', 422);
                  }
                  if (b.isAfter(now)) {
                    throw ApiFailure('还没到来的时刻不能记录。', 422);
                  }
                  await c.submit('sleep.log', {
                    'id': existing?['id'] ?? const Uuid().v4(),
                    'slept_at': a.toUtc().toIso8601String(),
                    'woke_at': b.toUtc().toIso8601String(),
                    'quality': ?quality,
                    'note': note.text.trim(),
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (value) {
                  if (context.mounted) setDialog(() => error = '$value');
                }
              },
              child: const Text('记下'),
            ),
          ],
        ),
      ),
    );
    note.dispose();
  }

  /// Review page: last night plus the seven-night average.
  Widget sleepSummary() {
    final theme = Theme.of(context);
    final week = c.sleeps
        .where(
          (s) =>
              s['woke_at'] != null &&
              now.difference(DateTime.parse(s['woke_at'])).inDays < 7,
        )
        .toList();
    final minutes = week.fold<int>(
      0,
      (sum, s) =>
          sum +
          DateTime.parse(s['woke_at'])
              .difference(DateTime.parse(s['slept_at']))
              .inMinutes,
    );
    final last = lastNight;
    return InkCard(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
      child: Row(
        children: [
          Icon(Icons.nights_stay_outlined, color: palette.inkZhong),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  last == null
                      ? '还没有睡眠记录'
                      : '最近一觉 ${hm(local(last['slept_at']))}–${hm(local(last['woke_at']))} · ${sleepLength(last)}',
                  style: theme.textTheme.titleSmall,
                ),
                if (week.isNotEmpty)
                  Text(
                    '近七天记了 ${week.length} 次，平均 ${(minutes / week.length / 60).toStringAsFixed(1)} 小时',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          TextButton(onPressed: () => sleepDialog(), child: const Text('补记')),
        ],
      ),
    );
  }
}
