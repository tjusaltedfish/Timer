import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';
import 'package:time_planner/week_calendar.dart';

/// 手机周视图的回归测试：7 列总览 → 单天概览 → 详细课表。
///
/// 时间固定在 2026-10-19（周一）16:00Z，即 Los Angeles 本地 09:00。
void main() {
  Future<PlannerController> seed({
    bool weekEmpty = false,
    DateTime Function()? clock,
  }) async {
    tzdata.initializeTimeZones();
    final c = PlannerController(
      storage: MemoryStore(),
      clock: clock ?? () => DateTime.utc(2026, 10, 19, 16),
    );
    await c.initialize();
    if (weekEmpty) return c;
    await c.submit('task.create', {
      'id': 't1',
      'title': '实验代码',
      'outcome_criteria': '输出 CSV',
      'remaining_minutes': 60,
    });
    await c.submit('block.create', {
      'id': 'b1',
      'task_id': 't1',
      'kind': 'flexible',
      'timezone': 'America/Los_Angeles',
      'start_at': '2026-10-19T16:00:00Z',
      'end_at': '2026-10-19T17:00:00Z',
    });
    return c;
  }

  void phone(WidgetTester tester, {double width = 390, double height = 844}) {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openWeek(WidgetTester tester) async {
    await tester.tap(find.text('一周').last);
    await tester.pumpAndSettle();
  }

  testWidgets('手机整周总览：7 列都放得下，今天高亮，点色块命中', (tester) async {
    phone(tester, width: 360, height: 780);
    final c = await seed();
    await c.submit('task.create', {
      'id': 't2',
      'title': '算法学习',
      'outcome_criteria': '两章',
      'remaining_minutes': 90,
    });
    await c.submit('block.create', {
      'id': 'b2',
      'task_id': 't2',
      'kind': 'flexible',
      'timezone': 'America/Los_Angeles',
      'start_at': '2026-10-20T17:00:00Z',
      'end_at': '2026-10-20T18:00:00Z',
    });
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await openWeek(tester);

    expect(find.byKey(const Key('week.overview')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('week.overview')),
        matching: find.text('今'),
      ),
      findsOneWidget,
    );
    for (var i = 0; i < 7; i++) {
      final rect = tester.getRect(find.byKey(ValueKey('week.day.$i')));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
      expect(rect.bottom, lessThanOrEqualTo(780));
    }
    expect(
      find.descendant(
        of: find.byKey(const Key('week.overview')),
        matching: find.textContaining('实验代码'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('week.overview')),
        matching: find.textContaining('算法学习'),
      ),
      findsOneWidget,
    );

    // 长按色块看全名（窄列里标题会被截断）。
    await tester.longPress(find.byKey(const ValueKey('week.stamp.b1')));
    await tester.pumpAndSettle();
    expect(find.text('实验代码\n09:00—10:00'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    // 点色块 = 打开这件事的详情，不需要先进单天概览。
    await tester.tap(find.byKey(const ValueKey('week.stamp.b1')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('实验代码'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('点某一天进入单天概览：计划/已投入/完成/中断 + 紧凑列表', (tester) async {
    phone(tester);
    var clock = DateTime.utc(2026, 10, 19, 16);
    final c = await seed(clock: () => clock);
    await c.startBlock(c.blocks.single);
    expect(c.sessions, hasLength(1));
    clock = DateTime.utc(2026, 10, 19, 16, 25);
    await c.controlSession(c.sessions.single, 'end');
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await openWeek(tester);

    await tester.tap(find.byKey(const ValueKey('week.day.0')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('week.day.close')), findsOneWidget);
    expect(find.text('已投入'), findsOneWidget);
    // 计划一小时，实际只投入 25 分钟。
    expect(find.text('1 小时'), findsOneWidget);
    expect(find.text('25 分钟'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('中断'), findsOneWidget);
    expect(find.text('1 段'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('week.day.item.b1')), findsOneWidget);
    expect(find.textContaining('09:00—09:25'), findsOneWidget);

    // 列表项点开详情。
    await tester.tap(find.byKey(const ValueKey('week.day.item.b1')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // 回到整周总览。
    await tester.tap(find.byKey(const Key('week.day.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.overview')), findsOneWidget);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('概览与详细课表可来回切换，缩放有上下边界', (tester) async {
    phone(tester);
    final c = await seed();
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await openWeek(tester);

    expect(find.byKey(const Key('week.detail.open')), findsOneWidget);
    await tester.tap(find.byKey(const Key('week.detail.open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.detail')), findsOneWidget);
    expect(find.byType(WeekCalendar), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);

    // 放大到 200% 后按钮停用。
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const Key('week.zoom.in')));
      await tester.pumpAndSettle();
    }
    expect(find.text('200%'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('week.zoom.in')))
          .onPressed,
      isNull,
    );

    // 缩小到 75% 后按钮停用。
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const Key('week.zoom.out')));
      await tester.pumpAndSettle();
    }
    expect(find.text('75%'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('week.zoom.out')))
          .onPressed,
      isNull,
    );

    // 返回整周总览。
    await tester.tap(find.byKey(const Key('week.detail.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.overview')), findsOneWidget);
    expect(find.byKey(const Key('week.detail')), findsNothing);

    // 从单天概览进详细课表，返回后仍在单天概览。
    await tester.tap(find.byKey(const ValueKey('week.day.0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('week.detail.open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.detail')), findsOneWidget);
    await tester.tap(find.byKey(const Key('week.detail.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.day.close')), findsOneWidget);
    expect(find.byKey(const Key('week.detail')), findsNothing);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('空状态：整周空着、单天空着，都能一键开始排', (tester) async {
    phone(tester, width: 360, height: 780);
    final c = await seed(weekEmpty: true);
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await openWeek(tester);

    expect(find.text('这周还空着'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('week.day.2')));
    await tester.pumpAndSettle();
    expect(find.text('这一天还空着。'), findsOneWidget);
    expect(find.byKey(const Key('week.day.plan')), findsOneWidget);

    await tester.tap(find.byKey(const Key('week.day.plan')));
    await tester.pumpAndSettle();
    expect(find.text('落一笔有结果的事'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 弹层的按钮在 360dp 上会在折叠区，这里直接关掉弹层确认已打开。
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('360/390/430dp 三档总览 7 列都不溢出', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in const [360.0, 390.0, 430.0]) {
      tester.view.physicalSize = Size(width, 780);
      tester.view.devicePixelRatio = 1;
      final c = await seed();
      await tester.pumpWidget(PlannerApp(controller: c));
      await tester.pumpAndSettle();
      await openWeek(tester);
      for (var i = 0; i < 7; i++) {
        final rect = tester.getRect(find.byKey(ValueKey('week.day.$i')));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(width));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
  });

  testWidgets('桌面宽屏仍是整周 hour 网格，不出现手机三段式入口', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await seed();
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await openWeek(tester);

    expect(find.byType(WeekCalendar), findsOneWidget);
    expect(find.byKey(const Key('week.overview')), findsNothing);
    expect(find.byKey(const Key('week.detail.open')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
