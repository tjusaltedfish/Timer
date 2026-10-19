import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_planner/controller.dart';
import 'package:time_planner/planner_app.dart';
import 'package:time_planner/theme/ink_theme.dart';
import 'package:time_planner/theme/tokens.dart';
import 'package:time_planner/widgets/card_wheel.dart';

void main() {
  test(
    'the ink system uses only black, white and grey, including project marks',
    () {
      for (final p in [InkPalette.light, InkPalette.dark]) {
        final scheme = buildInkTheme(
          p == InkPalette.light ? Brightness.light : Brightness.dark,
        ).colorScheme;
        for (final color in [
          p.paper,
          p.paperRaised,
          p.inkJiao,
          p.inkNong,
          p.inkZhong,
          p.inkDan,
          p.inkQing,
          p.line,
          p.accent,
          ...p.projects.values,
          scheme.primary,
          scheme.secondary,
          scheme.tertiary,
          scheme.error,
          scheme.primaryFixed,
          scheme.tertiaryContainer,
          scheme.surfaceContainerLow,
        ]) {
          final value = color.toARGB32();
          expect((value >> 16) & 255, (value >> 8) & 255);
          expect((value >> 8) & 255, value & 255);
        }
      }
    },
  );
  test('paper and night palettes keep body text readable', () {
    for (final p in [InkPalette.light, InkPalette.dark]) {
      for (final surface in [p.paper, p.paperRaised]) {
        for (final text in [p.inkJiao, p.inkNong, p.inkZhong, p.accent]) {
          final a = text.computeLuminance(), b = surface.computeLuminance();
          expect(
            ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
    }
  });

  testWidgets(
    'wheel focuses a neighbour before enabling its actions and supports keys',
    (tester) async {
      var actions = 0;
      final focused = <int>[], activated = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildInkTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
              height: 500,
              child: CardWheel(
                count: 4,
                initial: 1,
                onFocus: focused.add,
                onActivate: activated.add,
                builder: (_, index, focused) => Card(
                  child: Column(
                    children: [
                      Text('时段 $index'),
                      FilledButton(
                        onPressed: () => actions++,
                        child: Text('开始 $index'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      // A neighbouring button is deliberately absorbed; tap its screen position.
      await tester.tapAt(tester.getCenter(find.text('开始 2')));
      await tester.pumpAndSettle();
      expect(actions, 0);
      expect(focused.last, 2);
      await tester.tap(find.text('开始 2'));
      expect(actions, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(focused.last, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(activated, [1]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion removes wheel blur', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: SizedBox(
            height: 500,
            child: CardWheel(
              count: 3,
              initial: 1,
              builder: (_, index, focused) => Text('时段 $index'),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ImageFiltered), findsNothing);
  });

  for (final width in [360.0, 390.0, 412.0, 1280.0, 1920.0]) {
    testWidgets('ink shell and settings remain usable at width $width', (
      tester,
    ) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = PlannerController(storage: MemoryStore());
      await c.initialize();
      await tester.pumpWidget(PlannerApp(controller: c));
      expect(find.text('今日尚空。先落一笔有结果的事。'), findsOneWidget);
      if (width < 1000) {
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .destinations
              .length,
          5,
        );
      }
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('电脑服务已连接'), findsNothing);
      expect(find.text('当前使用本地记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets('360px task sheet can save while the keyboard is open', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final c = PlannerController(storage: MemoryStore());
    await c.initialize();
    await tester.pumpWidget(PlannerApp(controller: c));
    await tester.tap(find.byKey(const Key('action.first-task')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '扫描脚本');
    await tester.enterText(find.byType(TextField).at(1), '输出可复现 CSV');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存安排'));
    await tester.tap(find.text('保存安排'));
    await tester.pumpAndSettle();
    expect(c.blocks.length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
