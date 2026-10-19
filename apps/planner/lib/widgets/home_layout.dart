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
  Widget panel(Widget child, {Color? color}) => SizedBox(
    width: double.infinity,
    child: InkCard(child: child),
  );
  Widget chip(String text, String? id) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 2,
        height: 16,
        color: palette.projects[id] ?? palette.inkQing,
      ),
      const SizedBox(width: 8),
      Text(text, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
  void selectDate(DateTime date) => update(() {
    selectedDay = DateTime(date.year, date.month, date.day);
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
    child: Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '上一周',
              onPressed: () =>
                  selectDate(monday.subtract(const Duration(days: 7))),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${monday.month}月${monday.day}日 — ${monday.add(const Duration(days: 6)).month}月${monday.add(const Duration(days: 6)).day}日',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: () => selectDate(now),
              child: const Text('今天'),
            ),
            IconButton(
              tooltip: '下一周',
              onPressed: () => selectDate(monday.add(const Duration(days: 7))),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Row(
          children: List.generate(7, (i) {
            final date = monday.add(Duration(days: i));
            final selected = dateKey(date) == dateKey(selectedDay);
            return Expanded(
              child: Semantics(
                selected: selected,
                button: true,
                label: '${date.month}月${date.day}日 ${weekdays[i]}',
                child: InkWell(
                  onTap: () => selectDate(date),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      children: [
                        Text(
                          weekdays[i],
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          '${date.day}',
                          style: TextStyle(
                            fontFamily: 'WenKai',
                            fontSize: 24,
                            color: palette.inkJiao,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected
                                ? palette.accent
                                : palette.accent.withValues(alpha: 0),
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
      ],
    ),
  );
}
