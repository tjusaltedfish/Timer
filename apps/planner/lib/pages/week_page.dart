part of '../home.dart';

extension _WeekPage on _PlannerHomeState {
  Widget weekPage() => MediaQuery.sizeOf(context).width < 600
      ? padded(
          MobileWeekView(
            blocks: c.blocks,
            tasks: c.tasks,
            sessions: c.sessions,
            zone: zone,
            now: now,
            selectedDay: selectedDay,
            dayStart: c.settings['day_start'],
            dayEnd: c.settings['day_end'],
            weekNav: weekNav(),
            detail: weekDetail,
            onDetailChanged: (detail) => update(() => weekDetail = detail),
            onSelectDay: selectDate,
            onBlockTap: blockDetails,
            onPlan: () => taskDialog(),
            detailBuilder: _weekGrid,
          ),
        )
      : SingleChildScrollView(
          child: padded(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                weekNav(),
                const SizedBox(height: 8),
                _weekGrid(1),
                const SizedBox(height: 70),
              ],
            ),
          ),
        );

  /// 桌面（和手机「详细课表」）用的整周 hour 网格；[zoom] 为 1 时行为与以前一致。
  Widget _weekGrid(double zoom) => WeekCalendar(
    blocks: c.blocks,
    tasks: c.tasks,
    sessions: c.sessions,
    zone: zone,
    selectedDay: selectedDay,
    now: now,
    markOf: blockMark,
    zoom: zoom,
    onSlotPicked: (start, minutes) => taskDialog(start: start, minutes: minutes),
    dayStart: c.settings['day_start'],
    dayEnd: c.settings['day_end'],
    onSelectDay: selectDate,
    onBlockTap: blockDetails,
  );

  Future<tz.TZDateTime> resolvePlannedTime(
    DateTime date,
    TimeOfDay time,
  ) async {
    final candidates = localTimeCandidates(date, time.hour, time.minute, zone);
    if (candidates.isEmpty) throw ApiFailure('该本地时间因夏令时切换而不存在，请选择其他时间。', 422);
    if (candidates.length == 1) return candidates.single;
    final chosen = await showOwnedDialog<tz.TZDateTime>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('这个时间出现两次，请选择'),
        children: candidates
            .map(
              (value) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, value),
                child: Text(
                  '${hm(value)} · ${utcOffset(value.timeZoneOffset)}',
                ),
              ),
            )
            .toList(),
      ),
    );
    if (chosen == null) throw ApiFailure('时间尚未确认。', 422);
    return chosen;
  }
}
