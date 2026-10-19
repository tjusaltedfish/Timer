part of '../home.dart';

extension _TodayPage on _PlannerHomeState {
  Widget todayPage() {
    final items = todaysBlocks;
    final focus =
        items.where((b) => b['id'] == selectedBlock).firstOrNull ??
        items
            .where(
              (b) => [
                'running',
                'paused',
                'awaiting_feedback',
              ].contains(session(b['id'])?['state']),
            )
            .firstOrNull ??
        items
            .where(
              (b) =>
                  b['status'] == 'scheduled' && local(b['end_at']).isAfter(now),
            )
            .firstOrNull ??
        items.lastOrNull;
    final awaiting = c.sessions
        .where((s) => s['state'] == 'awaiting_feedback')
        .toList();
    final ids = items.map((b) => b['id']).join('|');
    Widget empty() => Center(
      child: InkCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '今日尚空。先落一笔有结果的事。',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('action.first-task'),
              onPressed: () => taskDialog(),
              icon: const Icon(Icons.add),
              label: const Text('安排第一件事'),
            ),
          ],
        ),
      ),
    );
    Widget wheel() => items.isEmpty
        ? empty()
        : CardWheel(
            key: ValueKey('${dateKey(selectedDay)}|$ids'),
            count: items.length,
            minimumCardHeight: c.activeSession == null ? 300 : 440,
            initial: items.indexOf(focus!),
            onFocus: (i) => selectedBlock = items[i]['id'],
            onActivate: (i) => activateBlock(items[i]),
            builder: (_, i, focused) => focusCard(items[i], focused: focused),
          );
    Widget listing() => items.isEmpty
        ? empty()
        : ListView(
            children: [
              for (final block in items) blockTile(block),
              const SizedBox(height: 80),
            ],
          );
    return padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          dateStrip(),
          if (awaiting.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Material(
                color: palette.inquiryWash,
                child: ListTile(
                  dense: true,
                  leading: const Seal('问', label: '待回话'),
                  title: Text('待回话 ${awaiting.length} 段 · 点此回答'),
                  onTap: () {
                    final b = c.blocks
                        .where((b) => b['id'] == awaiting.first['block_id'])
                        .firstOrNull;
                    if (b != null) feedbackDialog(b);
                  },
                ),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('此刻', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton(
                onPressed: () => update(() => listMode = false),
                child: Text(listMode ? '轮盘' : '轮盘 ·'),
              ),
              TextButton(
                onPressed: () => update(() => listMode = true),
                child: Text(listMode ? '列表 ·' : '列表'),
              ),
            ],
          ),
          const BrushDivider(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, bounds) {
                if (MediaQuery.sizeOf(context).width < 1000) {
                  return listMode ? listing() : wheel();
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: listMode ? listing() : wheel()),
                    const SizedBox(width: 32),
                    Expanded(
                      flex: 7,
                      child: InkTimeline(
                        blocks: items,
                        tasks: c.tasks,
                        zone: zone,
                        day: selectedDay,
                        now: now,
                        dayStart: c.settings['day_start'],
                        dayEnd: c.settings['day_end'],
                        onBlockTap: blockDetails,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
