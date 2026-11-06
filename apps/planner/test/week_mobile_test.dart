import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';
import 'package:time_planner/week_calendar.dart';

/// 手机「一周」的回归测试：默认是当天列表，按日期条换天，需要时进详细课表。
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

  testWidgets('一周默认是当天列表：没有整周色块，七天都放得下，能换天看详情', (tester) async {
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

    expect(find.byKey(const Key('week.list')), findsOneWidget);
    expect(find.byKey(const Key('week.overview')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('week.list')),
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

    // 打开就是今天的安排，不需要再点一层；别的天不混进来。
    expect(find.byKey(const ValueKey('week.day.item.b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('week.day.item.b2')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('week.day.1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('week.day.item.b2')), findsOneWidget);
    expect(find.byKey(const ValueKey('week.day.item.b1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('week.day.item.b2')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('当天列表带统计：计划/已投入/完成/中断 + 紧凑列表', (tester) async {
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

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('列表与详细课表可来回切换，缩放有上下边界', (tester) async {
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

    // 返回当天列表。
    await tester.tap(find.byKey(const Key('week.detail.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.list')), findsOneWidget);
    expect(find.byKey(const Key('week.detail')), findsNothing);

    // 换一天进详细课表，返回后还是那一天。
    await tester.tap(find.byKey(const ValueKey('week.day.2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('week.detail.open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.detail')), findsOneWidget);
    await tester.tap(find.byKey(const Key('week.detail.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.list')), findsOneWidget);
    expect(find.textContaining('10月21日'), findsWidgets);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('空状态：这一天空着，能一键开始排', (tester) async {
    phone(tester, width: 360, height: 780);
    final c = await seed(weekEmpty: true);
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await openWeek(tester);

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

  testWidgets('360/390/430dp 三档日期条 7 天都不溢出', (tester) async {
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
    expect(find.byKey(const Key('week.list')), findsNothing);
    expect(find.byKey(const Key('week.detail.open')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('桌面周视图拖动改期：存进本地，撤销能改回去', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await seed();
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await openWeek(tester);

    final chip = find.byKey(const ValueKey('week.block.b1'));
    final column = tester.getSize(chip).width + 8;
    final gesture = await tester.startGesture(
      tester.getCenter(chip),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(Offset(column, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    DateTime startOf() => DateTime.parse(
      c.blocks.singleWhere((b) => b['id'] == 'b1')['start_at'] as String,
    );
    expect(startOf(), DateTime.utc(2026, 10, 20, 16));
    expect(find.textContaining('改到 10月20日'), findsOneWidget);

    await tester.tap(find.byKey(const Key('week.drag.undo')));
    await tester.pumpAndSettle();
    expect(startOf(), DateTime.utc(2026, 10, 19, 16));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('拖动后的撤销提示几秒后自己消失，不挡后面的提示', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await seed();
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await openWeek(tester);

    final chip = find.byKey(const ValueKey('week.block.b1'));
    final column = tester.getSize(chip).width + 8;
    final gesture = await tester.startGesture(
      tester.getCenter(chip),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(Offset(column, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.drag.undo')), findsOneWidget);

    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.drag.undo')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('详细课表里有「今天」；离开本周后一点就回到今天', (tester) async {
    phone(tester);
    final c = await seed();
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await openWeek(tester);

    // 本周进详细课表：今天本来就在眼前，不出现多余的「今天」。
    await tester.tap(find.byKey(const Key('week.detail.open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.today')), findsNothing);

    await tester.tap(find.byKey(const Key('week.detail.close')));
    await tester.pumpAndSettle();

    // 翻到下一周再进详细课表，应该能一键回来。
    await tester.tap(find.byTooltip('下一周'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('week.detail.open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.today')), findsOneWidget);
    await tester.tap(find.byKey(const Key('week.today')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.today')), findsNothing);
    expect(find.byKey(const Key('week.detail')), findsOneWidget);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('窄屏进详细课表也能一眼找到「返回列表」', (tester) async {
    final c = await seed();
    phone(tester, width: 360);
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一周'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('week.detail.open')));
    await tester.pumpAndSettle();

    // 返回按钮在窄屏上必须可见、可点，不能因为缩放按钮挤掉。
    expect(find.byKey(const Key('week.detail.close')), findsOneWidget);
    expect(find.text('‹ 返回列表'), findsOneWidget);
    await tester.tap(find.byKey(const Key('week.detail.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week.list')), findsOneWidget);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
