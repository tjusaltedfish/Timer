import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'controller.dart';

class ReminderItem {
  const ReminderItem(this.key, this.at, this.title, this.body, this.payload);
  final String key, title, body;
  final DateTime at;
  final Json payload;
  int get id {
    var hash = 5381;
    for (final character in key.codeUnits) {
      hash = (hash * 33 + character) & 0x7fffffff;
    }
    return hash;
  }

  String get signature =>
      jsonEncode([at.toUtc().toIso8601String(), title, body, payload]);
}

List<ReminderItem> buildReminders(Json state, DateTime now) {
  final result = <ReminderItem>[];
  final zone = tz.getLocation((state['settings'] as Json)['timezone']);
  final sessions = (state['sessions'] as List).cast<Json>();
  final tasks = (state['tasks'] as List).cast<Json>();
  final horizon = now.add(const Duration(days: 7));
  void add(
    String key,
    String? rawTime,
    String title,
    String body,
    Json payload,
  ) {
    if (rawTime == null) return;
    final at = DateTime.parse(rawTime).toUtc();
    // Retain recently delivered prompts until feedback; refreshing must not erase them.
    if (at.isBefore(now.subtract(const Duration(days: 1))) ||
        at.isAfter(horizon)) {
      return;
    }
    result.add(ReminderItem(key, at, title, body, payload));
  }

  void followup(String key, String? end, Json payload) {
    if (end == null) return;
    final at = DateTime.parse(end).add(const Duration(minutes: 10));
    final local = tz.TZDateTime.from(at, zone);
    if (local.hour >= 8 && local.hour < 22) {
      add(
        '$key:followup',
        at.toIso8601String(),
        '这一段的结果，还没记录',
        '完成、部分完成，还是等待结果？点一下就好。',
        payload,
      );
    }
  }

  for (final block in (state['blocks'] as List).cast<Json>()) {
    if (block['status'] != 'scheduled' || block['kind'] == 'protected') {
      continue;
    }
    final task = tasks.where((t) => t['id'] == block['task_id']).firstOrNull;
    if (task != null && ['done', 'cancelled'].contains(task['state'])) continue;
    final session = sessions
        .where((s) => s['block_id'] == block['id'])
        .lastOrNull;
    final payload = <String, dynamic>{'page': 'today', 'block_id': block['id']};
    if (session == null) {
      add(
        'block:${block['id']}:start',
        block['start_at'],
        '该开始：${block['title']}',
        task?['outcome_criteria'] ?? '打开日程，开始这一段。',
        payload,
      );
      // Two prompts for a block that was never started: its start, and its
      // end (to backfill or reschedule). A third follow-up was just noise.
      add(
        'block:${block['id']}:end',
        block['end_at'],
        '这一段，进展如何？',
        '${block['title']}：记录结果或调整下一步。',
        payload,
      );
    }
  }
  for (final session in sessions) {
    if (!['running', 'awaiting_feedback'].contains(session['state'])) continue;
    final payload = <String, dynamic>{
      'page': 'today',
      'block_id': session['block_id'],
    };
    final end = session['state'] == 'running'
        ? session['expected_end_at']
        : session['actual_end_at'];
    add(
      'session:${session['id']}:end',
      end,
      '本段时间到了，记录一下结果',
      '结果未确认，任务会保留。你可以完成、继续或等待。',
      payload,
    );
    followup('session:${session['id']}', end, payload);
  }
  for (final check in (state['waiting_checks'] as List).cast<Json>()) {
    if (check['resolved_at'] != null) continue;
    final task = tasks.where((t) => t['id'] == check['task_id']).firstOrNull;
    if (task == null || task['state'] != 'waiting') continue;
    add(
      'waiting:${check['id']}',
      check['check_at'],
      '检查等待中的结果',
      task['title'],
      {'page': 'tasks', 'task_id': check['task_id']},
    );
  }
  final localNow = tz.TZDateTime.from(now, zone);
  final pieces = (state['settings']['daily_review_time'] as String)
      .split(':')
      .map(int.parse)
      .toList();
  for (var offset = 0; offset < 7; offset++) {
    final day = DateTime(localNow.year, localNow.month, localNow.day + offset);
    final key =
        '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    if ((state['reviews'] as List).any((r) => r['date'] == key)) continue;
    final candidates = localTimeCandidates(day, pieces[0], pieces[1], zone);
    // Recurring reviews use the first occurrence; a skipped wall time moves forward.
    final at =
        candidates.firstOrNull ??
        tz.TZDateTime(zone, day.year, day.month, day.day, pieces[0], pieces[1]);
    add(
      'review:$key',
      at.toUtc().toIso8601String(),
      '让今天，有个收尾',
      '两三句话：产出、卡点、明天从哪里继续。',
      {'page': 'review', 'date': key},
    );
  }
  result.sort((a, b) => a.at.compareTo(b.at));
  return result;
}

