part of '../home.dart';

extension _FocusPanel on _PlannerHomeState {
  Widget focusPanel(Json active) {
    final block = c.blocks.firstWhere((b) => b['id'] == active['block_id']);
    final paused = active['state'] == 'paused';
    final end = DateTime.parse(active['expected_end_at']);
    final expired = !paused && !end.isAfter(c.nowUtc);
    final label = paused
        ? '专注已暂停'
        : expired
        ? '本段时间到了'
        : '正在专注';
    final anchor = paused ? DateTime.parse(active['paused_at']) : c.nowUtc;
    final seconds = end.difference(anchor).inSeconds.clamp(0, 864000);
    final minutes = seconds ~/ 60;
    return InkCard(
      key: const Key('focus.panel'),
      focused: true,
      child: LayoutBuilder(
        builder: (context, bounds) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Seal(
                  paused
                      ? '歇'
                      : expired
                      ? '问'
                      : '今',
                  label: label,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '待办操作',
                  onSelected: (value) {
                    final t = task(block['task_id']);
                    if (t == null) return;
                    value == 'edit' ? editTask(t) : deleteTask(t);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑待办')),
                    PopupMenuItem(value: 'delete', child: Text('删除待办')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              block['title'],
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (bounds.maxHeight > 360) ...[
              const SizedBox(height: 8),
              Text(
                task(block['task_id'])?['outcome_criteria'] ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}',
                        key: const Key('focus.remaining'),
                        style: TextStyle(
                          fontFamily: 'WenKai',
                          fontSize: 64,
                          height: 1.2,
                          color: palette.inkJiao,
                        ),
                      ),
                      Text(
                        expired
                            ? '记录结果，或再给自己一点时间'
                            : '预计 ${hm(local(active['expected_end_at']))} 收尾',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            blockActions(block),
          ],
        ),
      ),
    );
  }
}
