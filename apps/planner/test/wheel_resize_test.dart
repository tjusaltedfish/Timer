import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_planner/theme/ink_theme.dart';
import 'package:time_planner/widgets/card_wheel.dart';

void main() {
  for (final heights in [
    [464.0],
    [120.0, 464.0],
    [464.0, 430.0],
  ]) {
    testWidgets('wheel rests on a whole page for heights $heights', (
      tester,
    ) async {
      final height = ValueNotifier(heights.first);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildInkTheme(Brightness.light),
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: height,
              builder: (_, h, _) => SizedBox(
                height: h,
                child: CardWheel(
                  count: 5,
                  initial: 2,
                  minimumCardHeight: 300,
                  builder: (_, i, _) => Card(child: Text('卡 $i')),
                ),
              ),
            ),
          ),
        ),
      );
      for (final h in heights.skip(1)) {
        await tester.pump();
        height.value = h;
      }
      await tester.pumpAndSettle();
      final page = tester
          .widget<PageView>(find.byType(PageView))
          .controller!
          .page!;
      expect(page, closeTo(2, .001));
    });
  }
}
