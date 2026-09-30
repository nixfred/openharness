import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/core/models.dart';
import 'package:harness/notify/alert_sounds.dart';
import 'package:harness/state/app_state.dart';
import 'package:harness/state/notification_inbox.dart';
import 'package:harness/state/status_menu.dart';
import 'package:harness/state/terminal_pane.dart';
import 'package:harness/state/workspace_status.dart';

import 'keymap_host_test.dart' show key;
import 'support/resource_picker.dart';
import 'swarm_attention_test.dart' show waitingQuestion;
import 'swarm_screen_test.dart' show mount, terminal;
import 'swarm_state_test.dart' show createApp;

void main() {
  test('lists every unread harness and excludes recent sessions without notifications', () {
    final app = createApp(connected: true);
    addTearDown(app.dispose);
    for (var i = 0; i < 30; i++) {
      app.rememberOpenedHarness('m', 'a$i');
      if (i >= 10) app.agentUnread.mark('m', 'a$i', AlertKind.done);
    }
    final entries = statusMenuEntries(app);
    expect(entries, hasLength(20));
    expect(entries.every((r) => r['unread'] == true), isTrue);
    expect(entries.any((r) => r['agentId'] == 'a0'), isFalse);
    expect(entries.map((r) => r['agentId']).toSet(), hasLength(entries.length));
    expect(entries.first['agentId'], 'a29');
    expect(entries.first['tabId'], isNull);
    expect(entries.first['tabName'], 'Other sessions');
    expect(entries.first['detail'], contains('Test host'));
    expect(entries.first['unavailable'], isNull);
    app.stateOf('m')!.nodeOnline = false;
    expect(statusMenuEntries(app).first['unavailable'], 'Offline');
    clearStatusMenuNotifications(app, entries);
    expect(
      statusMenuEntries(app),
      isEmpty,
      reason: 'read conversations never fill an empty notification menu',
    );
  });

  test('groups by tab identity across machines, in tab order with Other sessions last', () {
    final app = createApp(connected: true);
    addTearDown(app.dispose);
    const remote = Machine(
      machineId: 'remote',
      name: 'Remote host',
      authMode: MachineAuthMode.remote,
    );
    app.machineStates['remote'] = MachineState(remote)
      ..agents = [Agent(id: 'a0', name: 'Remote result', engine: 'codex')];
    final first = app.activeSwarm;
    app.renameSwarm(first.id, 'Design');
    first.panes.addAll([
      TerminalPane(id: 1, machineId: 'm', agentId: 'a0'),
      TerminalPane(id: 2, machineId: 'remote', agentId: 'a0'),
    ]);
    app.newSwarm(name: 'Design');
    final second = app.activeSwarm;
    second.panes.add(TerminalPane(id: 3, machineId: 'm', agentId: 'a1'));
    app.agentUnread.mark('m', 'a0', AlertKind.done);
    app.agentUnread.mark('m', 'a1', AlertKind.done);
    app.agentUnread.mark('remote', 'a0', AlertKind.done);
    app.agentUnread.mark('m', 'a9', AlertKind.done);

    final rows = statusMenuEntries(app);
    expect(rows.map((r) => (r['machineId'], r['agentId'])), [
      ('remote', 'a0'),
      ('m', 'a0'),
      ('m', 'a1'),
      ('m', 'a9'),
    ]);
    expect(rows.map((r) => r['tabId']), [first.id, first.id, second.id, null]);
    expect(rows.map((r) => r['tabName']), [
      'Design',
      'Design',
      'Design',
      'Other sessions',
    ]);

    app.renameSwarm(second.id, 'Review');
    expect(statusMenuEntries(app)[2]['tabName'], 'Review');
    expect(
      statusMenuReceiptIsCurrent(app, rows[2]),
      isTrue,
      reason: 'renaming a tab does not replace its notification',
    );
  });

  test(
    'a shared session counts once and follows tab membership and display names',
    () {
      final app = createApp(connected: true);
      addTearDown(app.dispose);
      final first = app.activeSwarm;
      final pane = TerminalPane(id: 1, machineId: 'm', agentId: 'a0');
      first.panes.add(pane);
      app.agentUnread.mark('m', 'a0', AlertKind.done);
      expect(
        statusMenuEntries(app).single['tabName'],
        workspaceTabNames(app)[first.id],
      );
      expect(statusMenuEntries(app).single['tabName'], isNot(first.name));

      app.newSwarm(name: 'Review');
      final second = app.activeSwarm..panes.add(pane);
      expect(statusMenuEntries(app).single['tabId'], second.id);
      app.newSwarm(name: 'Unrelated');
      expect(statusMenuEntries(app).single['tabId'], first.id);
      first.remove(pane);
      expect(statusMenuEntries(app).single['tabId'], second.id);
      second.remove(pane);
      expect(statusMenuEntries(app).single['tabName'], 'Other sessions');
      expect(statusMenuEntries(app).single['tabId'], isNull);
      expect(app.agentUnread.kindFor('m', 'a0'), AlertKind.done);
    },
  );

  test(
    'machine profiles keep unread sessions grouped under their hidden tabs',
    () {
      final app = createApp(connected: true);
      addTearDown(app.dispose);
      final hidden = app.activeSwarm;
      app.renameSwarm(hidden.id, 'Remote work');
      hidden.panes.add(TerminalPane(id: 1, machineId: 'remote', agentId: 'a0'));
      app.newSwarm(name: 'Local work');
      app.activeSwarm.panes.add(
        TerminalPane(id: 2, machineId: 'm', agentId: 'a1'),
      );
      app.setMachineProfile('m');
      app.agentUnread.mark('remote', 'a0', AlertKind.done);
      expect(app.profileSwarms, isNot(contains(hidden)));
      expect(statusMenuEntries(app).single['tabName'], 'Remote work');
      expect(statusMenuEntries(app).single['tabId'], hidden.id);
    },
  );

  test(
    'clear acknowledges displayed news, never answers or clears newer news',
    () {
      final app = createApp(connected: true);
      addTearDown(app.dispose);
      final machine = app.stateOf('m')!;
      app.agentUnread.mark('m', 'a0', AlertKind.done);
      machine.blockedAgents['a1'] = waitingQuestion('a1');
      app.agentUnread.mark('m', 'a1', AlertKind.needsYou);
      app.rememberOpenedHarness('m', 'a2');
      machine.blockedAgents['a2'] = waitingQuestion('a2', requestId: 'old');
      final displayed = statusMenuEntries(app);
      expect(displayed.where((r) => r['unread'] == true), hasLength(3));

      app.agentUnread.mark('m', 'a0', AlertKind.done, fresh: true);
      app.agentUnread.mark('m', 'a3', AlertKind.failed);
      machine.blockedAgents['a2'] = waitingQuestion('a2', requestId: 'new');
      clearStatusMenuNotifications(app, displayed);

      expect(notificationInbox(app).map((r) => r.agentId).toSet(), {
        'a0',
        'a2',
        'a3',
      });
      expect(app.questionFor('m', 'a1'), isNotNull);
      expect(app.questionNotificationRead('m', 'a1'), isTrue);
      clearStatusMenuNotifications(app, statusMenuEntries(app));
      expect(notificationInbox(app), isEmpty);
      expect(machine.blockedAgents.keys, containsAll(['a1', 'a2']));
    },
  );

  testWidgets(
    'native menu reuses panes, rejects stale clicks and clears its snapshot',
    (tester) async {
      const channel = MethodChannel('harness/swarm_tabs');
      const windowChannel = MethodChannel('window_manager');
      final updates = <Map>[];
      final windowActions = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'update') updates.add(call.arguments as Map);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        windowActions.add(call.method);
        return call.method == 'isMinimized' ? true : null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(windowChannel, null),
      );
      final app = createApp(connected: true)..watchedAgents = () => const [];
      final resultTab = app.activeSwarmId;
      final result = app.adoptSessionForTest(terminal('a8', []));
      app.newSwarm(name: 'Desktop');
      app.adoptSessionForTest(terminal('a0', []));
      final originalTab = app.activeSwarmId;
      app.agentUnread.mark('m', 'a8', AlertKind.done);
      app.stateOf('m')!.blockedAgents['a9'] = waitingQuestion('a9');
      app.agentUnread.mark('m', 'a9', AlertKind.needsYou);
      await mount(tester, app, nativeTabs: true);
      await tester.pumpAndSettle();
      List<Map> rows() =>
          (updates.last['statusMenuEntries'] as List).cast<Map>();
      Future<void> select(String method, Map args) async {
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, args),
          ),
          (_) => done.complete(),
        );
        // Native focus handoff replies after the destination's next frame.
        for (var i = 0; i < 8 && !done.isCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(done.isCompleted, isTrue);
      }

      expect(
        find.byKey(const ValueKey('workspace-notifications-button')),
        findsNothing,
      );
      expect(rows(), hasLength(2));
      expect(updates.last['unread'], rows().length);
      final stale = rows().singleWhere((r) => r['agentId'] == 'a8');
      app.agentUnread.mark('m', 'a8', AlertKind.failed, fresh: true);
      await tester.pump();
      await select('openStatusHarness', stale);
      expect(app.activeSwarmId, originalTab);
      expect(app.agentUnread.kindFor('m', 'a8'), AlertKind.failed);

      final displayedResult = rows().singleWhere((r) => r['agentId'] == 'a8');
      expect(displayedResult['tabId'], resultTab);
      // A shared session becomes visible in the active tab while the native
      // menu is tracking. The click still belongs to the displayed tab.
      app.activeSwarm.panes.add(result);
      app.renameSwarm(originalTab, 'Desktop review');
      await tester.pump();
      expect(
        rows().singleWhere((r) => r['agentId'] == 'a8')['tabId'],
        originalTab,
      );
      await select('openStatusHarness', displayedResult);
      expect(app.activeSwarmId, resultTab);
      expect(app.focusedPane, same(result));
      expect(app.allPanes.where((p) => p.agentId == 'a8'), hasLength(1));
      expect(app.agentUnread.kindFor('m', 'a8'), isNull);
      expect(rows().single['agentId'], 'a9');
      expect(updates.last['unread'], 1);
      expect(
        windowActions,
        containsAllInOrder(['isMinimized', 'restore', 'show', 'focus']),
      );

      // If the displayed tab has since closed, use the remaining view without
      // resurrecting a tab or creating another terminal controller.
      app.agentUnread.mark('m', 'a8', AlertKind.done);
      await tester.pump();
      final movedResult = rows().singleWhere((r) => r['agentId'] == 'a8');
      await app.closeSwarm(resultTab);
      await tester.pump();
      await select('openStatusHarness', movedResult);
      expect(app.activeSwarmId, originalTab);
      expect(app.focusedPane, same(result));
      expect(app.swarms.any((tab) => tab.id == resultTab), isFalse);
      expect(app.agentUnread.kindFor('m', 'a8'), isNull);

      final displayed = rows();
      app.agentUnread.mark('m', 'a7', AlertKind.done);
      await tester.pump();
      await select('clearStatusNotifications', {'receipts': displayed});
      expect(app.questionFor('m', 'a9'), isNotNull);
      expect(app.questionNotificationRead('m', 'a9'), isTrue);
      expect(notificationInbox(app).single.agentId, 'a7');
      expect(rows().single['agentId'], 'a7');
      expect(app.focusedPane, same(result), reason: 'clearing never navigates');
      await select('clearStatusNotifications', {'receipts': rows()});
      expect(rows(), isEmpty);
      expect(updates.last['unread'], 0);

      // Open Harness from an empty notification menu still opens the normal
      // picker, ready for typing, and selecting a session reuses its pane.
      await select('addAgent', {});
      expect(resourceScope('#'), findsOneWidget);
      final input = tester.widget<TextField>(resourceField);
      expect(input.focusNode!.hasFocus, isTrue);
      await tester.enterText(resourceField, 'Agent 0');
      await tester.pumpAndSettle();
      await selectResource(tester, 'a0');
      await key(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(resourceField, findsNothing);
      expect(app.activeSwarmId, originalTab);
      expect(app.focusedPane?.agentId, 'a0');
      expect(app.allPanes.where((p) => p.agentId == 'a0'), hasLength(1));

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpWidget(const SizedBox());
      expect(updates.last['enabled'], isFalse);
      expect(updates.last['statusMenuEntries'], isNull);
      app.dispose();
    },
  );
}
