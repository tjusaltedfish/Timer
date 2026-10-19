import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_planner/theme/ink_theme.dart';
import 'package:time_planner/theme/tokens.dart';

Color labelColor(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  final span = paragraph.text as TextSpan;
  return (span.style?.color ?? span.children?.first.style?.color)!;
}

void main() {
  testWidgets('chip labels stay readable in every state', (tester) async {
    final p = InkPalette.light;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildInkTheme(Brightness.light),
        home: Scaffold(
          body: Wrap(
            children: [
              ActionChip(label: const Text('动作'), onPressed: () {}),
              ChoiceChip(
                label: const Text('未选'),
                selected: false,
                onSelected: (_) {},
              ),
              ChoiceChip(
                label: const Text('已选'),
                selected: true,
                onSelected: (_) {},
              ),
              FilterChip(
                label: const Text('筛选'),
                selected: false,
                onSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(labelColor(tester, '动作'), p.inkNong);
    expect(labelColor(tester, '未选'), p.inkNong);
    expect(labelColor(tester, '已选'), p.paper);
    expect(labelColor(tester, '筛选'), p.inkNong);
  });
}
