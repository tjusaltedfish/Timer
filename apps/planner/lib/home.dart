import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import 'controller.dart';
import 'dialogs.dart';
import 'calendar.dart';
import 'week_calendar.dart';
import 'reminders.dart';

import 'formatting.dart';
import 'theme/tokens.dart';
import 'widgets/paper_background.dart';
import 'widgets/brush_divider.dart';
import 'widgets/ink_card.dart';
import 'widgets/seal.dart';
import 'widgets/enso_timer.dart';
import 'widgets/card_wheel.dart';
import 'widgets/ink_timeline.dart';
import 'widgets/sync_dot.dart';
part 'sheets/task_sheet.dart';
part 'sheets/inquiry_sheet.dart';
part 'sheets/replan_sheet.dart';
part 'sheets/block_detail_sheet.dart';
part 'sheets/waiting_sheet.dart';
part 'sheets/edit_task_sheet.dart';
part 'sheets/pair_sheet.dart';
part 'pages/tasks_page.dart';
part 'pages/week_page.dart';
part 'pages/settings_page.dart';
part 'pages/assistant_page.dart';
part 'pages/review_page.dart';
part 'pages/today_page.dart';
part 'widgets/home_layout.dart';
part 'widgets/block_card.dart';

class PlannerHome extends StatefulWidget {
  const PlannerHome({super.key, required this.controller, this.reminders});
  final PlannerController controller;
  final ReminderService? reminders;
  @override
  State<PlannerHome> createState() => _PlannerHomeState();
}

class _PlannerHomeState extends State<PlannerHome> with WidgetsBindingObserver {
  PlannerController get c => widget.controller;
  int page = 0;
  bool listMode = false;
  InkPalette get palette => context.inkPalette;
  Color get ink => palette.inkJiao;
  Color get green => palette.inkJiao;
  Map<String, Color> get projectColors => palette.projects;
  void update(VoidCallback change) => setState(change);
  Widget reviewPage() =>
      padded(ReviewPanel(controller: c, day: dateKey(selectedDay)));

