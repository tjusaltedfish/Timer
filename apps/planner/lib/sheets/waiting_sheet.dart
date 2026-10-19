part of '../home.dart';

extension _WaitingSheet on _PlannerHomeState {
  Future<void> resolveWaiting(Json check) async {
    final outcome = TextEditingController();
    var resolution = 'done', minutes = 30;
    String? error;
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('核对返回的结果'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(task(check['task_id'])?['outcome_criteria'] ?? ''),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('达到标准，确认完成'),
                        selected: resolution == 'done',
                        onSelected: (_) => setDialog(() => resolution = 'done'),
                      ),
                      ChoiceChip(
                        label: const Text('还需继续投入'),
                        selected: resolution == 'ready',
                        onSelected: (_) =>
                            setDialog(() => resolution = 'ready'),
                      ),
                    ],
                  ),
                  if (resolution == 'ready')
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: DropdownButtonFormField<int>(
                        initialValue: minutes,
                        decoration: const InputDecoration(labelText: '剩余工作量'),
                        items: [15, 30, 45, 60, 90, 120]
                            .map(
                              (n) => DropdownMenuItem(
                                value: n,
                                child: Text('$n 分钟'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => minutes = v!,
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: outcome,
                    maxLines: 2,
                    maxLength: 4000,
                    decoration: const InputDecoration(labelText: '结果说明（可选）'),
                  ),
                  if (error != null) Text(error!),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('稍后核对'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await c.submit('waiting.resolve', {
                    'id': check['id'],
                    'resolution': resolution,
                    'outcome_text': outcome.text.trim(),
                    if (resolution == 'ready') 'remaining_minutes': minutes,
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (e) {
                  if (context.mounted) setDialog(() => error = e.toString());
                }
              },
              child: const Text('保存结果'),
            ),
          ],
        ),
      ),
    );
    outcome.dispose();
  }
}
