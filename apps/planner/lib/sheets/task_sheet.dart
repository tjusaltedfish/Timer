part of '../home.dart';

extension _TaskSheet on _PlannerHomeState {
  Future<void> taskDialog({Json? existing}) async {
    final name = TextEditingController(text: existing?['title'] ?? '');
    final goal = TextEditingController(
      text: existing?['outcome_criteria'] ?? '',
    );
    var date = DateTime(selectedDay.year, selectedDay.month, selectedDay.day);
    var start = const TimeOfDay(hour: 9, minute: 0);
    var minutes = 60, project = existing?['project_id'] as String? ?? 'code';
    var fixed = false, protected = false, saving = false;
    String? error;
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(existing == null ? '安排一件有结果的事' : '继续安排这项任务'),
          content: SizedBox(
            width: 450,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (existing == null) ...[
                    TextField(
                      controller: name,
                      maxLength: 200,
                      decoration: const InputDecoration(labelText: '任务名称'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: goal,
                      maxLines: 2,
                      maxLength: 2000,
                      decoration: const InputDecoration(labelText: '完成标准'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: project,
                      decoration: const InputDecoration(labelText: '项目'),
                      items: c.projects
                          .map(
                            (p) => DropdownMenuItem(
                              value: p['id'] as String,
                              child: Text(p['name']),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => project = v!,
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final value = await showDatePicker(
                              context: context,
                              initialDate: date,
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                            );
                            if (value != null) setDialog(() => date = value);
                          },
                          child: Text('${date.month}/${date.day}'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final value = await showTimePicker(
                              context: context,
                              initialTime: start,
                            );
                            if (value != null) setDialog(() => start = value);
                          },
                          child: Text(start.format(context)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: minutes,
                    decoration: const InputDecoration(labelText: '本次投入'),
                    items: [15, 30, 45, 60, 90, 120, 180]
                        .map(
                          (m) =>
                              DropdownMenuItem(value: m, child: Text('$m 分钟')),
                        )
                        .toList(),
                    onChanged: (v) => minutes = v!,
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: fixed,
                    title: const Text('固定预约'),
                    onChanged: protected
                        ? null
                        : (v) => setDialog(() => fixed = v!),
                  ),
                  if (existing == null)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: protected,
                      title: const Text('这是用餐、休息等保护时段'),
                      onChanged: (v) => setDialog(() {
                        protected = v!;
                        if (protected) fixed = false;
                      }),
                    ),
                  if (error != null)
                    Text(error!, style: TextStyle(color: palette.accent)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('action.save-task'),
              onPressed: saving
                  ? null
                  : () async {
                      if (existing == null &&
                          (name.text.trim().isEmpty ||
                              (!protected && goal.text.trim().isEmpty))) {
                        setDialog(() => error = '请填写名称和完成标准。');
                        return;
                      }
                      setDialog(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        final begin = await resolvePlannedTime(date, start);
                        final end = begin.add(Duration(minutes: minutes));
                        if (c.blocks.any(
                          (b) =>
                              b['status'] == 'scheduled' &&
                              begin.isBefore(DateTime.parse(b['end_at'])) &&
                              end.isAfter(DateTime.parse(b['start_at'])),
                        )) {
                          throw ApiFailure('与已有安排冲突，请换一个时间。', 409);
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
                            'remaining_minutes': minutes,
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
                        if (mounted) selectDate(date);
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
              child: Text(saving ? '保存中…' : '保存安排'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    goal.dispose();
  }
}