abstract class ReminderDriver {
  bool get supported;
  bool get schedulesInSystem;
  bool get precise;
  Future<void> initialize(void Function(String?) onOpen);
  Future<bool> allowed();
  Future<bool> requestPermission();
  Future<void> requestExactPermission();
  Future<Set<int>> knownIds();
  Future<void> cancel(int id);
  Future<void> schedule(ReminderItem item);
  Future<void> show(ReminderItem item);
}

class NativeReminderDriver implements ReminderDriver {
  final plugin = FlutterLocalNotificationsPlugin();
  bool _precise = false;

  /// 到点响铃：关掉后仍然发通知，但静音、不占横幅优先级。
  bool sound = true;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _windows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  @override
  bool get supported => _android || _windows;
  @override
  bool get schedulesInSystem => _android;
  @override
  bool get precise => _precise;
  static const details = NotificationDetails(
    android: AndroidNotificationDetails(
      'planner_reminders',
      '日程与结果提醒',
      channelDescription: '开始安排、结束反馈、等待结果和日终回顾',
      importance: Importance.high,
      priority: Priority.high,
      groupKey: 'planner',
    ),
    windows: WindowsNotificationDetails(),
  );
  static const silentDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'planner_reminders',
      '日程与结果提醒',
      channelDescription: '开始安排、结束反馈、等待结果和日终回顾',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      playSound: false,
      silent: true,
      groupKey: 'planner',
    ),
    windows: WindowsNotificationDetails(),
  );
  @override
  Future<void> initialize(void Function(String?) onOpen) async {
    if (!supported) return;
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
        windows: WindowsInitializationSettings(
          appName: '瞬时',
          appUserModelId: 'dev.personal.time_planner',
          guid: 'd7e76cab-65a4-4fe3-9aa9-86c485185cf7',
        ),
      ),
      onDidReceiveNotificationResponse: (response) => onOpen(response.payload),
    );
    final launch = await plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      onOpen(launch?.notificationResponse?.payload);
    }
  }

  @override
  Future<bool> allowed() async {
    if (_android) {
      final implementation = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()!;
      _precise = await implementation.canScheduleExactNotifications() ?? false;
      return await implementation.areNotificationsEnabled() ?? false;
    }
    return _windows;
  }

  @override
  Future<bool> requestPermission() async {
    if (_android) {
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()!
          .requestNotificationsPermission();
    }
    return allowed();
  }

  @override
  Future<void> requestExactPermission() async {
    if (_android) {
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()!
          .requestExactAlarmsPermission();
    }
  }

  @override
  Future<Set<int>> knownIds() async {
    if (!_android) return {};
    return {
      ...(await plugin.pendingNotificationRequests()).map((n) => n.id),
      ...(await plugin.getActiveNotifications())
          .map((n) => n.id)
          .whereType<int>(),
    };
  }

  @override
  Future<void> cancel(int id) async {
    if (_android) await plugin.cancel(id: id);
  }

  @override
  Future<void> schedule(ReminderItem item) async {
    await plugin.zonedSchedule(
      id: item.id,
      scheduledDate: tz.TZDateTime.from(item.at, tz.UTC),
      notificationDetails: sound ? details : silentDetails,
      androidScheduleMode: _precise
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      title: item.title,
      body: item.body,
      payload: 'planner:${jsonEncode(item.payload)}',
    );
  }

  @override
  Future<void> show(ReminderItem item) async => plugin.show(
    id: item.id,
    title: item.title,
    body: item.body,
    notificationDetails: details,
    payload: 'planner:${jsonEncode(item.payload)}',
  );
}

