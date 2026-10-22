part of '../home.dart';

extension _HomeLayout on _PlannerHomeState {
  Widget heading(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
  Widget padded(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1400),
      child: Padding(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 600 ? 20 : 32,
        ),
        child: child,
      ),
    ),
  );
  Widget panel(Widget child) => SizedBox(
    width: double.infinity,
    child: InkCard(child: child),
  );
  void selectDate(DateTime date) => update(() {
    selectedDay = DateTime(date.year, date.month, date.day);
    _followingToday = dateKey(selectedDay) == dateKey(now);
    selectedBlock = null;
  });
  Widget dateStrip() => GestureDetector(
    onHorizontalDragEnd: (details) {
      if ((details.primaryVelocity ?? 0).abs() > 100) {
        selectDate(
          DateTime(
            selectedDay.year,
            selectedDay.month,
            selectedDay.day + (details.primaryVelocity! < 0 ? 7 : -7),
          ),
        );
      }
    },
    child: Row(
      children: List.generate(7, (i) {
        final date = DateTime(monday.year, monday.month, monday.day + i);
        final selected = dateKey(date) == dateKey(selectedDay);
        final today = dateKey(date) == dateKey(now);
        return Expanded(
          child: Semantics(
            selected: selected,
            button: true,
            label:
                '${date.month}月${date.day}日 ${weekdays[i]}${today ? ' 今天' : ''}${selected ? ' 已选中' : ''}',
            child: InkWell(
              key: ValueKey('day.${dateKey(date)}'),
              onTap: () => selectDate(date),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? palette.inkJiao : null,
                  borderRadius: BorderRadius.circular(12),
                  border: today && !selected
                      ? Border.all(color: palette.inkZhong)
                      : null,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      today ? '今天' : weekdays[i].replaceFirst('周', ''),
                      style: TextStyle(
                        fontSize: 11,
                        color: selected ? palette.paper : palette.inkZhong,
                      ),
                    ),
                    Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: 18,
                        color: selected ? palette.paper : palette.inkJiao,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    ),
  );

  Widget weekNav() => Row(
    children: [
      IconButton(
        tooltip: '上一周',
        onPressed: () => selectDate(monday.subtract(const Duration(days: 7))),
        icon: const Icon(Icons.chevron_left),
      ),
      Expanded(
        child: Text(
          '${monday.month}月${monday.day}日 — ${monday.add(const Duration(days: 6)).month}月${monday.add(const Duration(days: 6)).day}日',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      TextButton(onPressed: () => selectDate(now), child: const Text('今天')),
      IconButton(
        tooltip: '下一周',
        onPressed: () => selectDate(monday.add(const Duration(days: 7))),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
}
