import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import 'controller.dart';
import 'dialogs.dart';
import 'calendar.dart';
import 'week_calendar.dart';
import 'widgets/week_overview.dart';
import 'reminders.dart';
import 'updates.dart';

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
import 'widgets/ink_wheel_picker.dart';
import 'desktop/desktop_window.dart';
import 'desktop/title_bar.dart';
part 'sheets/task_sheet.dart';
part 'sheets/inquiry_sheet.dart';
part 'sheets/replan_sheet.dart';
part 'sheets/block_detail_sheet.dart';
part 'sheets/waiting_sheet.dart';
part 'sheets/edit_task_sheet.dart';
part 'sheets/pair_sheet.dart';
part 'sheets/category_sheet.dart';
part 'sheets/sleep_sheet.dart';
part 'pages/tasks_page.dart';
part 'pages/week_page.dart';
part 'pages/settings_page.dart';
part 'pages/assistant_page.dart';
part 'pages/assistant_settings.dart';
part 'pages/wechat_settings.dart';
part 'pages/review_page.dart';
part 'pages/today_page.dart';
part 'pages/widget_page.dart';
part 'widgets/home_layout.dart';
part 'widgets/block_card.dart';
part 'widgets/adjustment_notice.dart';
part 'widgets/focus_panel.dart';
part 'widgets/update_banner.dart';

class PlannerHome extends StatefulWidget {
  const PlannerHome({
    super.key,
    required this.controller,
    this.reminders,
    this.updates,
  });
  final PlannerController controller;
  final ReminderService? reminders;
  final UpdateService? updates;
  @override
  State<PlannerHome> createState() => _PlannerHomeState();
}

class _PlannerHomeState extends State<PlannerHome> with WidgetsBindingObserver {
  PlannerController get c => widget.controller;
  DesktopWindow get desktop => DesktopWindow.instance;
  int page = 0;
  bool listMode = false;
  bool weekDetail = false;
  InkPalette get palette => context.inkPalette;
  Color get ink => palette.inkJiao;
  Color get green => palette.inkJiao;

  /// Category mark: the user's categories take the grey marks in order.
  Color? markOf(String? projectId) {
    if (projectId == null) return null;
    final index = c.projects.indexWhere((p) => p['id'] == projectId);
    return index < 0 ? null : palette.marks[index % palette.marks.length];
  }

  Color? blockMark(Json block) => markOf(task(block['task_id'])?['project_id']);
  String? categoryName(String? projectId) =>
      c.projects.where((p) => p['id'] == projectId).firstOrNull?['name'];
  void update(VoidCallback change) => setState(change);
  Widget reviewPage() => padded(
    Column(
      children: [
        sleepSummary(),
        const SizedBox(height: 20),
        Expanded(
          child: ReviewPanel(controller: c, day: dateKey(selectedDay)),
        ),
      ],
    ),
  );

