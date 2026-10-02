import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/companions/companion_engine_picker.dart';
import 'package:harness/shared/theme/app_theme.dart';
import 'package:harness/shared/widgets/app_menu.dart';

void main() {
  testWidgets('first choice, switching, dismissal and a pending launch', (
    tester,
  ) async {
    String? selected;
    var busy = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return CompanionEnginePicker(
                engine: selected,
                busy: busy,
                onSelected: (engine) => setState(() => selected = engine),
              );
            },
          ),
        ),
      ),
    );
    final trigger = find.byKey(const ValueKey('companion-engine-picker'));
    expect(find.text('Choose agent'), findsOneWidget);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();
    expect(selected, 'codex');
    expect(find.byType(AppMenuItem), findsNothing);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<AppMenuItem>(find.byType(AppMenuItem))
          .where((row) => row.selected)
          .single
          .label,
      'Codex',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(selected, 'codex');
    expect(find.byType(AppMenuItem), findsNothing);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Code'));
    await tester.pumpAndSettle();
    expect(selected, 'claude');
    update(() => busy = true);
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(trigger).onPressed, isNull);
    expect(find.text('Opening…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard users can open, choose and dismiss the agent menu', (
    tester,
  ) async {
    String? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompanionEnginePicker(
            engine: null,
            onSelected: (engine) => chosen = engine,
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AppMenuItem), findsNWidgets(3));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(chosen, isNotNull);
    expect(find.byType(AppMenuItem), findsNothing);
  });
}
