part of '../home.dart';

/// The user's own categories: create, rename, archive. Nothing is built in.
extension _CategorySheet on _PlannerHomeState {
  Future<String?> askCategoryName({String? initial, String title = '新的分类'}) {
    final name = TextEditingController(text: initial ?? '');
    return showOwnedDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: name,
            autofocus: true,
            maxLength: 30,
            decoration: const InputDecoration(
              labelText: '名字',
              hintText: '例如：读论文、健身、找工作',
            ),
            onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, name.text.trim()),
            child: const Text('好'),
          ),
        ],
      ),
    ).whenComplete(name.dispose);
  }

  /// Returns the new category id, or null when cancelled or rejected.
  Future<String?> createCategory() async {
    final name = await askCategoryName();
    if (name == null || name.isEmpty) return null;
    final id = const Uuid().v4();
    try {
      await c.submit('project.create', {'id': id, 'name': name});
      return id;
    } catch (error) {
      message(error);
      return null;
    }
  }

  Widget categoriesPanel() {
    final theme = Theme.of(context);
    final active = c.activeProjects;
    final archived = c.projects.where((p) => p['archived'] == true).toList();
    return SizedBox(
      width: double.infinity,
      child: InkCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('分类', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('按你自己的方式归类；不归类也完全可以。', style: theme.textTheme.bodySmall),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in active)
                  InputChip(
                    avatar: CircleAvatar(
                      backgroundColor: markOf(item['id']),
                      radius: 5,
                    ),
                    label: Text(item['name']),
                    onPressed: () async {
                      final name = await askCategoryName(
                        initial: item['name'],
                        title: '重命名分类',
                      );
                      if (name == null ||
                          name.isEmpty ||
                          name == item['name']) {
                        return;
                      }
                      await attempt(
                        () => c.submit('project.update', {
                          'id': item['id'],
                          'name': name,
                        }),
                      );
                    },
                    deleteIcon: const Icon(
                      Icons.inventory_2_outlined,
                      size: 16,
                    ),
                    deleteButtonTooltipMessage: '归档（已有任务保留原分类）',
                    onDeleted: () => attempt(
                      () => c.submit('project.update', {
                        'id': item['id'],
                        'archived': true,
                      }),
                    ),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('新分类'),
                  onPressed: createCategory,
                ),
              ],
            ),
            if (archived.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('已归档', style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in archived)
                    ActionChip(
                      label: Text('${item['name']} · 恢复'),
                      onPressed: () => attempt(
                        () => c.submit('project.update', {
                          'id': item['id'],
                          'archived': false,
                        }),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Category picker used by the task forms; null means "不归类".
  Widget categoryChips(String? selected, ValueChanged<String?> onChanged) =>
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ChoiceChip(
            label: const Text('不归类'),
            selected: selected == null,
            onSelected: (_) => onChanged(null),
          ),
          for (final item in c.activeProjects)
            ChoiceChip(
              label: Text(item['name']),
              selected: selected == item['id'],
              onSelected: (_) => onChanged(item['id']),
            ),
          ActionChip(
            avatar: const Icon(Icons.add, size: 16),
            label: const Text('新分类'),
            onPressed: () async {
              final id = await createCategory();
              if (id != null) onChanged(id);
            },
          ),
        ],
      );
}