  late DateTime selectedDay;
  String? selectedBlock;
  Timer? clock;
  int _clockMinute = -1;
  int _lastReminderSerial = 0;
  tz.Location get zone => tz.getLocation(c.settings['timezone'] as String);
  DateTime get now => tz.TZDateTime.now(zone);
  DateTime local(String value) =>
      tz.TZDateTime.from(DateTime.parse(value), zone);
  List<Json> get todaysBlocks => daySlices(
    c.blocks,
    selectedDay,
    zone,
  ).map((slice) => slice.block).toList();
  Json? task(String? id) => c.tasks.where((t) => t['id'] == id).firstOrNull;
  Json? session(String blockId) =>
      c.sessions.where((s) => s['block_id'] == blockId).lastOrNull;
  DateTime get monday => DateTime(
    selectedDay.year,
    selectedDay.month,
    selectedDay.day - selectedDay.weekday + 1,
  );
  @override
  void initState() {
    super.initState();
    final today = now;
    selectedDay = DateTime(today.year, today.month, today.day);
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (c.activeSession != null || now.minute != _clockMinute)) {
        _clockMinute = now.minute;
        update(() {});
      }
    });
    c.startPolling();
    WidgetsBinding.instance.addObserver(this);
    widget.reminders?.addListener(_openReminder);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openReminder());
  }

  @override
  void dispose() {
    clock?.cancel();
    widget.reminders?.removeListener(_openReminder);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(c.sync());
      final reminders = widget.reminders;
      if (reminders != null) unawaited(reminders.refresh(force: true));
    }
  }

  void _openReminder() {
    final reminders = widget.reminders;
    if (!mounted ||
        reminders == null ||
        reminders.openSerial == _lastReminderSerial ||
        reminders.lastOpen == null) {
      return;
    }
    final payload = reminders.lastOpen!;
    final block = c.blocks
        .where((b) => b['id'] == payload['block_id'])
        .firstOrNull;
    if (payload['block_id'] != null && block == null) return;
    _lastReminderSerial = reminders.openSerial;
    update(() {
      page = payload['page'] == 'tasks'
          ? 2
          : payload['page'] == 'review'
          ? 3
          : 0;
      if (block != null) {
        selectedBlock = block['id'];
        final date = local(block['start_at']);
        selectedDay = DateTime(date.year, date.month, date.day);
      }
      if (payload['date'] != null) {
        selectedDay = DateTime.tryParse(payload['date']) ?? selectedDay;
      }
    });
  }

  void message(Object error) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> attempt(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      message(error);
    }
  }

  String get utcNow => DateTime.now().toUtc().toIso8601String();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      c,
      if (widget.reminders != null) widget.reminders!,
    ]),
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 1000;
      final labels = ['今日', '一周', '诸事', '回顾', '助手'];
      final icons = [
        Icons.today_outlined,
        Icons.calendar_view_week_outlined,
        Icons.checklist_outlined,
        Icons.auto_stories_outlined,
        Icons.chat_bubble_outline,
      ];
      final content = [
        todayPage,
        weekPage,
        taskPage,
        reviewPage,
        assistantPage,
        settingsPage,
      ][page]();
      Widget navIcon(int i) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icons[i]),
          const SizedBox(height: 4),
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: page == i
                  ? palette.accent
                  : palette.accent.withValues(alpha: 0),
            ),
          ),
        ],
      );
      final title = page == 0
          ? '${selectedDay.month}月${selectedDay.day}日 · ${weekdays[selectedDay.weekday - 1]}'
          : page == 5
          ? '设置'
          : labels[page];
      return PaperBackground(
        child: Scaffold(
          backgroundColor: palette.paper.withValues(alpha: 0),
          body: SafeArea(
            child: Row(
              children: [
                if (wide)
                  SizedBox(
                    width: 88,
                    child: Column(
                      children: [
                        const SizedBox(height: 24),
                        const Seal('日程', label: '日程之间', size: 30),
                        const SizedBox(height: 32),
                        Expanded(
                          child: NavigationRail(
                            selectedIndex: page < 5 ? page : null,
                            minWidth: 88,
                            labelType: NavigationRailLabelType.all,
                            useIndicator: false,
                            onDestinationSelected: (value) =>
                                update(() => page = value),
                            destinations: List.generate(
                              5,
                              (i) => NavigationRailDestination(
                                icon: navIcon(i),
                                label: Text(labels[i]),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '设置',
                          onPressed: () => update(() => page = 5),
                          icon: const Icon(Icons.settings_outlined),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                Expanded(
                  child: Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 32 : 20,
                          20,
                          wide ? 32 : 12,
                          8,
                        ),
                        child: Row(
                          children: [
                            if (page == 5 && !wide)
                              IconButton(
                                tooltip: '返回今日',
                                onPressed: () => update(() => page = 0),
                                icon: const Icon(Icons.arrow_back),
                              ),
                            Expanded(
                              child: Text(
                                title,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                            ),
                            SyncDot(
                              connected: c.connected,
                              syncing: c.syncing,
                              conflict: c.conflict,
                              pending: c.pending.length,
                              error: c.connectionError,
                              onTap: () => syncDetails(),
                            ),
                            if (!wide && page != 5)
                              IconButton(
                                tooltip: '设置',
                                onPressed: () => update(() => page = 5),
                                icon: const Icon(Icons.settings_outlined),
                              ),
                          ],
                        ),
                      ),
                      if (c.conflict != null)
                        Container(
                          color: palette.inquiryWash,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            children: [
                              const Expanded(child: Text('同步需要处理，记录已保留。')),
                              TextButton(
                                onPressed: conflictDialog,
                                child: const Text('处理'),
                              ),
                            ],
                          ),
                        ),
                      Expanded(child: content),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: page < 5 ? page : 0,
                  onDestinationSelected: (value) => update(() => page = value),
                  destinations: List.generate(
                    5,
                    (i) => NavigationDestination(
                      icon: navIcon(i),
                      label: labels[i],
                    ),
                  ),
                ),
          floatingActionButton: page <= 2
              ? FloatingActionButton(
                  key: const Key('action.create'),
                  tooltip: '安排一件事',
                  onPressed: () => taskDialog(),
                  child: const Icon(Icons.add),
                )
              : null,
        ),
      );
    },
  );

  Future<void> syncDetails() async {
    await showOwnedDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('同步记录'),
        content: Text(
          c.conflict ??
              c.connectionError ??
              '${c.connected ? '已连接电脑' : '当前为本地记录'}\n${c.pending.length} 条待同步\n最近同步：${c.lastSync == null ? '尚未连接' : hm(tz.TZDateTime.from(c.lastSync!, zone))}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              attempt(c.sync);
            },
            child: const Text('立即同步'),
          ),
        ],
      ),
    );
  }
}