class ReminderService extends ChangeNotifier {
  ReminderService({
    required this.controller,
    required this.driver,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final PlannerController controller;
  final ReminderDriver driver;
  final DateTime Function() clock;
  bool enabled = false,
      alarm = true,
      initialized = false,
      _disposed = false,
      _dirty = false,
      _force = false;
  String status = '提醒尚未启用';
  Json? lastOpen;
  int openSerial = 0, registeredCount = 0;
  Future<void>? _refreshing;
  Future<void>? _initialization;
  Timer? _windowsClock;
  List<ReminderItem> _plan = [];
  ReminderItem? _testReminder;
  Map<String, String> _registry = {}, _shown = {};
  String? _reported;

  Future<void> initialize() => _initialization ??= _initialize()
      .catchError((Object error, StackTrace stack) {
        // 把真实原因留下来：ColorOS 等机型上系统提醒接口可能整段不可用。
        final brief = '$error'.split('\n').first;
        status = '系统提醒初始化失败：$brief';
        debugPrint('[rem] initialize failed: $error\n$stack');
        _notify();
      })
      .whenComplete(() {
        _initialization = null;
      });

  Future<void> _initialize() async {
    if (initialized) return;
    final stored = await controller.storage.read('reminders_enabled');
    // The computer needs no permission, and its only switch hid in settings,
    // so desktop reminders start on; an explicit 「关」 is still respected.
    enabled = stored == null
        ? driver.supported && !driver.schedulesInSystem
        : stored == 'true';
    alarm = await controller.storage.read('reminders_alarm') != 'false';
    if (driver is NativeReminderDriver) {
      (driver as NativeReminderDriver).sound = alarm;
    }
    _registry = Map<String, String>.from(
      jsonDecode(await controller.storage.read('reminder_registry') ?? '{}'),
    );
    _shown = Map<String, String>.from(
      jsonDecode(await controller.storage.read('reminder_shown') ?? '{}'),
    );
    await driver.initialize((payload) {
      if (payload == null || !payload.startsWith('planner:')) return;
      try {
        lastOpen = jsonDecode(payload.substring(8)) as Json;
        openSerial++;
        _notify();
      } catch (_) {
        /* Ignore foreign/malformed notification payload. */
      }
    });
    initialized = true;
    controller.addListener(_onState);
    if (!driver.schedulesInSystem && driver.supported) {
      _windowsClock = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_showDue()),
      );
    }
    await refresh(force: true);
  }

