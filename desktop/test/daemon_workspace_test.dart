// The daemon in the workspace: when it may appear, the habits the window
// reports, the hatch and its reveal, the panel, and what native hears.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/core/models.dart';
import 'package:harness/daemons/roster.dart';
import 'package:harness/daemons/zoo.dart';
import 'package:harness/daemons/zoo_controller.dart';
import 'package:harness/screens/swarm_screen.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/state/app_state.dart';
import 'package:harness/ws/local_cli_discovery.dart';
import 'package:harness/state/swarm_catalog.dart' show SwarmProjectStore;

import 'daemons/zoo_test.dart' show FakeZooTransport;
import 'keymap_host_test.dart' show key;
import 'swarm_screen_test.dart' show terminal;
import 'swarm_state_test.dart' show createApp;

const _habits5 = ['turn', 'split', 'find', 'machine', 'store'];

void main() {
  late AppNotifier app;
  late ZooController zoo;
  late FakeZooTransport remote;

  setUp(() {
    app = createApp();
    app.currentUser = const CurrentUserProfile(
      id: 'u1',
      email: 'review@example.test',
    );
  });
  tearDown(() => app.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Zoo seed = Zoo.empty,
    bool native = false,
    bool reduceMotion = false,
    Completer<void>? gate,
  }) async {
    remote = FakeZooTransport()
      ..zoo = seed
      ..revision = 1
      ..gate = gate;
    zoo = ZooController(random: Random(1));
    addTearDown(zoo.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: grid.buildAppTheme(brightness: Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: SwarmScreen(
          notifier: app,
          nativeTabs: native,
          projectStore: SwarmProjectStore(),
          zoo: zoo,
          zooTransport: remote,
          daemonClock: () => tester.binding.clock.now(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  }

  final slot = find.byKey(const ValueKey('daemon-slot'));
  /// What the slot's ten cells draw, without the gutters.
  String glyph(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('daemon-slot-glyph')))
      .data!
      .trim();

  testWidgets('nothing shows until the profile and the zoo have loaded', (
    tester,
  ) async {
    app.currentUser = null;
    final gate = Completer<void>();
    await mount(tester, gate: gate);
    expect(slot, findsNothing);
    expect(zoo.scope, isNull, reason: 'no temporary scope before the profile');
    app.currentUser = const CurrentUserProfile(id: 'u1', email: 'a@b.test');
    app.notifyListeners();
    await tester.pump();
    expect(zoo.scope, 'account:u1');
    expect(slot, findsNothing, reason: 'the first read is still in flight');
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(slot, findsOneWidget);
    expect(glyph(tester), r'\_O_/');
    await unmount(tester);
  });

  testWidgets('a guest has a local zoo at once', (tester) async {
    app.signedIn = false;
    await mount(tester);
    await tester.pump();
    expect(zoo.source, ZooSource.local);
    expect(slot, findsOneWidget);
    expect(remote.fetches, 0);
    await unmount(tester);
  });

  testWidgets('habits come from real signals and are reported once', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump();
    expect(remote.zoo.habits, isEmpty);
    // A finished turn in a harness open here.
    app.adoptSessionForTest(terminal('a0', []));
    await app.handleMachineEventForTest('m', {
      'type': 'turn_ended',
      'agentId': 'a0',
    });
    await tester.pump();
    // Two harnesses side by side.
    app.adoptSessionForTest(terminal('a1', []));
    app.notifyListeners();
    await tester.pump();
    // A paused harness resumed from this window.
    app.stateOf('m')!.resumedHarnesses = 1;
    app.notifyListeners();
    await tester.pump();
    await zoo.flush();
    await tester.pump();
    expect(remote.zoo.habits, containsAll(['turn', 'split', 'resume']));
    expect(remote.zoo.habits, isNot(contains('elsewhere')));
    final sent = remote.batches
        .expand((b) => b)
        .where((op) => op['op'] == 'zoo.habit')
        .map((op) => op['key'])
        .toList();
    expect(sent.toSet().length, sent.length, reason: 'each habit once');
    expect(glyph(tester), r'~\_O_/~');
    await unmount(tester);
  });

  testWidgets('the nest says how far along it is, and a ready egg hatches '
      'into a reveal that returns focus when closed', (tester) async {
    await mount(
      tester,
      seed: Zoo(
        habits: _habits5,
        firstEgg: true,
        eggs: const [ZooEgg(id: 'egg1', kind: 'first', grantedAt: '')],
      ),
    );
    await tester.pump();
    expect(glyph(tester), r'\_o.o_/');
    final before = FocusManager.instance.primaryFocus;
    await tester.tap(slot);
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-hatch')), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-hatch-egg')), findsOneWidget);
    expect(glyph(tester), r'\_o.o_/', reason: 'the slot keeps the egg');
    await tester.pump(const Duration(seconds: 7));
    final id = remote.zoo.daemons.single.id;
    final def = daemonRoster.byId(id)!;
    expect(find.byKey(const ValueKey('daemon-hatch-card')), findsOneWidget);
    expect(
      find.textContaining("fork() returned 0. it's a $id."),
      findsOneWidget,
    );
    expect(glyph(tester), isNot(r'\_o.o_/'), reason: 'revealed');
    // Copy puts a fenced code block on the clipboard.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('daemon-hatch-copy')));
    await tester.pump();
    expect(copied, startsWith('```\n.---'));
    expect(copied, contains('${def.id} 0.1'));
    expect(copied, endsWith("'\n```"));
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-hatch')), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot(contains('Hatch')),
    );
    expect(before, isNotNull);
    await unmount(tester);
  });

  testWidgets('Reduce Motion goes straight to the card', (tester) async {
    await mount(
      tester,
      reduceMotion: true,
      seed: Zoo(
        habits: _habits5,
        firstEgg: true,
        eggs: const [ZooEgg(id: 'egg1', kind: 'first', grantedAt: '')],
      ),
    );
    await tester.pump();
    await tester.tap(slot);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-hatch-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-hatch-egg')), findsNothing);
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-hatch')), findsNothing);
    await unmount(tester);
  });

  testWidgets('native never hears the hatchling before the reveal ends', (
    tester,
  ) async {
    final states = <Map>[];
    const channel = MethodChannel('harness/swarm_tabs');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'daemonState') states.add(call.arguments as Map);
      if (call.method == 'update') {
        final daemon = (call.arguments as Map?)?['daemon'];
        if (daemon is Map) states.add(daemon);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await mount(
      tester,
      native: true,
      seed: Zoo(
        habits: _habits5,
        firstEgg: true,
        eggs: const [ZooEgg(id: 'egg1', kind: 'first', grantedAt: '')],
      ),
    );
    await tester.pump();
    expect(states.last['glyph'], r'\_o.o_/');
    expect(states.last['label'], 'Egg, ready to hatch');
    const codec = StandardMethodCodec();
    // Native's click; the reply waits for the next frame, so it is not awaited.
    unawaited(
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'harness/swarm_tabs',
        codec.encodeMethodCall(const MethodCall('daemon')),
        (_) {},
      ),
    );
    await tester.pump();
    final start = states.length;
    // Up to just before the card: every frame of the reveal.
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find
          .byKey(const ValueKey('daemon-hatch-card'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      final id = remote.zoo.daemons.firstOrNull?.id;
      for (final state in states.skip(start)) {
        expect(state['glyph'], r'\_o.o_/');
        expect(state['busy'], isTrue);
        if (id != null) {
          expect(
            '${state['label']} ${state['tooltip']} ${state['detail']}',
            isNot(contains(id)),
          );
        }
      }
    }
    expect(find.byKey(const ValueKey('daemon-hatch-card')), findsOneWidget);
    await tester.pump();
    final id = remote.zoo.daemons.single.id;
    expect(states.last['label'], id, reason: 'named once the card is up');
    expect(states.last['busy'], isFalse);
    await key(tester, LogicalKeyboardKey.escape);
    await unmount(tester);
  });

  testWidgets('the panel: portrait, lore, zoo, pair, rename and nap by '
      'keyboard', (tester) async {
    await mount(
      tester,
      seed: const Zoo(
        daemons: [
          ZooDaemon(id: 'tim', hatchedAt: '2026-09-26T09:00:00Z', egg: 'first'),
          ZooDaemon(
            id: 'fzf',
            hatchedAt: '2026-09-26T10:00:00Z',
            egg: 'turn',
            version: '2.0',
            xp: 600,
          ),
        ],
        pair: 'tim',
        habits: _habits5,
        firstEgg: true,
      ),
    );
    await tester.pump();
    expect(glyph(tester), '[o o]');
    await tester.tap(slot);
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-portrait')), findsOneWidget);
    expect(find.textContaining('screen -> tmux -> tim'), findsOneWidget);
    expect(find.textContaining('Named the way vim was'), findsOneWidget);
    // The zoo's box back: two owned, the rest numbered and unknown, the
    // secret marked.
    expect(find.text('[ ? ]'), findsNWidgets(7));
    expect(find.text('[ ! ]'), findsOneWidget);
    expect(find.text('#08 fzf'), findsOneWidget);
    // Move to fzf and pair it.
    await key(tester, LogicalKeyboardKey.keyJ);
    await tester.pump();
    await key(tester, LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      find.text(daemonRoster.byId('fzf')!.lore),
      findsOneWidget,
      reason: 'the panel now shows fzf',
    );
    await tester.tap(find.byKey(const ValueKey('daemon-pair')));
    await tester.pump();
    expect(zoo.zoo.pair, 'fzf');
    await zoo.flush();
    expect(remote.zoo.pair, 'fzf');
    // Rename it.
    await tester.tap(find.byKey(const ValueKey('daemon-rename')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('daemon-name-input')),
      'Scout',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await zoo.flush();
    expect(remote.zoo.daemons.last.nickname, 'Scout');
    expect(find.text('Scout (fzf)'), findsOneWidget);
    // Nap, then Escape closes and the slot shows the nap.
    await tester.tap(find.byKey(const ValueKey('daemon-nap')));
    // The click that opened the panel was a boop; it wins for 900 ms.
    await tester.pump(const Duration(seconds: 1));
    expect(glyph(tester), '> ;-;-;z');
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-panel')), findsNothing);
    await unmount(tester);
  });

  testWidgets('command search opens the panel as "Daemon"', (tester) async {
    await mount(tester);
    await tester.pump();
    await key(tester, LogicalKeyboardKey.keyP, cmd: true, shift: true);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('swarm-search-input')),
      '> Daemon',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await key(tester, LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('daemon-panel')), findsOneWidget);
    expect(find.text('Your first egg'), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-habit-turn')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-panel')), findsNothing);
    await unmount(tester);
  });

  testWidgets('zoo_changed refetches; the voice replaces the context', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump();
    remote
      ..zoo = const Zoo(
        daemons: [ZooDaemon(id: 'tim', hatchedAt: '', egg: 'first')],
        pair: 'tim',
      )
      ..revision = 5;
    await app.handleMachineEventForTest('m', {
      'type': 'zoo_changed',
      'payload': {'revision': 5},
    });
    await tester.pump();
    await tester.pump();
    expect(glyph(tester), '[o o]');
    await tester.tap(slot);
    await tester.pump();
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.byKey(const ValueKey('daemon-voice')),
      findsOneWidget,
      reason: "the boop's line, after the typing pause",
    );
    expect(find.text("tim: hey. that's my status line."), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const ValueKey('daemon-voice')), findsNothing);
    await unmount(tester);
  });
  for (final guest in [true, false]) {
    testWidgets(
      guest
          ? 'a guest earns from its own live turns'
          : 'signed in, turns are left to harnessd: no zoo.turn is sent',
      (tester) async {
        if (guest) app.signedIn = false;
        await mount(tester);
        await tester.pump();
        app.adoptSessionForTest(terminal('a0', []));
        Future<void> turn({bool live = true, bool aborted = false}) async {
          if (live) {
            await app.handleMachineEventForTest('m', {
              'type': 'turn_started',
              'agentId': 'a0',
            });
          }
          await app.handleMachineEventForTest('m', {
            'type': 'turn_ended',
            'agentId': 'a0',
            if (aborted) 'payload': {'aborted': true},
          });
          await tester.pump();
        }

        await turn();
        await turn(live: false); // picked up at attach: never counts
        await turn(aborted: true); // interrupted: never counts
        await turn();
        await zoo.flush();
        if (guest) {
          expect(zoo.zoo.progress.turns, 2);
        } else {
          expect(
            remote.batches.expand((b) => b).map((op) => op['op']),
            isNot(contains('zoo.turn')),
          );
          expect(zoo.zoo.progress.turns, 0);
        }
        await unmount(tester);
      },
    );
  }
  const zooOfTim = Zoo(
    daemons: [ZooDaemon(id: 'tim', hatchedAt: '', egg: 'first')],
    pair: 'tim',
    habits: _habits5,
    firstEgg: true,
  );

  testWidgets('a machine that is asleep or out of reach is calm: the face '
      'never fails for it, the panel says so', (tester) async {
    await mount(tester, seed: zooOfTim);
    await tester.pump();
    // The fixture's machine is not connected: an open harness on it is away.
    app.adoptSessionForTest(terminal('a0', []));
    app.notifyListeners();
    await tester.pump();
    expect(glyph(tester), '[o o]', reason: 'not x eyes');
    await tester.tap(slot);
    await tester.pump();
    expect(
      find.text('Test host is asleep or unreachable. its harnesses wait.'),
      findsOneWidget,
    );
    await key(tester, LogicalKeyboardKey.escape);
    await unmount(tester);
  });

  testWidgets('a failed turn in an open harness is a failure', (tester) async {
    app.stateOf('m')!
      ..nodeOnline = true
      ..connectionStatus = ConnectionStatus.connected;
    await mount(tester, seed: zooOfTim);
    await tester.pump();
    app.adoptSessionForTest(terminal('a0', []));
    await app.handleMachineEventForTest('m', {
      'type': 'turn_started',
      'agentId': 'a0',
    });
    await app.handleMachineEventForTest('m', {
      'type': 'turn_ended',
      'agentId': 'a0',
      'payload': {'error': 'exit 1'},
    });
    await tester.pump();
    expect(glyph(tester), '[x x]');
    await tester.pump(const Duration(seconds: 5));
    expect(glyph(tester), '[x x]', reason: 'its last turn failed');
    await app.handleMachineEventForTest('m', {
      'type': 'turn_started',
      'agentId': 'a0',
    });
    await tester.pump();
    expect(glyph(tester), startsWith('[= =]'), reason: 'a new turn');
    await app.handleMachineEventForTest('m', {
      'type': 'turn_ended',
      'agentId': 'a0',
    });
    await tester.pump();
    expect(glyph(tester), '[^ ^]', reason: 'it ended well');
    await unmount(tester);
  });

  testWidgets('agent events step the work frame, at most twice a second; '
      'a quiet agent is a still baton', (tester) async {
    app.stateOf('m')!
      ..nodeOnline = true
      ..connectionStatus = ConnectionStatus.connected;
    await mount(tester, seed: zooOfTim);
    await tester.pump();
    app.adoptSessionForTest(terminal('a0', []));
    await app.handleMachineEventForTest('m', {
      'type': 'turn_started',
      'agentId': 'a0',
    });
    await tester.pump();
    final first = glyph(tester);
    expect(first, startsWith('[= =]'));
    await tester.pump(const Duration(seconds: 3));
    expect(glyph(tester), first, reason: 'no events, no motion');
    await app.handleMachineEventForTest('m', {
      'type': 'tool_start',
      'agentId': 'a0',
      'payload': {'tool': 'Bash'},
    });
    await tester.pump();
    final second = glyph(tester);
    expect(second, isNot(first), reason: 'one event, one step');
    for (var i = 0; i < 5; i++) {
      await app.handleMachineEventForTest('m', {
        'type': 'text_delta',
        'agentId': 'a0',
        'payload': {'content': 'x'},
      });
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(glyph(tester), second, reason: 'at most two steps a second');
    await tester.pump(const Duration(milliseconds: 500));
    expect(glyph(tester), isNot(second));
    await app.handleMachineEventForTest('m', {
      'type': 'turn_ended',
      'agentId': 'a0',
    });
    await tester.pump();
    await unmount(tester);
  });

  testWidgets('finished turns are a +N beside the slot, cleared when you '
      'look; Quiet and Motion are switches in the panel', (tester) async {
    app.stateOf('m')!
      ..nodeOnline = true
      ..connectionStatus = ConnectionStatus.connected;
    await mount(tester, seed: zooOfTim);
    await tester.pump();
    app.adoptSessionForTest(terminal('a0', []));
    app.adoptSessionForTest(terminal('a1', []));
    await tester.pump();
    // a1 is in front: its turn is seen already; a0's is not.
    for (final id in ['a0', 'a1']) {
      await app.handleMachineEventForTest('m', {
        'type': 'turn_started',
        'agentId': id,
      });
      await app.handleMachineEventForTest('m', {
        'type': 'turn_ended',
        'agentId': id,
      });
    }
    await tester.pump();
    final focused = app.focusedPane!.agentId;
    expect(focused, isNotNull);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('daemon-slot-tally')))
          .data,
      '+1',
    );
    expect(find.byKey(const ValueKey('daemon-voice')), findsNothing);
    await tester.tap(slot);
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-slot-tally')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('daemon-quiet')));
    await tester.pump();
    expect(find.text('[ quiet: on ]'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('daemon-motion')));
    await tester.pump();
    expect(find.text('[ motion: off ]'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.byKey(const ValueKey('daemon-voice')),
      findsNothing,
      reason: "Quiet: not even the boop's reply",
    );
    await unmount(tester);
  });

  testWidgets('xyzzy in Cmd-O: "Nothing happens." and one zoo.easter', (
    tester,
  ) async {
    await mount(tester, seed: zooOfTim);
    await tester.pump();
    await key(tester, LogicalKeyboardKey.keyO, cmd: true);
    await tester.pump();
    final input = find.byKey(const ValueKey('swarm-search-input'));
    await tester.enterText(input, 'xyzzy');
    await tester.pump(const Duration(milliseconds: 100));
    // A result row, not a place to go.
    final note = find.byKey(const ValueKey('swarm-search-line:note:xyzzy'));
    expect(note, findsOneWidget);
    expect(
      find.descendant(of: note, matching: find.text('Nothing happens.')),
      findsOneWidget,
    );
    await tester.enterText(input, 'xyzz');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Nothing happens.'), findsNothing);
    await tester.enterText(input, 'XYZZY');
    await tester.pump(const Duration(milliseconds: 100));
    expect(note, findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('swarm-search-input')),
      findsOneWidget,
      reason: 'Return never takes the note',
    );
    await zoo.flush();
    final easter = remote.batches
        .expand((b) => b)
        .where((op) => op['op'] == 'zoo.easter')
        .toList();
    expect(easter, [
      {'op': 'zoo.easter', 'word': 'xyzzy'},
    ]);
    await key(tester, LogicalKeyboardKey.escape);
    await unmount(tester);
  });

  testWidgets('after the third hatch, any key skips to the card', (
    tester,
  ) async {
    await mount(
      tester,
      seed: const Zoo(
        daemons: [
          ZooDaemon(id: 'tim', hatchedAt: '', egg: 'first'),
          ZooDaemon(id: 'fish', hatchedAt: '', egg: 'turn'),
          ZooDaemon(id: 'ping', hatchedAt: '', egg: 'turn'),
        ],
        pair: 'tim',
        habits: _habits5,
        firstEgg: true,
        eggs: [ZooEgg(id: 'egg4', kind: 'turn', grantedAt: '')],
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('daemon-slot-tally')))
          .data,
      '+1 egg',
      reason: 'an egg waits beside the slot until it is opened',
    );
    await tester.tap(slot);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('daemon-egg:turn')));
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-hatch')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    await key(tester, LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-hatch-card')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('daemon-slot-tally')), findsNothing);
    await unmount(tester);
  });

  testWidgets('native hears the ten cells and the tally', (tester) async {
    final states = <Map>[];
    const channel = MethodChannel('harness/swarm_tabs');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'daemonState') states.add(call.arguments as Map);
      if (call.method == 'update') {
        final daemon = (call.arguments as Map?)?['daemon'];
        if (daemon is Map) states.add(daemon);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await mount(
      tester,
      native: true,
      seed: const Zoo(
        daemons: [
          ZooDaemon(id: 'tim', hatchedAt: '', egg: 'first', shiny: true),
        ],
        pair: 'tim',
        habits: _habits5,
        firstEgg: true,
        eggs: [ZooEgg(id: 'e1', kind: 'week', grantedAt: '')],
      ),
    );
    await tester.pump();
    expect(states.last['cell'], '* [o o]   ');
    expect(states.last['tally'], '+1 egg');
    expect(states.last['patch'], isNull, reason: 'a dark theme');
    await unmount(tester);
  });

  group('the pair brain', () {
    late List<(String, Map<String, dynamic>)> frames;
    setUp(() {
      frames = [];
      // This computer's own harnessd: the only socket daemon_* frames use.
      app.stateOf('m')!.localEndpoint = LocalCliEndpoint(
        computerId: 'test-computer',
        wsUri: Uri.parse('ws://fixture.invalid'),
        protocolVersion: 1,
        terminalProtocolVersion: 3,
      );
      app.daemonFrameSenderForTest = (type, payload) {
        frames.add((type, payload));
        return true;
      };
    });

    Future<void> frame(
      WidgetTester tester,
      String type,
      Map<String, dynamic> payload, {
      String machine = 'm',
    }) async {
      await app.handleMachineEventForTest(machine, {
        'type': type,
        'payload': payload,
      });
      await tester.pump();
    }

    const zooWithTim = Zoo(
      daemons: [ZooDaemon(id: 'tim', hatchedAt: '', egg: 'first')],
      pair: 'tim',
      habits: _habits5,
      firstEgg: true,
    );
    final question = {
      'id': 'q1',
      'about': 'office/a1',
      'mood': 'need',
      'line': 'codex@office wants to run the migration.',
      'actions': [
        {'key': 'y', 'label': 'run it', 'choice': '1'},
        {'key': 'n', 'label': 'not now', 'choice': '3'},
      ],
    };

    testWidgets('its state drives the face; its line offers answers', (
      tester,
    ) async {
      await mount(tester, seed: zooWithTim);
      await tester.pump();
      expect(glyph(tester), '[o o]');
      await frame(tester, 'daemon_state', {
        'pair': 'tim',
        'needs': [
          {
            'machineId': 'office',
            'agentId': 'a1',
            'requestId': 'r1',
            'name': 'migration',
          },
        ],
        'working': false,
        'failing': [],
        'machines': [],
      });
      expect(glyph(tester), '[? ?]', reason: 'a harness on another machine');
      expect(frames.first.$1, 'daemon_presence');
      expect(frames.first.$2['active'], isTrue);
      expect(frames.first.$2['desk'], isA<String>());
      expect(frames.first.$2.containsKey('pair'), isFalse, reason: 'signed in');
      // The pane in front of you is never spoken about: the brain hears it.
      app.adoptSessionForTest(terminal('a3', []));
      app.notifyListeners();
      await tester.pump();
      expect(frames.last.$1, 'daemon_presence');
      expect(frames.last.$2['focusAgentId'], 'a3');
      expect(frames.last.$2['focusMachineId'], 'm');
      await frame(tester, 'daemon_say', question);
      expect(
        find.text('tim: codex@office wants to run the migration.'),
        findsOneWidget,
      );
      expect(find.text('[y] run it'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('daemon-answer-y')));
      await tester.pump();
      expect(frames.last.$1, 'daemon_act');
      expect(frames.last.$2['id'], 'q1');
      expect(frames.last.$2['choice'], '1');
      expect(find.byKey(const ValueKey('daemon-voice')), findsNothing);
      // The chord answers too: ⌘⌥N.
      await frame(tester, 'daemon_say', {...question, 'id': 'q2'});
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(frames.last.$2['id'], 'q2');
      expect(frames.last.$2['choice'], '3');
      // A stale answer is explained in one line.
      await frame(tester, 'daemon_act_result', {
        'requestId': frames.last.$2['requestId'],
        'id': 'q2',
        'ok': false,
        'error': 'STALE_QUESTION',
      });
      await tester.pump(const Duration(seconds: 3));
      expect(
        find.text('tim: that question changed before the answer landed.'),
        findsOneWidget,
      );
      // Withdrawn lines go; frames from a relayed socket are never heard.
      await tester.pump(const Duration(seconds: 6));
      await frame(tester, 'daemon_say', {...question, 'id': 'q3'});
      await tester.pump(const Duration(seconds: 3));
      await frame(tester, 'daemon_unsay', {'id': 'q3', 'reason': 'answered'});
      expect(find.byKey(const ValueKey('daemon-voice')), findsNothing);
      app.machineStates['r'] = MachineState(
        const Machine(
          machineId: 'r',
          name: 'office',
          authMode: MachineAuthMode.remote,
        ),
      );
      await frame(tester, 'daemon_say', {
        ...question,
        'id': 'q4',
      }, machine: 'r');
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const ValueKey('daemon-voice')), findsNothing);
      await unmount(tester);
    });

    testWidgets('presence follows the window; the brief shows on return', (
      tester,
    ) async {
      app.signedIn = false;
      await mount(tester);
      await tester.pump();
      await frame(tester, 'daemon_state', {'pair': null, 'needs': []});
      expect(frames.single.$2['active'], isTrue);
      expect(
        frames.single.$2.containsKey('pair'),
        isFalse,
        reason: 'no pair yet',
      );
      // A guest's pair lives in its local zoo: the brain hears it paired.
      for (final key in _habits5) {
        zoo.habit(key);
      }
      final hatched = await zoo.hatch(zoo.readyEgg!.id);
      await tester.pump();
      expect(frames.last.$2['pair'], hatched!.daemonId);
      app.appLifecycleChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(frames.last.$2['active'], isFalse);
      app.appLifecycleChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(frames.last.$2['active'], isTrue);
      expect(frames.last.$2['awayMs'], isA<int>());
      expect(frames.last.$2['pair'], hatched.daemonId, reason: 'a guest');
      await frame(tester, 'daemon_brief', {
        'desk': frames.last.$2['desk'],
        'line': 'welcome back. 2 done, 1 waiting 40m.',
        'items': [
          {
            'id': 'i1',
            'kind': 'waiting',
            'machine': 'office',
            'line': 'migration waits 40m',
          },
        ],
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('daemon-brief')), findsOneWidget);
      expect(
        find.textContaining('office  migration waits 40m'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 11));
      expect(find.byKey(const ValueKey('daemon-brief')), findsNothing);
      await unmount(tester);
    });
  });
}
