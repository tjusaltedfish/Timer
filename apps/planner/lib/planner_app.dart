import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import 'controller.dart';
import 'dialogs.dart';

const ink = Color(0xff20382e),
    green = Color(0xff245a43),
    paper = Color(0xfff5f4ef);
const projectColors = {
  'code': Color(0xff2c7050),
  'learn': Color(0xffa95e32),
  'fab': Color(0xff536b88),
  'personal': Color(0xff71658a),
};
const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
String hm(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
String dateKey(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
String taskState(String? value) =>
    {
      'ready': '可执行',
      'in_progress': '进行中',
      'waiting': '等待结果',
      'review': '待验收',
      'done': '已完成',
      'cancelled': '已取消',
    }[value] ??
    '未确认';

class PlannerApp extends StatelessWidget {
  const PlannerApp({super.key, required this.controller});
  final PlannerController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '日程之间',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(seedColor: green, surface: paper),
      fontFamily: 'Microsoft YaHei UI',
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding: const EdgeInsets.all(14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: green,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    ),
    home: PlannerHome(controller: controller),
  );
}

class PlannerHome extends StatefulWidget {
  const PlannerHome({super.key, required this.controller});
  final PlannerController controller;
  @override
  State<PlannerHome> createState() => _PlannerHomeState();
}

class _PlannerHomeState extends State<PlannerHome> {
  PlannerController get c => widget.controller;
  int page = 0;
  late DateTime selectedDay;
  String? selectedBlock;
  Timer? clock;
  tz.Location get zone => tz.getLocation(c.settings['timezone'] as String);
  DateTime get now => tz.TZDateTime.now(zone);
  DateTime local(String value) =>
      tz.TZDateTime.from(DateTime.parse(value), zone);
  List<Json> get todaysBlocks =>
      c.blocks
          .where(
            (b) =>
                !['superseded', 'cancelled'].contains(b['status']) &&
                dateKey(local(b['start_at'])) == dateKey(selectedDay),
          )
          .toList()
        ..sort(
          (a, b) =>
              a['start_at'].toString().compareTo(b['start_at'].toString()),
        );
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
    selectedDay = now;
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && c.activeSession != null) setState(() {});
    });
    c.startPolling();
  }

  @override
  void dispose() {
    clock?.cancel();
    super.dispose();
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
    animation: c,
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 1000;
      final labels = ['今天', '一周课表', '任务与等待', '日终回顾', '助手', '连接与设置'];
      final icons = [
        Icons.today_outlined,
        Icons.calendar_view_week_outlined,
        Icons.checklist_rounded,
        Icons.auto_stories_outlined,
        Icons.auto_awesome_outlined,
        Icons.settings_outlined,
      ];
      final content = [
        todayPage,
        weekPage,
        taskPage,
        reviewPage,
        assistantPage,
        settingsPage,
      ][page]();
      return Scaffold(
        appBar: AppBar(
          title: Text(
            wide ? '工作台 / ${labels[page]}' : '日程之间 · ${labels[page]}',
            style: const TextStyle(fontSize: 16),
          ),
          actions: [
            Tooltip(
              message:
                  c.conflict ??
                  c.connectionError ??
                  '最近同步 ${c.lastSync == null ? '尚未连接' : hm(c.lastSync!.toLocal())}',
              child: TextButton.icon(
                onPressed: () => attempt(c.sync),
                icon: Icon(
                  c.syncing
                      ? Icons.sync
                      : c.connected
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                  size: 18,
                ),
                label: Text(
                  c.pending.isNotEmpty
                      ? '${c.pending.length} 条待同步'
                      : c.connected
                      ? '已同步'
                      : '本地记录',
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Row(
          children: [
            if (wide)
              NavigationRail(
                selectedIndex: page,
                extended: true,
                backgroundColor: const Color(0xffedf0e7),
                leading: const Padding(
                  padding: EdgeInsets.fromLTRB(12, 20, 30, 32),
                  child: Text(
                    '◷  日程之间',
                    style: TextStyle(fontSize: 24, color: ink),
                  ),
                ),
                onDestinationSelected: (value) => setState(() => page = value),
                destinations: List.generate(
                  labels.length,
                  (i) => NavigationRailDestination(
                    icon: Icon(icons[i]),
                    label: Text(labels[i]),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                children: [
                  if (c.conflict != null)
                    MaterialBanner(
                      content: Text('同步需要处理：${c.conflict}'),
                      actions: [
                        TextButton(
                          onPressed: conflictDialog,
                          child: const Text('查看并处理'),
                        ),
                      ],
                    ),
                  Expanded(child: content),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: page,
                onDestinationSelected: (value) => setState(() => page = value),
                destinations: List.generate(
                  labels.length,
                  (i) => NavigationDestination(
                    icon: Icon(icons[i]),
                    label: ['今天', '课表', '任务', '回顾', '助手', '设置'][i],
                  ),
                ),
              ),
        floatingActionButton: page <= 2
            ? FloatingActionButton.extended(
                onPressed: () => taskDialog(),
                icon: const Icon(Icons.add),
                label: const Text('安排一件事'),
              )
            : null,
      );
    },
  );

  Widget heading(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w500,
            color: ink,
          ),
        ),
        const SizedBox(height: 8),
        Text(subtitle, style: const TextStyle(color: Color(0xff647068))),
      ],
    ),
  );
  Widget padded(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1220),
      child: Padding(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 600 ? 16 : 30,
        ),
        child: child,
      ),
    ),
  );
  Widget dateStrip() => Column(
    children: [
      Row(
        children: [
          IconButton(
            onPressed: () =>
                selectDate(selectedDay.subtract(const Duration(days: 7))),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Text(
              '${monday.month} 月 ${monday.day} 日 — ${monday.add(const Duration(days: 6)).month} 月 ${monday.add(const Duration(days: 6)).day} 日',
              textAlign: TextAlign.center,
            ),
          ),
          TextButton(onPressed: () => selectDate(now), child: const Text('今天')),
          IconButton(
            onPressed: () =>
                selectDate(selectedDay.add(const Duration(days: 7))),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      Row(
        children: List.generate(7, (i) {
          final date = monday.add(Duration(days: i));
          final isSelected = dateKey(date) == dateKey(selectedDay);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => selectDate(date),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? green : const Color(0xffe9ede2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      Text(
                        weekdays[i],
                        style: TextStyle(
                          fontSize: 11,
                          color: isSelected ? Colors.white : ink,
                        ),
                      ),
                      Text(
                        '${date.day}',
                        style: TextStyle(
                          fontSize: 22,
                          fontFamily: 'Georgia',
                          color: isSelected ? Colors.white : ink,
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
  );
  void selectDate(DateTime date) => setState(() {
    selectedDay = date;
    selectedBlock = null;
  });

  Widget todayPage() {
    final items = todaysBlocks;
    final focus =
        items.where((b) => b['id'] == selectedBlock).firstOrNull ??
        items.where((b) => b['status'] == 'scheduled').firstOrNull ??
        items.firstOrNull;
    final index = focus == null ? -1 : items.indexOf(focus);
    return SingleChildScrollView(
      child: padded(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading(
              '把今天，过得有着落。',
              '${selectedDay.month} 月 ${selectedDay.day} 日 · ${weekdays[selectedDay.weekday - 1]} · ${c.settings['timezone']}',
            ),
            dateStrip(),
            const SizedBox(height: 22),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '眼前这一件',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: index > 0
                      ? () => setState(
                          () => selectedBlock = items[index - 1]['id'],
                        )
                      : null,
                  icon: const Icon(Icons.arrow_back),
                ),
                IconButton(
                  onPressed: index >= 0 && index < items.length - 1
                      ? () => setState(
                          () => selectedBlock = items[index + 1]['id'],
                        )
                      : null,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
            if (focus == null)
              panel(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('这一天，还留着空间。', style: TextStyle(fontSize: 23)),
                    const SizedBox(height: 12),
                    const Text('先安排一件有明确结果的事，也给休息留个位置。'),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: () => taskDialog(),
                      icon: const Icon(Icons.add),
                      label: const Text('安排第一件事'),
                    ),
                  ],
                ),
              )
            else
              focusCard(focus),
            if (index >= 0 && index + 1 < items.length)
              Opacity(
                opacity: .65,
                child: ListTile(
                  onTap: () =>
                      setState(() => selectedBlock = items[index + 1]['id']),
                  title: Text(
                    '下一项 · ${items[index + 1]['title']}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Text(hm(local(items[index + 1]['start_at']))),
                ),
              ),
            const SizedBox(height: 22),
            const Text('今天的安排', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final block in items) blockTile(block),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '◌  空白也是计划的一部分。',
                style: TextStyle(color: Color(0xff647068)),
              ),
            ),
            const SizedBox(height: 64),
          ],
        ),
      ),
    );
  }

  Widget panel(Widget child, {Color? color}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: color ?? Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xffdce3d6)),
    ),
    child: child,
  );

  Widget focusCard(Json block) {
    final t = task(block['task_id']);
    final s = session(block['id']);
    final state = s?['state'];
    final remaining = s == null
        ? null
        : DateTime.parse(s['expected_end_at'])
              .difference(DateTime.now())
              .inSeconds;
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      child: Container(
        key: ValueKey('${block['id']}-${s?['state']}'),
        child: panel(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  chip(
                    block['kind'] == 'protected'
                        ? '保护时段'
                        : projectName(t?['project_id']),
                    t?['project_id'],
                  ),
                  Text(
                    '${hm(local(block['start_at']))} — ${hm(local(block['end_at']))}',
                    style: const TextStyle(fontFamily: 'Georgia', fontSize: 17),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                block['title'],
                style: const TextStyle(fontSize: 24, color: ink),
              ),
              const SizedBox(height: 12),
              Text(
                t?['outcome_criteria'] ?? '为生活和休息留出的时间。',
                style: const TextStyle(height: 1.8),
              ),
              const SizedBox(height: 20),
              if (state == 'running' || state == 'paused') ...[
                Text(
                  state == 'paused'
                      ? '已暂停计时'
                      : remaining! <= 0
                      ? '时间到了，记录一下进展吧。'
                      : '剩余 ${(remaining ~/ 60).toString().padLeft(2, '0')}:${(remaining % 60).toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton(
                      onPressed: () => attempt(
                        () => c.submit(
                          state == 'paused'
                              ? 'session.resume'
                              : 'session.pause',
                          {'id': s!['id'], 'occurred_at': utcNow},
                        ),
                      ),
                      child: Text(state == 'paused' ? '继续这一段' : '暂停'),
                    ),
                    OutlinedButton(
                      onPressed: () => attempt(() async {
                        await c.submit('session.end', {
                          'id': s!['id'],
                          'occurred_at': utcNow,
                        });
                        if (mounted) await feedbackDialog(block);
                      }),
                      child: const Text('结束并反馈'),
                    ),
                  ],
                ),
              ] else if (state == 'awaiting_feedback')
                FilledButton(
                  onPressed: () => feedbackDialog(block),
                  child: const Text('补充结果反馈'),
                )
              else if (t != null &&
                  block['status'] == 'scheduled' &&
                  t['state'] != 'done')
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: () => attempt(
                        () => c.submit('session.start', {
                          'id': const Uuid().v4(),
                          'block_id': block['id'],
                          'occurred_at': utcNow,
                        }),
                      ),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('开始这一段'),
                    ),
                    TextButton(
                      onPressed: () => attempt(
                        () => c.submit('feedback.create', {
                          'block_id': block['id'],
                          'choice': 'not_started',
                        }),
                      ),
                      child: const Text('这段没有开始'),
                    ),
                  ],
                )
              else
                Text(
                  s == null
                      ? block['kind'] == 'protected'
                            ? '保护时段'
                            : taskState(t?['state'])
                      : '本段已记录',
                ),
            ],
          ),
          color: const Color(0xffedf2e7),
        ),
      ),
    );
  }

  String projectName(String? id) =>
      c.projects.where((p) => p['id'] == id).firstOrNull?['name'] ?? '个人安排';
  Widget chip(String text, String? id) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: (projectColors[id] ?? green).withValues(alpha: .10),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: projectColors[id] ?? green),
    ),
  );

  Widget blockTile(Json block) {
    final t = task(block['task_id']);
    final s = session(block['id']);
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 6),
          onTap: () => blockDetails(block),
          leading: SizedBox(
            width: 56,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    hm(local(block['start_at'])),
                    maxLines: 1,
                    style: const TextStyle(fontFamily: 'Georgia', fontSize: 17),
                  ),
                ),
                Text(
                  hm(local(block['end_at'])),
                  maxLines: 1,
                  style: const TextStyle(fontSize: 10),
                ),
              ],
            ),
          ),
          title: Text(block['title'], style: const TextStyle(fontSize: 14)),
          subtitle: Text(
            t?['outcome_criteria'] ?? '保护时段',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          trailing: Text(
            s?['state'] == 'awaiting_feedback'
                ? '待反馈'
                : s?['state'] == 'running'
                ? '进行中'
                : block['kind'] == 'fixed'
                ? '固定'
                : block['status'] == 'completed'
                ? '已记录'
                : '',
            style: const TextStyle(fontSize: 11),
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Future<void> blockDetails(Json block) async {
    final t = task(block['task_id']);
    await showOwnedDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(block['title']),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${dateKey(local(block['start_at']))}  ${hm(local(block['start_at']))}—${hm(local(block['end_at']))}',
              ),
              const SizedBox(height: 14),
              Text(t?['outcome_criteria'] ?? '保护时段'),
              if (t != null) ...[
                const SizedBox(height: 12),
                Text(
                  '状态：${taskState(t['state'])} · 剩余投入 ${t['remaining_minutes']} 分钟',
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (t != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                replanDialog(t);
              },
              child: const Text('弹性调整'),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                selectedDay = local(block['start_at']);
                selectedBlock = block['id'];
                page = 0;
              });
            },
            child: const Text('查看卡片'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> taskDialog({Json? existing}) async {
    final name = TextEditingController(text: existing?['title'] ?? '');
    final goal = TextEditingController(
      text: existing?['outcome_criteria'] ?? '',
    );
    var date = DateTime(selectedDay.year, selectedDay.month, selectedDay.day);
    var start = const TimeOfDay(hour: 9, minute: 0);
    var minutes = 60, project = existing?['project_id'] as String? ?? 'code';
    var fixed = false, protected = false, saving = false;
    String? error;
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(existing == null ? '安排一件有结果的事' : '继续安排这项任务'),
          content: SizedBox(
            width: 450,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (existing == null) ...[
                    TextField(
                      controller: name,
                      maxLength: 200,
                      decoration: const InputDecoration(labelText: '任务名称'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: goal,
                      maxLines: 2,
                      maxLength: 2000,
                      decoration: const InputDecoration(labelText: '完成标准'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: project,
                      decoration: const InputDecoration(labelText: '项目'),
                      items: c.projects
                          .map(
                            (p) => DropdownMenuItem(
                              value: p['id'] as String,
                              child: Text(p['name']),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => project = v!,
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final value = await showDatePicker(
                              context: context,
                              initialDate: date,
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                            );
                            if (value != null) setDialog(() => date = value);
                          },
                          child: Text('${date.month}/${date.day}'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final value = await showTimePicker(
                              context: context,
                              initialTime: start,
                            );
                            if (value != null) setDialog(() => start = value);
                          },
                          child: Text(start.format(context)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: minutes,
                    decoration: const InputDecoration(labelText: '本次投入'),
                    items: [15, 30, 45, 60, 90, 120, 180]
                        .map(
                          (m) =>
                              DropdownMenuItem(value: m, child: Text('$m 分钟')),
                        )
                        .toList(),
                    onChanged: (v) => minutes = v!,
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: fixed,
                    title: const Text('固定预约'),
                    onChanged: protected
                        ? null
                        : (v) => setDialog(() => fixed = v!),
                  ),
                  if (existing == null)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: protected,
                      title: const Text('这是用餐、休息等保护时段'),
                      onChanged: (v) => setDialog(() {
                        protected = v!;
                        if (protected) fixed = false;
                      }),
                    ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (existing == null &&
                          (name.text.trim().isEmpty ||
                              (!protected && goal.text.trim().isEmpty))) {
                        setDialog(() => error = '请填写名称和完成标准。');
                        return;
                      }
                      setDialog(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        final begin = tz.TZDateTime(
                          zone,
                          date.year,
                          date.month,
                          date.day,
                          start.hour,
                          start.minute,
                        );
                        final end = begin.add(Duration(minutes: minutes));
                        if (c.blocks.any(
                          (b) =>
                              b['status'] == 'scheduled' &&
                              begin.isBefore(DateTime.parse(b['end_at'])) &&
                              end.isAfter(DateTime.parse(b['start_at'])),
                        )) {
                          throw ApiFailure('与已有安排冲突，请换一个时间。', 409);
                        }
                        final taskId = protected
                            ? null
                            : existing?['id'] ?? const Uuid().v4();
                        if (!protected && existing == null) {
                          await c.submit('task.create', {
                            'id': taskId,
                            'title': name.text.trim(),
                            'outcome_criteria': goal.text.trim(),
                            'project_id': project,
                            'remaining_minutes': minutes,
                          });
                        }
                        await c.submit('block.create', {
                          'id': const Uuid().v4(),
                          'task_id': taskId,
                          'title': protected
                              ? name.text.trim()
                              : existing?['title'] ?? name.text.trim(),
                          'start_at': begin.toUtc().toIso8601String(),
                          'end_at': end.toUtc().toIso8601String(),
                          'timezone': zone.name,
                          'kind': protected
                              ? 'protected'
                              : fixed
                              ? 'fixed'
                              : 'flexible',
                        });
                        if (mounted) selectDate(date);
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (value) {
                        if (context.mounted) {
                          setDialog(() {
                            error = value.toString();
                            saving = false;
                          });
                        }
                      }
                    },
              child: Text(saving ? '保存中…' : '保存安排'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    goal.dispose();
  }

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
                            setDialog(
                              () => check = tz.TZDateTime(
                                zone,
                                date.year,
                                date.month,
                                date.day,
                                time.hour,
                                time.minute,
                              ),
                            );
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
                    Text(error!, style: const TextStyle(color: Colors.red)),
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

  Future<void> replanDialog(Json t) async {
    await attempt(() async {
      final from = now.toUtc();
      final plan = await c.onlineRequest('/api/v1/plan/proposals', {
        'task_id': t['id'],
        'from_at': from.toIso8601String(),
        'until_at': from.add(const Duration(days: 7)).toIso8601String(),
      });
      if (!mounted) return;
      final confirmed = await showOwnedDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('给剩余工作找个位置'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(plan['reason']),
                  const SizedBox(height: 14),
                  for (final b in plan['new_blocks'] as List)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(b['title']),
                      subtitle: Text(
                        '${dateKey(local(b['start_at']))}  ${hm(local(b['start_at']))}—${hm(local(b['end_at']))}',
                      ),
                    ),
                  for (final item in plan['unscheduled_items'] as List)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        '尚未安排：${item['title']} ${item['minutes']} 分钟\n${item['reason']}',
                        style: const TextStyle(color: Colors.deepOrange),
                      ),
                    ),
                  const Text(
                    '固定预约、保护时段和已有执行记录保留。',
                    style: TextStyle(color: green),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('先保持原样'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('应用调整'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await c.applyProposal(plan['id']);
        message('已更新安排。');
      }
    });
  }

  Widget weekPage() => SingleChildScrollView(
    child: padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading('一周，有安排也有留白。', '点击时间块查看结果标准。固定预约与保护时段会保留。'),
          dateStrip(),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              final days = constraints.maxWidth < 650
                  ? [selectedDay]
                  : List.generate(7, (i) => monday.add(Duration(days: i)));
              return GestureDetector(
                onHorizontalDragEnd: (details) {
                  if ((details.primaryVelocity ?? 0).abs() > 100) {
                    selectDate(
                      selectedDay.add(
                        Duration(days: details.primaryVelocity! < 0 ? 1 : -1),
                      ),
                    );
                  }
                },
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 42,
                      child: Column(
                        children: [
                          const SizedBox(height: 48),
                          for (var hour = 0; hour < 24; hour++)
                            SizedBox(
                              height: 60,
                              child: Text(
                                '${hour.toString().padLeft(2, '0')}:00',
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                        ],
                      ),
                    ),
                    for (final date in days)
                      Expanded(
                        child: Column(
                          children: [
                            SizedBox(
                              height: 48,
                              child: Center(
                                child: Text(
                                  '${weekdays[date.weekday - 1]} ${date.day}',
                                ),
                              ),
                            ),
                            SizedBox(
                              height: 1440,
                              child: Stack(
                                children: [
                                  for (var i = 0; i < 24; i++)
                                    Positioned(
                                      top: i * 60,
                                      left: 0,
                                      right: 0,
                                      child: const Divider(height: 1),
                                    ),
                                  for (final block in c.blocks.where(
                                    (b) =>
                                        ![
                                          'superseded',
                                          'cancelled',
                                        ].contains(b['status']) &&
                                        dateKey(local(b['start_at'])) ==
                                            dateKey(date),
                                  ))
                                    Positioned(
                                      top:
                                          local(block['start_at']).hour * 60.0 +
                                          local(block['start_at']).minute,
                                      left: 3,
                                      right: 3,
                                      height: DateTime.parse(block['end_at'])
                                          .difference(
                                            DateTime.parse(block['start_at']),
                                          )
                                          .inMinutes
                                          .toDouble()
                                          .clamp(18, 1440)
                                          .toDouble(),
                                      child: Material(
                                        color: block['kind'] == 'protected'
                                            ? const Color(0xffe5e5df)
                                            : (projectColors[task(
                                                        block['task_id'],
                                                      )?['project_id']] ??
                                                      green)
                                                  .withValues(alpha: .14),
                                        borderRadius: BorderRadius.circular(7),
                                        child: InkWell(
                                          onTap: () => blockDetails(block),
                                          borderRadius: BorderRadius.circular(
                                            7,
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(5),
                                            child: Text(
                                              '${hm(local(block['start_at']))}${block['kind'] == 'fixed' ? ' ⌑' : ''}\n${block['title']}',
                                              overflow: TextOverflow.fade,
                                              style: const TextStyle(
                                                fontSize: 10,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 70),
        ],
      ),
    ),
  );

  Widget taskPage() => SingleChildScrollView(
    child: padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading('每件事，都有下一步。', '任务目标、已经投入的时间和等待结果分别记录。'),
          if (c.tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('还没有任务，先安排一件具体的事。'),
            ),
          for (final t in c.tasks.reversed)
            Card(
              color: Colors.white,
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            t['title'],
                            style: const TextStyle(fontSize: 17),
                          ),
                        ),
                        chip(taskState(t['state']), t['project_id']),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(t['outcome_criteria'] ?? ''),
                    const SizedBox(height: 8),
                    Text(
                      '剩余投入 ${t['remaining_minutes'] ?? 0} 分钟',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (!['done', 'cancelled'].contains(t['state'])) ...[
                          TextButton(
                            onPressed: () => taskDialog(existing: t),
                            child: const Text('安排下一段'),
                          ),
                          TextButton(
                            onPressed: () => replanDialog(t),
                            child: const Text('弹性安排'),
                          ),
                        ],
                        TextButton(
                          onPressed: () => editTask(t),
                          child: const Text('编辑任务'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 70),
        ],
      ),
    ),
  );

  Future<void> editTask(Json t) async {
    final title = TextEditingController(text: t['title']),
        goal = TextEditingController(text: t['outcome_criteria']);
    String? error;
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('编辑任务'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: '任务名称'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: goal,
                  maxLines: 3,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '完成标准'),
                ),
                if (error != null) Text(error!),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('返回'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  await c.submit('task.update', {
                    'id': t['id'],
                    'version': t['version'],
                    'state': ['done', 'cancelled'].contains(t['state'])
                        ? 'ready'
                        : 'cancelled',
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (e) {
                  setDialog(() => error = e.toString());
                }
              },
              child: Text(
                ['done', 'cancelled'].contains(t['state']) ? '明确重新打开' : '取消任务',
              ),
            ),
            FilledButton(
              onPressed: () async {
                if (title.text.trim().isEmpty || goal.text.trim().isEmpty) {
                  setDialog(() => error = '请保留名称和完成标准。');
                  return;
                }
                try {
                  await c.submit('task.update', {
                    'id': t['id'],
                    'version': t['version'],
                    'title': title.text.trim(),
                    'outcome_criteria': goal.text.trim(),
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (e) {
                  setDialog(() => error = e.toString());
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    goal.dispose();
  }

  Widget reviewPage() =>
      padded(ReviewPanel(controller: c, day: dateKey(selectedDay)));

  Widget assistantPage() => padded(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading('把变化，告诉助手。', '助手接入和结构化建议正在实现，任务、执行和反馈可先正常使用。'),
        panel(
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('模型服务尚未配置', style: TextStyle(fontSize: 20)),
              SizedBox(height: 12),
              Text('API Key 将保留在电脑端。配置完成后，这里用于制定计划、解释调整和日终分析。'),
            ],
          ),
        ),
      ],
    ),
  );

  Widget settingsPage() => SingleChildScrollView(
    child: padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading('让手机和电脑接上。', '先保留本地记录，连接恢复后再同步。'),
          panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.connected ? '电脑服务已连接' : '当前使用本地记录',
                  style: const TextStyle(fontSize: 20),
                ),
                const SizedBox(height: 12),
                Text('地址：${c.serverUrl}'),
                Text('待同步：${c.pending.length} 条'),
                if (c.connectionError != null) Text(c.connectionError!),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton(
                      onPressed: pairDialog,
                      child: const Text('连接 / 配对电脑'),
                    ),
                    OutlinedButton(
                      onPressed: () => attempt(c.sync),
                      child: const Text('立即同步'),
                    ),
                    if (c.state['device']?['role'] == 'desktop')
                      OutlinedButton(
                        onPressed: pairingCode,
                        child: const Text('生成手机配对码'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('时间设置', style: TextStyle(fontSize: 19)),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: c.settings['timezone'],
                  decoration: const InputDecoration(labelText: '日程时区'),
                  items: ['America/Los_Angeles', 'Asia/Shanghai', 'UTC']
                      .map((z) => DropdownMenuItem(value: z, child: Text(z)))
                      .toList(),
                  onChanged: (value) => attempt(
                    () => c.submit('settings.update', {'timezone': value}),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '可安排范围 ${c.settings['day_start']}—${c.settings['day_end']}。用餐和休息可通过新建「保护时段」设置。',
                ),
                const SizedBox(height: 14),
                const Text(
                  '本地通知权限与连接检查将在提醒切片接入。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          if (c.preservedConflicts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text('已保留 ${c.preservedConflicts.length} 份冲突时的本地副本。'),
            ),
        ],
      ),
    ),
  );

  Future<void> pairDialog() async {
    final url = TextEditingController(text: c.serverUrl),
        code = TextEditingController();
    String? error;
    var working = false;
    await showOwnedDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('连接电脑'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('在电脑端生成一次性配对码，输入电脑的私人网络服务地址。'),
                const SizedBox(height: 16),
                TextField(
                  controller: url,
                  decoration: const InputDecoration(
                    labelText: '服务地址',
                    hintText: 'http://电脑地址:8787',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: '8 位配对码'),
                ),
                if (error != null) Text(error!),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: working ? null : () => Navigator.pop(dialogContext),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: working
                  ? null
                  : () async {
                      setDialog(() => working = true);
                      try {
                        await c.pair(url.text, code.text, '个人客户端');
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (e) {
                        if (context.mounted) {
                          setDialog(() {
                            error = e.toString();
                            working = false;
                          });
                        }
                      }
                    },
              child: Text(working ? '连接中…' : '配对'),
            ),
          ],
        ),
      ),
    );
    url.dispose();
    code.dispose();
  }

  Future<void> pairingCode() async => attempt(() async {
    final value = await c.onlineRequest('/api/v1/pairing/code', {});
    if (mounted) {
      await showOwnedDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('手机配对码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                value['code'],
                style: const TextStyle(fontSize: 32, letterSpacing: 4),
              ),
              const SizedBox(height: 12),
              const Text('5 分钟有效，仅可使用一次。手机需要能访问电脑的服务地址。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
  });

  Future<void> conflictDialog() async {
    final confirm = await showOwnedDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('处理同步冲突'),
        content: Text(
          '${c.conflict}\n\n可以重试，或保留完整的本地操作副本，再采用电脑记录。副本不会删除，之后可据此手动补录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后处理'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保留副本并采用电脑记录'),
          ),
        ],
      ),
    );
    if (confirm == true) await attempt(c.preserveConflictAndRefresh);
  }
}

class ReviewPanel extends StatefulWidget {
  const ReviewPanel({super.key, required this.controller, required this.day});
  final PlannerController controller;
  final String day;
  @override
  State<ReviewPanel> createState() => _ReviewPanelState();
}

class _ReviewPanelState extends State<ReviewPanel> {
  final text = TextEditingController();
  String? result;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant ReviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.day != widget.day) load();
  }

  void load() {
    text.text =
        widget.controller.reviews
            .where((r) => r['date'] == widget.day)
            .lastOrNull?['text'] ??
        '';
    result = null;
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('让今天，有个收尾。', style: TextStyle(fontSize: 28, color: ink)),
        const SizedBox(height: 10),
        Text('${widget.day} · 两三句话，记录产出、卡点和下一步。'),
        const SizedBox(height: 24),
        TextField(
          controller: text,
          minLines: 5,
          maxLines: 10,
          maxLength: 10000,
          decoration: const InputDecoration(
            labelText: '你的两三句话',
            hintText: '今天留下了什么？哪些还在等待，明天从哪里继续？',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () async {
            if (text.text.trim().isEmpty) return;
            try {
              await widget.controller.submit('review.save', {
                'date': widget.day,
                'text': text.text.trim(),
              });
              if (mounted) setState(() => result = '原文已保留。连接电脑后写入日报归档。');
            } catch (e) {
              if (mounted) setState(() => result = e.toString());
            }
          },
          child: const Text('保存今天的回顾'),
        ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(result!),
          ),
        const SizedBox(height: 24),
        const Text('记录来源'),
        for (final review
            in widget.controller.reviews
                .where((r) => r['date'] == widget.day)
                .toList()
                .reversed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(review['text']),
            subtitle: Text(
              review['archive_status'] == 'saved' ? '已归档到电脑' : '等待电脑归档',
            ),
          ),
      ],
    ),
  );
}