  void _onState() {
    unawaited(refresh());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static const _driverTimeout = Duration(seconds: 8);

  /// 系统提醒接口在个别手机上会不返回（尤其 ColorOS 的通知权限查询）。
  /// 这里一律加超时并把失败原因写到 status，避免用户点了按钮却什么也看不到。
  Future<void> enable() async {
    try {
      debugPrint('[rem] enable tapped (init=$initialized, enabled=$enabled)');
      if (!initialized) await initialize().timeout(_driverTimeout);
      debugPrint(
        '[rem] after init: initialized=$initialized supported=${driver.supported}',
      );
      if (!initialized) {
        status = '系统提醒没能初始化（可能是系统限制）。退出 App 重进，或到手机设置里允许「瞬时」通知后再试。';
        _notify();
        return;
      }
      if (!driver.supported) {
        status = '此预览环境不提供离线系统提醒，请使用原生客户端。';
        _notify();
        return;
      }
      enabled = await driver.requestPermission().timeout(_driverTimeout);
      debugPrint('[rem] requestPermission -> $enabled');
      await controller.storage.write('reminders_enabled', enabled.toString());
      await refresh(force: true);
      if (!enabled) {
        status = '系统没允许通知。到手机设置里给「瞬时」打开通知权限，再回来打开这个开关。';
        _notify();
      }
    } on TimeoutException {
      status = '开启提醒的请求 8 秒没有响应（系统提醒接口卡住）。退出 App 重进再试一次。';
      _notify();
    } catch (error) {
      status = '开启提醒失败：$error';
      _notify();
    }
  }

  String get diagnostics =>
      '初始化${initialized ? '完成' : '未完成'} · 系统调度${driver.schedulesInSystem ? '是' : '否'}'
      ' · 准时${driver.precise ? '是' : '否'} · 开关${enabled ? '开' : '关'}';

  /// 用户自己选「到点响不响」：关掉只弹静默通知。
  Future<void> setAlarm(bool value) async {
    alarm = value;
    if (driver is NativeReminderDriver) {
      (driver as NativeReminderDriver).sound = value;
    }
    await controller.storage.write('reminders_alarm', value.toString());
    await refresh(force: true);
  }

  Future<void> disable() async {
    enabled = false;
    _testReminder = null;
    await controller.storage.write('reminders_enabled', 'false');
    await refresh(force: true);
  }

  Future<void> requestExact() async {
    await driver.requestExactPermission();
    await refresh(force: true);
  }

  Future<void> test() async {
    if (!enabled) await enable();
    if (enabled && driver.supported && await driver.allowed()) {
      final item = ReminderItem(
        'test',
        clock().add(
          driver.schedulesInSystem
              ? const Duration(seconds: 15)
              : Duration.zero,
        ),
        '瞬时 · 测试提醒',
        '这是系统提醒测试。日程到点时也会通知你。',
        {'page': 'today'},
      );
      if (driver.schedulesInSystem) {
        _testReminder = item;
        await driver.schedule(item);
        status = '已安排 15 秒后测试，请切到其他应用或锁屏观察通知。';
      } else {
        await driver.show(item);
      }
      _notify();
    }
  }

  Future<void> refresh({bool force = false}) {
    _dirty = true;
    _force = _force || force;
    return _refreshing ??= _refreshLoop()
        .timeout(const Duration(seconds: 20))
        .catchError((Object error) {
          status = '刷新提醒失败：$error';
          _notify();
        })
        .whenComplete(() {
          _refreshing = null;
        });
  }

  Future<void> _refreshLoop() async {
    while (_dirty && !_disposed) {
      final force = _force;
      _dirty = false;
      _force = false;
      try {
        if (!initialized) return;
        if (!driver.supported) {
          status = '此预览环境不提供离线系统提醒。';
          _notify();
          return;
        }
        final known = {
          ..._registry.keys.map(int.parse),
          ...await driver.knownIds(),
        };
        if (!enabled || !await driver.allowed()) {
          for (final id in known) {
            await driver.cancel(id);
          }
          _plan = [];
          _registry = {};
          registeredCount = 0;
          status = enabled ? '系统尚未允许通知，请检查通知权限。' : '提醒尚未启用';
          await controller.storage.write('reminder_registry', '{}');
          _notify();
          continue;
        }
        final now = clock().toUtc();
        final all = [
          ...buildReminders(controller.state, now),
          // Sync must retain the test alarm until it has had time to display.
          if (_testReminder case final test?
              when now.isBefore(test.at.add(const Duration(minutes: 2))))
            test,
        ];
        _plan = all.where((r) => !r.at.isAfter(now)).toList();
        _plan.addAll(all.where((r) => r.at.isAfter(now)).take(120));
        final ids = <int>{};
        for (final reminder in _plan) {
          if (!ids.add(reminder.id)) {
            throw StateError('Reminder identity collision');
          }
        }
        final current = {for (final r in _plan) r.id.toString(): r.signature};
        for (final id in known.where((id) => !ids.contains(id))) {
          await driver.cancel(id);
        }
        if (driver.schedulesInSystem) {
          final actualPending = await driver.knownIds();
          for (final item in _plan.where((r) => r.at.isAfter(now))) {
            if (force ||
                _registry[item.id.toString()] != item.signature ||
                !actualPending.contains(item.id)) {
              await driver.cancel(item.id);
              await driver.schedule(item);
            }
          }
        }
        _registry = current;
        await controller.storage.write(
          'reminder_registry',
          jsonEncode(current),
        );
        registeredCount = _plan.where((r) => r.at.isAfter(now)).length;
        status = driver.schedulesInSystem
            ? '已向手机系统登记 $registeredCount 项提醒${driver.precise ? '' : '；尚未允许准时提醒，可能延后'}。'
            : '电脑提醒已启用，客户端运行期间检查；手机由系统独立调度。';
        if (all.where((r) => r.at.isAfter(now)).length > 120) {
          status += ' 后续提醒将在打开或同步时补充。';
        }
        _report();
        _notify();
      } catch (error) {
        status = '系统提醒未能更新，请检查权限并重试。';
        _report('$error'.split('\n').first);
        _notify();
      }
    }
  }

  /// Sends the reminder state to the computer's client log when it changes, so
  /// "it never rang" can be checked against what the phone actually registered.
  void _report([String? problem]) {
    final line =
        '$diagnostics · 登记 $registeredCount 项 · $status'
        '${problem == null ? '' : ' · $problem'}';
    if (line == _reported) return;
    _reported = line;
    unawaited(controller.reportClientEvent('reminders', line));
  }

  Future<void> _showDue() async {
    if (!enabled || _disposed) return;
    final now = clock().toUtc();
    for (final item in List<ReminderItem>.from(_plan)) {
      if (item.at.isAfter(now) ||
          now.difference(item.at) > const Duration(minutes: 2) ||
          _shown[item.id.toString()] == item.signature) {
        continue;
      }
      _shown[item.id.toString()] = item.signature;
      await controller.storage.write('reminder_shown', jsonEncode(_shown));
      try {
        await driver.show(item);
      } catch (_) {
        status = '电脑通知未能显示，请检查系统通知设置。';
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    controller.removeListener(_onState);
    _windowsClock?.cancel();
    super.dispose();
  }
}
