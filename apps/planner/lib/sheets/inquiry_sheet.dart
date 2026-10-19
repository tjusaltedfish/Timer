part of '../home.dart';

extension _InquirySheet on _PlannerHomeState {
  Future<void> feedbackDialog(Json block) async {
    final s = session(block['id']);
    if (s == null) return;
    final text = TextEditingController();
    var choice = 'done', remaining = 30;
    var check = now.add(const Duration(hours: 2));
    String? error;
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('这一段，进展如何？'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(block['title']),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        {
                              'done': '完成了',
                              'partial': '部分完成',
                              'waiting': '等待结果',
                              'interrupted': '被打断',
                            }.entries
                            .map(
                              (entry) => ChoiceChip(
                                key: ValueKey('feedback.${entry.key}'),
                                label: Text(entry.value),
                                selected: choice == entry.key,
                                onSelected: (_) =>
                                    setDialog(() => choice = entry.key),
                              ),
                            )
                            .toList(),
                  ),
                  if (choice == 'partial')
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: DropdownButtonFormField<int>(
                        initialValue: remaining,
                        decoration: const InputDecoration(labelText: '预计还需投入'),
                        items: [15, 30, 45, 60, 90, 120]
                            .map(
                              (m) => DropdownMenuItem(
                                value: m,
                                child: Text('$m 分钟'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => remaining = v!,
                      ),
                    ),
                  if (choice == 'waiting')
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: check,
                            firstDate: DateTime(now.year, now.month, now.day),
                            lastDate: DateTime(2100),
                          );
                          if (date == null || !context.mounted) return;
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(check),
                          );
                          if (time != null) {
                            try {
                              final value = await resolvePlannedTime(
                                date,
                                time,
                              );
                              if (context.mounted) {
                                setDialog(() => check = value);
                              }
                            } catch (value) {
                              if (context.mounted) {
                                setDialog(() => error = value.toString());
                              }
                            }
                          }
                        },
                        icon: const Icon(Icons.schedule),
                        label: Text(
                          '下次检查 ${check.month}/${check.day} ${hm(check)}',
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: text,
                    maxLines: 2,
                    maxLength: 4000,
                    decoration: const InputDecoration(labelText: '结果或卡点（可选）'),
                  ),
                  if (error != null)
                    Text(error!, style: TextStyle(color: palette.accent)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('稍后反馈'),
            ),
            FilledButton(
              key: const Key('action.save-feedback'),
              onPressed: () async {
                try {
                  if (choice == 'waiting' && !check.isAfter(now)) {
                    throw ApiFailure('请选择未来的检查时间。', 422);
                  }
                  await c.submit('feedback.create', {
                    'session_id': s['id'],
                    'choice': choice,
                    'outcome_text': text.text.trim(),
                    if (choice == 'partial') 'remaining_minutes': remaining,
                    if (choice == 'waiting')
                      'check_at': check.toUtc().toIso8601String(),
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (choice == 'partial' && mounted) {
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
        ),
      ),
    );
    text.dispose();
  }
}
