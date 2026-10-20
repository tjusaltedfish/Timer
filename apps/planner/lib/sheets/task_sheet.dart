part of '../home.dart';

extension _TaskSheet on _PlannerHomeState {
  /// New task (or another segment of [existing]). [start]/[minutes] come from
  /// a slot picked on the calendar; past moments are never accepted.
  Future<void> taskDialog({
    Json? existing,
    DateTime? start,
    int? minutes,
  }) async {
    final name = TextEditingController(text: existing?['title'] ?? '');
    final goal = TextEditingController(
      text: existing?['outcome_criteria'] ?? '',
    );
    final current = now;
    final earliest = InkDateTimeWheel.ceilTo(
      current.add(const Duration(seconds: 1)),
      5,
    );
    DateTime initial;
    if (start != null) {
      final wall = tz.TZDateTime.from(start, zone);
      initial = DateTime(
        wall.year,
        wall.month,
        wall.day,
        wall.hour,
        wall.minute,
      );
    } else if (dateKey(selectedDay).compareTo(dateKey(current)) > 0) {
      final parts = (c.settings['day_start'] as String).split(':');
      initial = DateTime(
        selectedDay.year,
        selectedDay.month,
        selectedDay.day,
        int.parse(parts[0]),
        int.parse(parts[1]),
      );
    } else {
      initial = earliest;
    }
    if (initial.isBefore(earliest)) initial = earliest;
    var day = DateTime(initial.year, initial.month, initial.day);
    var hour = initial.hour, minute = initial.minute;
    const durations = [15, 30, 45, 60, 90, 120, 180];
    var length = minutes ?? 60;
    String? project = existing?['project_id'] as String?;
    var fixed = false, protected = false, saving = false;
    String? error;
    final p = palette;
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(
            existing == null ? '落一笔有结果的事' : '再为「${existing['title']}」留一段',
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (existing == null) ...[
                    TextField(
                      controller: name,
                      maxLength: 200,
                      decoration: InputDecoration(
                        labelText: protected ? '这段时间留给' : '要做的事',
                        hintText: protected ? '午饭、散步、小憩…' : '例如：整理参数扫描脚本',
                      ),
                    ),
                    if (!protected) ...[
                      const SizedBox(height: 4),
                      TextField(
                        controller: goal,
                        maxLines: 2,
                        maxLength: 2000,
                        decoration: const InputDecoration(
                          labelText: '做到什么程度算完成',
                          hintText: '可以检验的结果，例如：输出一份可复现的 CSV',
                        ),
                      ),
                      label('归到哪一类（可不选）'),
                      categoryChips(
                        project,
                        (value) => setDialog(() => project = value),
                      ),
                    ],
                  ],
                  label('何时开始'),
                  Center(
                    child: InkDateTimeWheel(
                      key: const Key('task.when'),
                      initial: initial,
                      today: current,
                      minimum: current,
                      onChanged: (d, h, m) {
                        day = d;
                        hour = h;
                        minute = m;
                      },
                    ),
                  ),
                  label('留多久'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final m in {...durations, length}.toList()..sort())
                        ChoiceChip(
                          label: Text(
                            m < 60 || m % 60 != 0
                                ? m >= 60
                                      ? '${m ~/ 60} 小时 ${m % 60} 分'
                                      : '$m 分钟'
                                : '${m ~/ 60} 小时',
                          ),
                          selected: length == m,
                          onSelected: (_) => setDialog(() => length = m),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilterChip(
                        label: const Text('固定预约 · 不会被挪动'),
                        selected: fixed,
                        onSelected: protected
                            ? null
                            : (v) => setDialog(() => fixed = v),
                      ),
                      if (existing == null)
                        FilterChip(
                          label: const Text('留给吃饭、休息'),
                          selected: protected,
                          onSelected: (v) => setDialog(() {
                            protected = v;
                            if (protected) fixed = false;
                          }),
                        ),
                    ],
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(error!, style: TextStyle(color: p.accent)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('先不了'),
            ),
            FilledButton(
              key: const Key('action.save-task'),
              onPressed: saving
                  ? null
                  : () async {
                      if (existing == null &&
                          (name.text.trim().isEmpty ||
                              (!protected && goal.text.trim().isEmpty))) {
                        setDialog(
                          () => error = protected
                              ? '给这段时间起个名字吧。'
                              : '写下要做的事，和做到什么程度算完成。',
                        );
                        return;
                      }
                      setDialog(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        final begin = await resolvePlannedTime(
                          day,
                          TimeOfDay(hour: hour, minute: minute),
                        );
                        if (!begin.isAfter(now)) {
                          throw ApiFailure('这个时刻已经过去了，换一个还没到来的时间吧。', 422);
                        }
                        final end = begin.add(Duration(minutes: length));
                        if (c.blocks.any(
                          (b) =>
                              b['status'] == 'scheduled' &&
                              begin.isBefore(DateTime.parse(b['end_at'])) &&
                              end.isAfter(DateTime.parse(b['start_at'])),
                        )) {
                          throw ApiFailure('这段时间已经有安排了，换一个时间吧。', 409);
                        }
                        final taskId = protected
                            ? null
                            : existing?['id'] ?? const Uuid().v4();
                        if (!protected && existing == null) {
                          await c.submit('task.create', {
                            'id': taskId,
                            'title': name.text.trim(),
                            'outcome_criteria': goal.text.trim(),
                            'project_id': project,
                            'remaining_minutes': length,
                          });
                        }
                        await c.submit('block.create', {
                          'id': const Uuid().v4(),
                          'task_id': taskId,
                          'title': protected
                              ? name.text.trim()
                              : existing?['title'] ?? name.text.trim(),
                          'start_at': begin.toUtc().toIso8601String(),
                          'end_at': end.toUtc().toIso8601String(),
                          'timezone': zone.name,
                          'kind': protected
                              ? 'protected'
                              : fixed
                              ? 'fixed'
                              : 'flexible',
                        });
                        if (mounted) selectDate(day);
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (value) {
                        if (context.mounted) {
                          setDialog(() {
                            error = value.toString();
                            saving = false;
                          });
                        }
                      }
                    },
              child: Text(saving ? '落笔中…' : '保存安排'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    goal.dispose();
  }
}
