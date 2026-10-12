import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/shortcuts/keymap_commands.dart';
import 'package:harness/state/app_state.dart';

import 'support/agent_messages_api.dart';
import 'swarm_interactions_test.dart' show chord;
import 'swarm_screen_test.dart' show mount;
import 'swarm_state_test.dart' show createApp;

/// ⇧⌘P: "Show Agent Messages" (this tab's log) replaces Swarm's "Tab
/// conversation". There is no command to turn Agent Messages on or off for a
/// tab: whether agents may message is the account's, in Settings ▸ Experimental
/// (owner, 2026-10-12).
void main() {
  test('Show Agent Messages is the one command, and Swarm\'s is gone', () {
    expect(
      harnessCommandById['agent_messages.show']?.label,
      'Show Agent Messages',
    );
    expect(harnessCommandById['agent_messages.toggle'], isNull);
    expect(harnessCommandById['team.open'], isNull);
  });

  Future<void> search(WidgetTester tester, String query) async {
    await chord(tester, LogicalKeyboardKey.keyP, shift: true);
    await tester.enterText(
      find.byKey(const ValueKey('swarm-search-input')),
      query,
    );
    await tester.pump();
  }

  testWidgets('the palette offers the log and nothing to turn on', (
    tester,
  ) async {
    final app = createApp();
    addTearDown(app.dispose);
    await joinAgentMessagesDesk(app);
    await mount(tester, app);
    await search(tester, '> agent messages');
    // The row, and the preview of the chosen one.
    expect(find.text('Show Agent Messages'), findsWidgets);
    expect(find.textContaining('for this tab'), findsNothing);
    expect(find.textContaining('Tab conversation'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a tab without Agent Messages lists no command', (tester) async {
    // Before the desk is joined there is no log to show.
    final app = createApp()..status = AppStatus.authenticated;
    addTearDown(app.dispose);
    await mount(tester, app);
    await search(tester, '> agent messages');
    expect(find.text('Show Agent Messages'), findsNothing);
    expect(find.textContaining('for this tab'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Show Agent Messages opens this tab\'s log', (tester) async {
    final app = createApp();
    addTearDown(app.dispose);
    await joinAgentMessagesDesk(app);
    await mount(tester, app);
    app.renameSwarm(app.activeSwarmId, 'app');
    await tester.pump();
    await search(tester, '> show agent messages');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('app · Agent Messages'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('app · Agent Messages'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