  late DateTime selectedDay;
  String? selectedBlock;
  Timer? clock;
  int _clockMinute = -1;
  int _lastReminderSerial = 0;
  final _seenAdjustments = <String>{};
  tz.Location get zone => tz.getLocation(c.settings['timezone'] as String);
  DateTime get now => tz.TZDateTime.from(c.nowUtc, zone);
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
      if (mounted &&
          (page == 0 ||
              c.activeSession != null ||
              now.minute != _clockMinute)) {
        _clockMinute = now.minute;
        update(() {});
      }
    });
    c.startPolling();
    c.addListener(_onAdjustment);
    WidgetsBinding.instance.addObserver(this);
    widget.reminders?.addListener(_openReminder);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openReminder());
    if (widget.updates?.supported ?? false) {
      unawaited(widget.updates!.check());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAdjustment());
  }

  @override
  void dispose() {
    clock?.cancel();
    c.removeListener(_onAdjustment);
    widget.reminders?.removeListener(_openReminder);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (widget.updates?.supported ?? false) {
        unawaited(widget.updates!.check());
      }
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

  String get utcNow => c.nowUtc.toIso8601String();

  String get greeting {
    final h = now.hour;
    return h < 5
        ? '夜深了'
        : h < 11
        ? '早上好'
        : h < 13
        ? '中午好'
        : h < 18
        ? '下午好'
        : '晚上好';
  }

  String get daySummary {
    final items = todaysBlocks.where((b) => b['kind'] != 'protected').toList();
    final today = dateKey(selectedDay) == dateKey(now);
    if (!today) {
      return items.isEmpty
          ? '${weekdays[selectedDay.weekday - 1]}还空着'
          : '${weekdays[selectedDay.weekday - 1]} · ${items.length} 件安排';
    }
    final left = items
        .where(
          (b) => b['status'] == 'scheduled' && local(b['end_at']).isAfter(now),
        )
        .length;
    if (items.isEmpty) return '$greeting，今天还空着，想做点什么？';
    if (left == 0) return '$greeting，今天的安排都落定了，留点时间给自己。';
    return '$greeting，今天还有 $left 件事，一件一件来。';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      c,
      if (widget.reminders != null) widget.reminders!,
      if (widget.updates != null) widget.updates!,
      desktop.changes,
    ]),
    builder: (context, _) {
      if (desktop.enabled && desktop.widgetMode.value) return widgetShell();
      final size = MediaQuery.sizeOf(context);
      final compact = size.width < 600;
      final wide = size.width >= 1000;
      const labels = ['今日', '一周', '诸事', '回顾', '助手'];
      const icons = [
        Icons.wb_twilight_outlined,
        Icons.calendar_view_week_outlined,
        Icons.format_list_bulleted,
        Icons.auto_stories_outlined,
        Icons.forum_outlined,
      ];
      const selectedIcons = [
        Icons.wb_twilight,
        Icons.calendar_view_week,
        Icons.format_list_bulleted,
        Icons.auto_stories,
        Icons.forum,
      ];
      final content = [
        todayPage,
        weekPage,
        taskPage,
        reviewPage,
        assistantPage,
        settingsPage,
      ][page]();
      final title = page == 0
          ? '日程之间'
          : page == 5
          ? '设置'
          : labels[page];
      final header = Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 20 : 28,
          desktop.enabled ? 4 : 16,
          compact ? 8 : 20,
          4,
        ),
        child: Row(
          children: [
            if (page == 5 && compact)
              IconButton(
                tooltip: '返回今日',
                onPressed: () => update(() => page = 0),
                icon: const Icon(Icons.arrow_back),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ],
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
            if (compact && page != 5)
              IconButton(
                tooltip: '设置',
                onPressed: () => update(() => page = 5),
                icon: const Icon(Icons.tune),
              ),
          ],
        ),
      );
      final body = Column(
        children: [
          header,
          updateBanner(),
          if (c.conflict != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Material(
                color: palette.inquiryWash,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Row(
                    children: [
                      const Expanded(child: Text('同步需要处理，本地记录都还在。')),
                      TextButton(
                        onPressed: conflictDialog,
                        child: const Text('处理'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: AnimatedSwitcher(
              duration: context.stillMotion
                  ? Duration.zero
                  : InkMetrics.transition,
              switchInCurve: InkMetrics.settle,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, .015),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: KeyedSubtree(key: ValueKey(page), child: content),
            ),
          ),
        ],
      );
      final rail = SizedBox(
        width: wide ? 92 : 80,
        child: Column(
          children: [
            SizedBox(height: desktop.enabled ? 8 : 28),
            if (!desktop.enabled) ...[
              const Seal('日程', label: '日程之间', size: 28),
              const SizedBox(height: 24),
            ],
            Expanded(
              child: NavigationRail(
                selectedIndex: page < 5 ? page : null,
                minWidth: wide ? 92 : 80,
                labelType: NavigationRailLabelType.all,
                groupAlignment: -.9,
                onDestinationSelected: (value) => update(() => page = value),
                destinations: List.generate(
                  5,
                  (i) => NavigationRailDestination(
                    icon: Icon(icons[i]),
                    selectedIcon: Icon(selectedIcons[i]),
                    label: Text(labels[i]),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '设置',
              isSelected: page == 5,
              onPressed: () => update(() => page = 5),
              icon: const Icon(Icons.tune),
            ),
            const SizedBox(height: 20),
          ],
        ),
      );
      return PaperBackground(
        child: Scaffold(
          backgroundColor: palette.paper.withValues(alpha: 0),
          body: SafeArea(
            bottom: !compact,
            child: Column(
              children: [
                if (desktop.enabled)
                  InkTitleBar(title: page == 0 ? null : title),
                Expanded(
                  child: Row(
                    children: [
                      if (!compact) rail,
                      Expanded(child: body),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: compact
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        palette.paper.withValues(alpha: 0),
                        palette.paper.withValues(alpha: .94),
                        palette.paper,
                      ],
                      stops: const [0, .3, 1],
                    ),
                  ),
                  child: NavigationBar(
                    selectedIndex: page < 5 ? page : 0,
                    labelBehavior:
                        NavigationDestinationLabelBehavior.alwaysShow,
                    onDestinationSelected: (value) =>
                        update(() => page = value),
                    destinations: List.generate(
                      5,
                      (i) => NavigationDestination(
                        icon: Icon(icons[i]),
                        selectedIcon: Icon(selectedIcons[i]),
                        label: labels[i],
                      ),
                    ),
                  ),
                )
              : null,
          floatingActionButton: page <= 2
              ? compact
                    ? FloatingActionButton(
                        key: const Key('action.create'),
                        tooltip: '安排一件事',
                        onPressed: () => taskDialog(),
                        child: const Icon(Icons.add),
                      )
                    : FloatingActionButton.extended(
                        key: const Key('action.create'),
                        tooltip: '安排一件事',
                        onPressed: () => taskDialog(),
                        icon: const Icon(Icons.add),
                        label: const Text('安排一件事'),
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
