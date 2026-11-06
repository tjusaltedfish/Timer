import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_planner/controller.dart';
import 'package:time_planner/home.dart' show showMemoryDialog;
import 'package:time_planner/theme/ink_theme.dart';

void main() {
  testWidgets('记忆列表标出来源和条数，删了能撤销，也能新加', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = PlannerController(storage: MemoryStore());
    await c.initialize();
    await c.submit('memory.save', {'id': 'm1', 'text': '上午优先做实验'});
    await c.submit('memory.save', {
      'id': 'm2',
      'text': '周末留空',
      'source': 'assistant',
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildInkTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMemoryDialog(context, c),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2/50 条'), findsOneWidget);
    expect(find.textContaining('你说的'), findsWidgets);
    expect(find.textContaining('助手记下'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('memory.delete.m2')));
    await tester.pumpAndSettle();
    expect(c.state['memories'].map((m) => m['id']), ['m1']);
    expect(find.textContaining('已删除「周末留空」'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory.undo')));
    await tester.pumpAndSettle();
    final restored = (c.state['memories'] as List).last as Json;
    expect((restored['id'], restored['source']), ('m2', 'assistant'));
    expect(find.byKey(const Key('memory.undo')), findsNothing);

    await tester.enterText(find.byKey(const Key('memory.input')), '回答简短');
    await tester.tap(find.byKey(const Key('memory.save')));
    await tester.pumpAndSettle();
    expect(find.text('回答简短'), findsOneWidget);
    expect(find.textContaining('3/50 条'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
