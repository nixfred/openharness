// Real-font review captures of the daemon: the status slot in every mood and
// nest stage (with its tally, a shiny `*`, alerts and replies), the hatch
// reveal's frames and rarity tells, and the panel (the zoo's box back, the
// card, a calm unreachable machine, light themes). Always checks that nothing
// overflows; writes PNGs only when asked:
//
//   HARNESS_DAEMON_CAPTURE_DIR=/private/tmp/daemon-review \
//     flutter test test/daemon_review_render_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/core/local_key_value_store.dart';
import 'package:harness/daemons/daemon_brain.dart';
import 'package:harness/daemons/daemon_face.dart';
import 'package:harness/daemons/render.dart';
import 'package:harness/daemons/roster.dart';
import 'package:harness/daemons/zoo.dart';
import 'package:harness/daemons/zoo_controller.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/shared/theme/workspace_bar_style.dart';
import 'package:harness/terminal/terminal_text.dart';
import 'package:harness/terminal/terminal_theme_store.dart';
import 'package:harness/terminal/terminal_typography.dart';
import 'package:harness/widgets/daemon_hatch.dart';
import 'package:harness/widgets/daemon_panel.dart';
import 'package:harness/widgets/daemon_slot.dart';
import 'package:xterm/xterm.dart' show TerminalStyle, TerminalTheme;

import 'support/real_fonts.dart';

class _Memory implements LocalKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

final _roster = daemonRoster;

/// Every scheme the app ships is dark; light captures use Solarized Light.
const _solarizedLight = TerminalTheme(
  cursor: Color(0xff268bd2),
  selection: Color(0x40268bd2),
  foreground: Color(0xff586e75),
  background: Color(0xfffdf6e3),
  black: Color(0xff073642),
  red: Color(0xffdc322f),
  green: Color(0xff859900),
  yellow: Color(0xffb58900),
  blue: Color(0xff268bd2),
  magenta: Color(0xffd33682),
  cyan: Color(0xff2aa198),
  white: Color(0xffeee8d5),
  brightBlack: Color(0xff002b36),
  brightRed: Color(0xffcb4b16),
  brightGreen: Color(0xff586e75),
  brightYellow: Color(0xff657b83),
  brightBlue: Color(0xff839496),
  brightMagenta: Color(0xff6c71c4),
  brightCyan: Color(0xff93a1a1),
  brightWhite: Color(0xfffdf6e3),
  searchHitBackground: Color(0xffb58900),
  searchHitBackgroundCurrent: Color(0xffcb4b16),
  searchHitForeground: Color(0xfffdf6e3),
);
final _output = Platform.environment['HARNESS_DAEMON_CAPTURE_DIR'];

Zoo _paired(
  String id, {
  String version = '2.0',
  bool shiny = false,
  int? serial,
  List<String>? more,
  List<ZooEgg> eggs = const [],
  ZooProgress progress = ZooProgress.empty,
}) => Zoo(
  daemons: [
    ZooDaemon(
      id: id,
      hatchedAt: '2026-09-26T09:42:00Z',
      egg: 'first',
      version: version,
      shiny: shiny,
      serial: serial,
      xp: const {'0.1': 0, '1.0': 150, '2.0': 600}[version]!,
    ),
    for (final other in more ?? const <String>[])
      ZooDaemon(
        id: other,
        hatchedAt: '2026-09-26T10:00:00Z',
        egg: 'turn',
        // A duplicate grows on its own: the second fzf has reached 1.0.
        xp: other == 'fzf' ? 150 : 0,
        version: other == 'fzf' ? '1.0' : '0.1',
      ),
  ],
  pair: id,
  habits: const ['turn', 'split', 'find', 'machine', 'store'],
  firstEgg: true,
  eggs: eggs,
  progress: progress,
);

/// A face over a local zoo, settled.
Future<DaemonFace> _face(WidgetTester tester, Zoo zoo) async {
  final storage = _Memory()
    ..values[ZooController.localZooKey] = jsonEncode({
      'zoo': zoo.toJson(),
      'seeded': true,
    });
  final controller = ZooController(storage: storage);
  final face = DaemonFace(controller);
  addTearDown(() {
    face.dispose();
    controller.dispose();
  });
  controller.bind('guest');
  await tester.pump();
  face.sync(const DaemonWatch());
  return face;
}

Future<void> _fonts() async {
  if (Platform.isMacOS) {
    for (final (family, path) in [
      ('.AppleSystemUIFont', '/System/Library/Fonts/SFNS.ttf'),
      ('SF Pro Text', '/System/Library/Fonts/SFNS.ttf'),
      ('Roboto', '/System/Library/Fonts/SFNS.ttf'),
      ('.AppleSystemUIFontMonospaced', '/System/Library/Fonts/SFNSMono.ttf'),
      ('SF Mono', '/System/Library/Fonts/SFNSMono.ttf'),
      ('Menlo', '/System/Library/Fonts/SFNSMono.ttf'),
    ]) {
      final bytes = ByteData.sublistView(await File(path).readAsBytes());
      await (FontLoader(family)..addFont(Future.value(bytes))).load();
    }
  } else {
    await loadRealFonts();
  }
}

Future<void> _capture(
  WidgetTester tester,
  String name,
  Size size,
  Widget Function(BuildContext context) build, {
  Brightness brightness = Brightness.dark,
  Duration settle = const Duration(milliseconds: 50),
  Future<void> Function()? act,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final previousBrightness = grid.AppTheme.brightness.value;
  final previousFont = terminalFontStore.value;
  final previousTheme = terminalThemeStore.value;
  grid.AppTheme.brightness.value = brightness;
  terminalFontStore.value = TerminalStyle(
    fontFamily: terminalFontFamily,
    fontFamilyFallback: terminalFontFallback,
    fontSize: 13,
  );
  terminalThemeStore.value = TerminalThemeChoice.matchApp;
  debugDaemonTerminalTheme = brightness == Brightness.light
      ? _solarizedLight
      : null;
  addTearDown(() {
    debugDaemonTerminalTheme = null;
    grid.AppTheme.brightness.value = previousBrightness;
    terminalFontStore.value = previousFont;
    terminalThemeStore.value = previousTheme;
  });
  final boundary = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: grid.buildAppTheme(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: TerminalFontScope(child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            backgroundColor: currentTerminalTheme().background,
            body: build(context),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(settle);
  if (act != null) {
    await act();
    await tester.pump(settle);
  }
  expect(tester.takeException(), isNull, reason: name);
  final output = _output;
  if (output == null) return;
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// One status bar: context text, then the slot, as the workspace draws it.
Widget _bar(
  BuildContext context,
  DaemonFace face,
  String caption, {
  DaemonBrain? brain,
}) {
  final theme = currentTerminalTheme();
  final cell = workspaceBarCellSizeOf(context);
  return Container(
    height: workspaceBarControlHeight(context),
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: theme.foreground.withValues(alpha: .08)),
      ),
    ),
    child: Row(
      children: [
        SizedBox(width: cell.width),
        SizedBox(
          width: cell.width * 20,
          child: Text(
            caption,
            style: workspaceBarTextStyle(
              color: theme.foreground.withValues(alpha: .5),
            ),
          ),
        ),
        Expanded(
          child: DaemonVoiceLine(
            face: face,
            brain: brain,
            onAnswer: (_) {},
            fallback: Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Codex  m2:harness  (main)',
                style: workspaceBarTextStyle(color: theme.foreground),
              ),
            ),
          ),
        ),
        SizedBox(width: cell.width),
        DaemonSlotButton(face: face, onPressed: () {}),
        SizedBox(width: cell.width),
      ],
    ),
  );
}

void main() {
  setUpAll(_fonts);

  testWidgets('status slot: nest stages, versions, moods, tally and voice', (
    tester,
  ) async {
    final rows = <(String, DaemonFace)>[];
    // The nest follows render.mjs nestStage: 3 habits, a finished turn
    // among them; without one, at most two count.
    for (final (habits, label) in [
      (const <String>[], 'nest 0/3'),
      (const ['split'], 'nest 1/3'),
      (const ['split', 'find', 'store'], 'nest 2/3 no turn'),
      (const ['turn', 'split', 'find'], 'egg ready'),
    ]) {
      final ready = habits.contains('turn') && habits.length >= 3;
      final face = await _face(
        tester,
        Zoo(
          habits: habits,
          firstEgg: ready,
          eggs: [
            if (ready) const ZooEgg(id: 'egg1', kind: 'first', grantedAt: ''),
          ],
        ),
      );
      rows.add((label, face));
    }
    for (final kind in ['setup', 'week', 'night', 'history', 'easter']) {
      rows.add((
        '$kind egg',
        await _face(
          tester,
          Zoo(
            eggs: [ZooEgg(id: kind, kind: kind, grantedAt: '')],
          ),
        ),
      ));
    }
    for (final version in ['0.1', '1.0', '2.0']) {
      rows.add((
        'tim $version',
        await _face(tester, _paired('tim', version: version)),
      ));
    }
    Future<DaemonFace> mood(
      String id,
      String label,
      DaemonWatch watch, {
      String version = '2.0',
    }) async {
      final face = await _face(tester, _paired(id, version: version));
      face.sync(watch);
      rows.add((label, face));
      return face;
    }

    final working = await mood(
      'tim',
      'tim 0.1 work',
      const DaemonWatch(working: true),
      version: '0.1',
    );
    working.pulse();
    await mood('fish', 'fish work', const DaemonWatch(working: true));
    await mood('vim', 'vim fail', const DaemonWatch(failing: true));
    await mood('fzf', 'fzf idle', const DaemonWatch());
    final bat = await _face(tester, _paired('bat'));
    bat.nap();
    rows.add(('bat nap', bat));
    await mood('grue', 'grue (dark)', const DaemonWatch());
    rows.add((
      'zsh shiny',
      await _face(tester, _paired('zsh', shiny: true)),
    ));
    // Finished turns: a count beside the slot, never a line.
    final done = await _face(tester, _paired('tim'));
    done
      ..sync(const DaemonWatch(turns: {'m': 0}))
      ..sync(const DaemonWatch(turns: {'m': 3}));
    rows.add(('tim +3 done', done));
    rows.add((
      'ping +1 egg',
      await _face(
        tester,
        _paired(
          'ping',
          eggs: const [ZooEgg(id: 'e1', kind: 'week', grantedAt: '')],
        ),
      ),
    ));
    // A need takes over in the message yellow; a boop's reply is dim.
    await mood(
      'vim',
      'vim need (alert)',
      const DaemonWatch(
        needIds: {'office/a1#r1'},
        needs: {
          'office/a1#r1': DaemonSubject(
            'office/a1',
            who: 'codex@office',
            q: 'run the migration?',
          ),
        },
      ),
    );
    final biff = await _face(tester, _paired('biff'));
    biff.boop();
    rows.add(('biff boop (reply)', biff));
    await _capture(
      tester,
      'status-slot',
      Size(760, 30.0 * rows.length + 20),
      (context) => Column(
        children: [
          for (final (label, face) in rows) _bar(context, face, label),
        ],
      ),
    );
    await tester.pumpWidget(const SizedBox());
    // Every motion ends at rest: stop work, wake the nap, let lines clear.
    for (final (_, face) in rows) {
      face
        ..sync(const DaemonWatch())
        ..wake();
    }
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('status slot on a light terminal', (tester) async {
    final done = await _face(tester, _paired('tim'));
    done
      ..sync(const DaemonWatch(turns: {'m': 0}))
      ..sync(const DaemonWatch(turns: {'m': 2}));
    final rows = <(String, DaemonFace)>[
      ('nest 2/5', await _face(tester, const Zoo(habits: ['turn', 'split']))),
      ('tim 2.0', await _face(tester, _paired('tim'))),
      ('ping 2.0', await _face(tester, _paired('ping'))),
      ('grue (light)', await _face(tester, _paired('grue'))),
      ('tim +2 done', done),
    ];
    await _capture(
      tester,
      'status-slot-light',
      Size(760, 30.0 * rows.length + 20),
      brightness: Brightness.light,
      (context) => Column(
        children: [
          for (final (label, face) in rows) _bar(context, face, label),
        ],
      ),
    );
    await tester.pumpWidget(const SizedBox());
    for (final (_, face) in rows) {
      face.sync(const DaemonWatch());
    }
    await tester.pump(const Duration(seconds: 4));
  });

  final egg = const ZooEgg(id: 'egg1', kind: 'first', grantedAt: '');
  final frames = <(String, String, HatchFrame, Brightness)>[
    (
      'hatch-1-egg',
      'tim',
      HatchFrame(stage: HatchStage.egg, egg: eggFrame(_roster)),
      Brightness.dark,
    ),
    (
      'hatch-2-wobble',
      'tim',
      HatchFrame(stage: HatchStage.egg, egg: eggFrame(_roster, offset: -1)),
      Brightness.dark,
    ),
    (
      'hatch-3-crack',
      'tim',
      HatchFrame(stage: HatchStage.crack, egg: eggFrame(_roster, crack: 2)),
      Brightness.dark,
    ),
    (
      'hatch-4-pop',
      'tim',
      HatchFrame(stage: HatchStage.pop, egg: eggPopFrame(_roster)),
      Brightness.dark,
    ),
    (
      'hatch-5-silhouette',
      'tim',
      const HatchFrame(stage: HatchStage.silhouette),
      Brightness.dark,
    ),
    (
      'hatch-6-colour',
      'tim',
      const HatchFrame(stage: HatchStage.colour),
      Brightness.dark,
    ),
    (
      'hatch-7-banner',
      'tim',
      const HatchFrame(stage: HatchStage.banner, bannerRows: 5),
      Brightness.dark,
    ),
    (
      'hatch-8-card',
      'tim',
      const HatchFrame(stage: HatchStage.card, bannerRows: 5),
      Brightness.dark,
    ),
    // The rarity, told at the crack.
    (
      'hatch-tell-rare-crack',
      'vim',
      HatchFrame(stage: HatchStage.crack, egg: eggFrame(_roster, crack: 2)),
      Brightness.dark,
    ),
    (
      'hatch-tell-legendary-pop',
      'fzf',
      HatchFrame(
        stage: HatchStage.pop,
        egg: eggPopFrame(_roster, sparks: true),
      ),
      Brightness.dark,
    ),
    (
      'hatch-tell-secret-dark-before-crack',
      'grue',
      HatchFrame(stage: HatchStage.crack, egg: eggFrame(_roster)),
      Brightness.dark,
    ),
    (
      'hatch-tell-secret-crack-light-theme',
      'grue',
      HatchFrame(stage: HatchStage.crack, egg: eggFrame(_roster, crack: 1)),
      Brightness.light,
    ),
    (
      'hatch-secret-pitch',
      'grue',
      const HatchFrame(stage: HatchStage.pitch),
      Brightness.dark,
    ),
    (
      'hatch-secret-silhouette',
      'grue',
      const HatchFrame(stage: HatchStage.silhouette),
      Brightness.dark,
    ),
    (
      'hatch-secret-card',
      'grue',
      const HatchFrame(stage: HatchStage.card, bannerRows: 5),
      Brightness.dark,
    ),
    (
      'hatch-legendary-card',
      'fzf',
      const HatchFrame(stage: HatchStage.card, bannerRows: 5),
      Brightness.dark,
    ),
    (
      'hatch-rare-card-light',
      'zsh',
      const HatchFrame(stage: HatchStage.card, bannerRows: 5),
      Brightness.light,
    ),
  ];
  for (final (name, id, frame, brightness) in frames) {
    testWidgets('hatch reveal: $name', (tester) async {
      await _capture(
        tester,
        name,
        const Size(520, 760),
        brightness: brightness,
        (context) => Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: SizedBox(
              width: terminalCellSizeOf(context).width * 46,
              child: DaemonHatchReveal(
                roster: _roster,
                egg: egg,
                result: Future.value(
                  ZooHatch(eggId: 'egg1', daemonId: id, shiny: false),
                ),
                zoo: () => _paired(id),
                onClose: () {},
                still: frame,
              ),
            ),
          ),
        ),
      );
      if (frame.stage == HatchStage.card) {
        expect(find.byKey(const ValueKey('daemon-hatch-card')), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('hatch reveal: a shiny card', (tester) async {
    await _capture(
      tester,
      'hatch-shiny-card',
      const Size(520, 760),
      (context) => Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SizedBox(
            width: terminalCellSizeOf(context).width * 46,
            child: DaemonHatchReveal(
              roster: _roster,
              egg: egg,
              result: Future.value(
                const ZooHatch(eggId: 'egg1', daemonId: 'bat', shiny: true),
              ),
              zoo: () => _paired('bat', shiny: true),
              onClose: () {},
              still: const HatchFrame(stage: HatchStage.card, bannerRows: 5),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('SHINY COMMON'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  final today = localDayOf(DateTime.now());
  final panels = <(String, Zoo, Brightness, DaemonWatch, String?)>[
    (
      'panel-nest',
      const Zoo(habits: ['turn', 'split', 'store']),
      Brightness.dark,
      const DaemonWatch(),
      null,
    ),
    (
      'panel-nest-single-machine',
      const Zoo(habits: ['split', 'find']),
      Brightness.dark,
      const DaemonWatch(),
      null,
    ),
    (
      'panel-egg-ready',
      const Zoo(
        habits: ['turn', 'split', 'find', 'machine', 'store'],
        firstEgg: true,
        eggs: [ZooEgg(id: 'egg1', kind: 'first', grantedAt: '')],
      ),
      Brightness.dark,
      const DaemonWatch(),
      null,
    ),
    (
      'panel-tim-zoo-box',
      _paired(
        'tim',
        more: ['fzf', 'fzf', 'grue', 'vim'],
        eggs: const [
          ZooEgg(id: 'e1', kind: 'turn', grantedAt: ''),
          ZooEgg(id: 'e2', kind: 'turn', grantedAt: ''),
          ZooEgg(id: 'e3', kind: 'week', grantedAt: ''),
        ],
        progress: ZooProgress(turns: 108, days: {today: 7}),
      ),
      Brightness.dark,
      const DaemonWatch(idleCount: 2),
      null,
    ),
    (
      'panel-vim-need',
      _paired('vim', more: ['tim']),
      Brightness.dark,
      const DaemonWatch(
        needIds: {'office/a1#r1'},
        needs: {
          'office/a1#r1': DaemonSubject(
            'office/a1',
            who: 'codex@office',
            q: 'run the migration?',
          ),
        },
      ),
      null,
    ),
    (
      'panel-away-calm',
      _paired('tim'),
      Brightness.dark,
      const DaemonWatch(
        away: [
          DaemonMachine(name: 'office', status: 'asleep'),
          DaemonMachine(name: 'studio', status: 'unreachable'),
        ],
      ),
      null,
    ),
    (
      'panel-grue',
      _paired('grue'),
      Brightness.dark,
      const DaemonWatch(),
      null,
    ),
    (
      'panel-grue-light',
      _paired('grue', more: ['tim']),
      Brightness.light,
      const DaemonWatch(),
      null,
    ),
    (
      'panel-bat-light',
      _paired('bat', more: ['tim', 'zsh']),
      Brightness.light,
      const DaemonWatch(),
      null,
    ),
    (
      'panel-card',
      _paired('zsh', shiny: true, serial: 42, more: ['tim']),
      Brightness.dark,
      const DaemonWatch(),
      'daemon-card',
    ),
  ];
  // The now tab tells what is going on; the rest show the zoo.
  const nowPanels = {'panel-vim-need', 'panel-away-calm'};
  for (final (name, zoo, brightness, watch, tap) in panels) {
    testWidgets('panel: $name', (tester) async {
      final face = await _face(tester, zoo);
      face.sync(watch);
      face.settings.tab = nowPanels.contains(name) ? 'now' : 'zoo';
      await _capture(
        tester,
        name,
        const Size(520, 1100),
        brightness: brightness,
        act: tap == null
            ? null
            : () async {
                await tester.tap(find.byKey(ValueKey(tap)));
              },
        (context) => Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: SizedBox(
              width: terminalCellSizeOf(context).width * 46,
              child: DaemonPanel(
                face: face,
                onClose: () {},
                onHatch: (_) {},
                onCommand: (_) {},
                shortcut: (command) => switch (command) {
                  'agent.new' => '⌘N',
                  'agent.open' => '⌘O',
                  'pane.split_right' => '⌘R',
                  'machines.list' => '⌘M',
                  'app.store' => '⌘S',
                  'harnesses.list' => '⌘P',
                  _ => null,
                },
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('daemon-panel')), findsOneWidget);
      if (name == 'panel-card') {
        expect(find.byKey(const ValueKey('daemon-card-text')), findsOneWidget);
        expect(find.textContaining('SHINY RARE', findRichText: true), findsWidgets);
        expect(find.textContaining('#0042', findRichText: true), findsWidgets);
      }
      if (name == 'panel-tim-zoo-box') {
        expect(find.text('[ ? ]'), findsNWidgets(6));
        expect(find.text('1.0 x2'), findsOneWidget);
        expect(find.textContaining('28/40'), findsOneWidget);
      }
      if (name == 'panel-away-calm') {
        expect(face.mood, DaemonMood.idle, reason: 'asleep is not a failure');
        expect(find.byKey(const ValueKey('daemon-panel-away')), findsOneWidget);
      }
      if (name == 'panel-nest-single-machine') {
        expect(
          find.text('all of it can happen on this computer.'),
          findsOneWidget,
        );
      }
      await tester.pumpWidget(const SizedBox());
      face.sync(const DaemonWatch());
      await tester.pump(const Duration(minutes: 3));
    });
  }

  // ── round 3: the pair brain in the window, and economy v2 ───────────────

  testWidgets('status line: the pair brain keys first, and the +n', (
    tester,
  ) async {
    const need = DaemonSay(
      id: 'need:1',
      about: DaemonAbout('office', 'a1', requestId: 'r1'),
      line: '[y/n/g] api@office Bash: npm test',
      mood: DaemonSayMood.need,
      actions: [
        (key: 'y', label: 'Yes', choice: '1. Yes'),
        (key: 'n', label: 'No', choice: '3. No'),
        (key: 'g', label: 'open', choice: 'open'),
      ],
      ttl: Duration(milliseconds: 5200),
    );
    Future<DaemonFace> saying(DaemonSay say, {DaemonWatch? watch}) async {
      final face = await _face(tester, _paired('tim'));
      if (watch != null) face.sync(watch);
      face.sayFromBrain(say);
      return face;
    }

    final rows = <(String, DaemonFace)>[
      (
        'need, keys first',
        await saying(
          need,
          watch: const DaemonWatch(
            needIds: {'office/a1#r1'},
            needs: {
              'office/a1#r1': DaemonSubject(
                'office/a1',
                who: 'codex@office',
                q: 'Bash: npm test',
              ),
            },
          ),
        ),
      ),
      (
        'ask (a proposal)',
        await saying(
          const DaemonSay(
            id: 'ask:1',
            about: DaemonAbout('m', ''),
            line: '[y/n] start codex in ~/api?',
            mood: DaemonSayMood.ask,
            actions: [
              (key: 'y', label: 'do it', choice: 'y'),
              (key: 'n', label: 'skip', choice: 'n'),
            ],
            ttl: Duration(milliseconds: 5200),
          ),
          watch: const DaemonWatch(asks: 1),
        ),
      ),
      (
        'lesson [y/n/s]',
        await saying(
          const DaemonSay(
            id: 'lesson:l1:1',
            about: DaemonAbout('m', 'a7'),
            line:
                '[y/n/s] teach your agents "run-migrations-safely"? you corrected codex.',
            mood: DaemonSayMood.ask,
            actions: [
              (key: 'y', label: 'teach', choice: 'y'),
              (key: 'n', label: 'skip', choice: 'n'),
              (key: 's', label: 'show', choice: 's'),
            ],
            ttl: Duration(milliseconds: 5200),
          ),
        ),
      ),
      (
        'say (it answers)',
        await saying(
          const DaemonSay(
            id: 'say:1',
            about: DaemonAbout('m', ''),
            line: 'api waits on you, 40m. office is asleep.',
            mood: DaemonSayMood.say,
            ttl: Duration(seconds: 30),
          ),
        ),
      ),
      (
        'auto (it acted)',
        await saying(
          const DaemonSay(
            id: 'auto:1',
            about: DaemonAbout('office', 'a2'),
            line: 'rule: web@office answered "1. Yes"',
            mood: DaemonSayMood.auto,
            ttl: Duration(milliseconds: 5200),
          ),
        ),
      ),
    ];
    final done = await _face(tester, _paired('tim'));
    done.sync(
      const DaemonWatch(
        doneCount: 3,
        doneLast: ['api@office finished: tests pass.'],
      ),
    );
    rows.add(('+3 from the brain', done));
    await _capture(
      tester,
      'status-brain',
      Size(900, 30.0 * rows.length + 20),
      (context) => Column(
        children: [
          for (final (label, face) in rows) _bar(context, face, label),
        ],
      ),
    );
    expect(find.text('api@office Bash: npm test'), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-answer-y')), findsWidgets);
    expect(find.text('+3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    for (final (_, face) in rows) {
      face.sync(const DaemonWatch());
    }
    await tester.pump(const Duration(minutes: 3));
  });

  /// A brain that has heard a whole session, as a hardened harnessd sends it:
  /// talk, asks with their harness and detail, a lesson waiting, a brief, a
  /// journal, the dial and machines; it answers the lessons list itself. Its
  /// clock is the test's, so lines arm as they would.
  DaemonBrain pairBrain(
    WidgetTester tester, {
    bool keysLive = true,
    String autonomy = 'suggest',
    List<Map<String, dynamic>> confirms = const [],
    String? requested,
    bool asks = true,
    bool brief = true,
  }) {
    late final DaemonBrain brain;
    var offset = Duration.zero;
    brain = DaemonBrain(
      now: () => tester.binding.clock.now().add(offset),
      send: (type, payload) {
        if (type == 'pair' && payload['verb'] == 'lessons') {
          final requestId = payload['requestId'];
          brain.receive('pair_result', {
            'requestId': requestId,
            ...switch (payload['action']) {
              'show' => {
                'ok': true,
                'text':
                    '---\nname: tests-need-docker\n---\n'
                    'Start docker before `npm test` in api.',
              },
              _ => {
                'ok': true,
                'git': true,
                'lessons': [
                  {
                    'id': 'l1',
                    'kind': 'skill',
                    'name': 'run-migrations-safely',
                    'status': 'pending',
                    'description': 'Back up before migrating.',
                    'learnedBy': 'tim',
                  },
                  {
                    'id': 'l2',
                    'kind': 'skill',
                    'name': 'tests-need-docker',
                    'status': 'pending',
                    'description': 'Start docker before the api tests.',
                    'learnedBy': 'tim',
                  },
                  {
                    'id': 'l0',
                    'kind': 'note',
                    'name': 'note-l0',
                    'status': 'approved',
                    'approved': '2026-09-25',
                    'project': 'api',
                    'description': 'Tests need docker running.',
                    'learnedBy': 'tim',
                  },
                ],
              },
            },
          });
        }
        return true;
      },
    );
    addTearDown(brain.dispose);
    final at = DateTime.now().millisecondsSinceEpoch;
    brain.receive('daemon_state', {
      'pair': 'tim',
      'needs': [
        {
          'machineId': 'office',
          'machine': 'office',
          'agentId': 'a1',
          'name': 'api',
          'requestId': 'r1',
          'question': 'Bash: npm test',
          'allow': true,
          'detail':
              'Bash command\n\n  npm test -- --runInBand\n  Run the api tests\n\n'
              'Do you want to proceed?\n> 1. Yes\n  3. No',
          'id': 'need:office:e:1',
          'line': '[y/n/g] api@office Bash: npm test',
          'actions': [
            {'key': 'y', 'label': 'Yes', 'choice': '1. Yes'},
            {'key': 'n', 'label': 'No', 'choice': '3. No'},
            {'key': 'g', 'label': 'open', 'choice': 'open'},
          ],
        },
        {
          'machineId': 'm',
          'machine': 'laptop',
          'agentId': 'a4',
          'name': 'web',
          'requestId': 'r4',
          'question': 'Which branch should I use?',
        },
      ],
      'working': 1,
      'failing': [],
      'machines': [
        {'machineId': 'm', 'name': 'laptop', 'status': 'ok', 'local': true},
        {'machineId': 'office', 'name': 'office', 'status': 'ok'},
        {'machineId': 'studio', 'name': 'studio', 'status': 'asleep'},
      ],
      'done': {'count': 0, 'last': []},
      'asks': [
        if (asks) ...[
          {
            'id': 'ask:7',
            'line': '[y/n] start codex in ~/code/api?',
            'from': 'pair',
            'verb': 'start_harness',
            'harness': {
              'machineId': 'm',
              'machine': 'laptop',
              'agentId': null,
              'name': 'codex',
            },
            'detail':
                'start codex in ~/code/api (mode ask)\nfirst prompt: run the '
                'migrations on a copy of the database and report what fails',
            'actions': [
              {'key': 'y', 'label': 'do it', 'choice': 'y'},
              {'key': 'n', 'label': 'skip', 'choice': 'n'},
            ],
          },
          {
            'id': 'lesson:l1:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f',
            'line':
                '[y/n/s] teach your agents "run-migrations-safely"? you '
                'corrected codex.',
            'detail':
                '---\nname: run-migrations-safely\ndescription: Back up before '
                'migrating.\n---\n1. `npm run db:backup`\n2. `npm run migrate`\n'
                '3. If it fails: `npm run db:restore`',
            'actions': [
              {'key': 'y', 'label': 'teach', 'choice': 'y'},
              {'key': 'n', 'label': 'skip', 'choice': 'n'},
              {'key': 's', 'label': 'show', 'choice': 's'},
            ],
          },
        ],
      ],
      'acted': [
        {
          'machineId': 'office',
          'machine': 'office',
          'agentId': 'a2',
          'name': 'web@office',
          'by': 'rule',
          'action': 'answer',
          'text': 'answered "1. Yes"',
          'at': at - 3 * 60000,
        },
        {
          'machineId': 'm',
          'machine': 'laptop',
          'agentId': 'a5',
          'name': 'docs',
          'by': 'pair',
          'action': 'send',
          'text': 'sent "update the changelog"',
          'at': at - 12 * 60000,
        },
      ],
      'autonomy': autonomy,
      'autonomyRequested': ?requested,
      'confirms': confirms,
    });
    if (brief) {
      brain.receive('daemon_brief', {
        'desk': 'd',
        'line': 'reattached. 2 done, 1 waiting 40m, studio asleep.',
        'items': [
          {
            'id': 'brief:office:r1:1',
            'kind': 'waiting',
            'machineId': 'office',
            'machine': 'office',
            'agentId': 'a1',
            'name': 'api',
            'line': '[y/n/g] api@office: Bash: npm test (40m)',
            'detail': 'Bash command\n\n  npm test -- --runInBand\n',
            'actions': [
              {'key': 'y', 'label': 'Yes', 'choice': '1. Yes'},
              {'key': 'n', 'label': 'No', 'choice': '3. No'},
            ],
          },
          {
            'id': 'failed:m:a6',
            'kind': 'failed',
            'machineId': 'm',
            'machine': 'laptop',
            'agentId': 'a6',
            'line': 'billing failed: exit 1',
          },
          {
            'id': 'asleep:studio',
            'kind': 'asleep',
            'machineId': 'studio',
            'machine': 'studio',
            'line': 'studio is asleep.',
          },
          {
            'id': 'done:office:a9',
            'kind': 'done',
            'machineId': 'office',
            'machine': 'office',
            'agentId': 'a9',
            'line': 'web@office finished 2 turns: deployed the preview.',
          },
        ],
      });
    }
    if (!keysLive) offset = const Duration(minutes: 5);
    return brain;
  }

  Widget panelFor(BuildContext context, DaemonFace face, DaemonBrain brain) =>
      Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SizedBox(
            width: terminalCellSizeOf(context).width * 46,
            child: DaemonPanel(
              face: face,
              brain: brain,
              onClose: () {},
              onHatch: (_) {},
              onCommand: (_) {},
              onAnswer: (_, _, _) {},
              onOpenConversation: () {},
              onOpenRules: () {},
              talkShortcut: '⌘⌥T',
              shortcut: (_) => null,
            ),
          ),
        ),
      );

  Zoo watching(Zoo zoo) => zoo.copyWith(
    consent: const ZooConsent(
      watching: true,
      at: '2026-09-26T09:00:00.000Z',
    ),
  );

  /// A face whose brain lines, talk and tabs are live.
  Future<(DaemonFace, DaemonBrain)> pairPanel(
    WidgetTester tester,
    String tab, {
    Zoo? zoo,
    String autonomy = 'suggest',
    List<Map<String, dynamic>> confirms = const [],
    String? requested,
    bool asks = true,
    bool brief = true,
  }) async {
    final face = await _face(
      tester,
      watching(zoo ?? _paired('tim', more: ['vim', 'fzf'])),
    );
    face.settings.tab = tab;
    final brain = pairBrain(
      tester,
      autonomy: autonomy,
      confirms: confirms,
      requested: requested,
      asks: asks,
      brief: brief,
    );
    face.sync(
      DaemonWatch(
        asks: brain.state!.asks.length + brain.state!.confirms.length,
        needIds: const {'office/a1#r1', 'm/a4#r4'},
        needs: const {
          'office/a1#r1': DaemonSubject(
            'office/a1',
            who: 'claude@office',
            q: 'Bash: npm test',
          ),
        },
        away: const [DaemonMachine(name: 'studio', status: 'asleep')],
        autonomy: autonomy,
        autonomyRequested: requested,
      ),
    );
    return (face, brain);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  // ── round 4: consent, trust, and a panel you can scan ──────────────────

  testWidgets('panel tab 1: now (the line, what waits, the brief, what tim '
      'did, the talk)', (tester) async {
    final (face, brain) = await pairPanel(tester, 'now');
    brain.talkTo('what needs me?');
    brain.receive('daemon_say', {
      'id': 'say:1',
      'about': {'machineId': 'm', 'agentId': ''},
      'mood': 'say',
      'from': 'pair',
      'line': 'api@office waits on npm test, 40m. studio is asleep.',
      'actions': [],
      'ttlMs': 30000,
    });
    brain.talkTo('approve it if the tests are only unit tests');
    await _capture(
      tester,
      'panel-tab-1-now',
      const Size(560, 2400),
      act: () => settle(tester),
      (context) => panelFor(context, face, brain),
    );
    expect(find.text('1:now*'), findsOneWidget);
    expect(find.text('<tim> start codex in ~/code/api?'), findsOneWidget);
    expect(find.text('codex@laptop'), findsOneWidget, reason: 'the harness');
    expect(find.textContaining('first prompt: run the migrations'), findsOneWidget);
    expect(find.text('web@laptop: Which branch should I use?'), findsOneWidget);
    expect(find.text('what tim did'), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-talk-cost')), findsOneWidget);
    expect(brain.wasShown('ask:7'), isTrue, reason: 'on screen, so shown');
    await tester.pumpWidget(const SizedBox());
    face.sync(const DaemonWatch());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('panel tab 2: zoo', (tester) async {
    final (face, brain) = await pairPanel(
      tester,
      'zoo',
      zoo: _paired(
        'tim',
        more: ['vim', 'fzf'],
        eggs: const [
          ZooEgg(id: 'e1', kind: 'turn', grantedAt: ''),
          ZooEgg(id: 'e2', kind: 'week', grantedAt: ''),
        ],
        progress: ZooProgress(turns: 108, days: {today: 7}),
      ),
    );
    await _capture(
      tester,
      'panel-tab-2-zoo',
      const Size(560, 1250),
      (context) => panelFor(context, face, brain),
    );
    expect(find.text('2:zoo*'), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-portrait')), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-panel-zoo')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    face.sync(const DaemonWatch());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('panel tab 3: lessons (the proposed one in full, keys '
      'arming; the rest by terminal)', (tester) async {
    final (face, brain) = await pairPanel(tester, 'lessons');
    await _capture(
      tester,
      'panel-tab-3-lessons-arming',
      const Size(560, 1200),
      act: () async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      },
      (context) => panelFor(context, face, brain),
    );
    const id = 'lesson:l1:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f';
    expect(
      find.byKey(const ValueKey('daemon-key-lesson-ask:$id-y-arming')),
      findsOneWidget,
    );
    expect(find.textContaining('npm run db:restore'), findsOneWidget);
    expect(find.textContaining('harness pair lessons approve l2'), findsOneWidget);
    await _capture(
      tester,
      'panel-tab-3-lessons',
      const Size(560, 1200),
      act: () async {
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('daemon-lesson-show:l2')));
        await settle(tester);
      },
      (context) => panelFor(context, face, brain),
    );
    expect(find.byKey(const ValueKey('daemon-key-lesson-ask:$id-y')), findsOneWidget);
    expect(find.textContaining('Start docker before'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    face.sync(const DaemonWatch());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('panel tab 4: settings (switches, the dial, the floor, '
      'consent)', (tester) async {
    final (face, brain) = await pairPanel(tester, 'settings');
    await _capture(
      tester,
      'panel-tab-4-settings',
      const Size(560, 1300),
      (context) => panelFor(context, face, brain),
    );
    expect(find.text('4:settings*'), findsOneWidget);
    expect(find.text('(*) suggest'), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-panel-floor')), findsOneWidget);
    expect(
      find.textContaining('tim watches your harnesses since 2026-09-26'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    face.sync(const DaemonWatch());
    await tester.pump(const Duration(minutes: 3));
  });

  const autonomyConfirm = {
    'id': 'confirm:autonomy:k1',
    'kind': 'autonomy',
    'nonce': 'k1',
    'line':
        '[y/n] let your daemon act at act-on-key? it stays at suggest until '
        'you say yes',
    'detail':
        'autonomy suggest -> act-on-key\nact-on-key: it drives harnesses it '
        'started without asking (the floor still holds); the rest wait for '
        'your key.\nThe floor holds at every level: nothing is deleted, '
        'restarted, forked or bypassed; a push, force, rm -rf, sudo, deploy, '
        'publish, drop or merge is never approved; only a one-time yes to an '
        'allow-class prompt.',
    'actions': [
      {'key': 'y', 'label': 'confirm', 'choice': 'y'},
      {'key': 'n', 'label': 'keep it as it is', 'choice': 'n'},
    ],
    'level': 'act-on-key',
  };

  testWidgets('an autonomy confirm: exactly what changes, keys armed', (
    tester,
  ) async {
    final (face, brain) = await pairPanel(
      tester,
      'settings',
      confirms: [autonomyConfirm],
      requested: 'act-on-key',
    );
    await _capture(
      tester,
      'panel-autonomy-confirm',
      const Size(560, 1500),
      act: () => settle(tester),
      (context) => panelFor(context, face, brain),
    );
    expect(find.text('(~) act on key  waits for your yes'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('daemon-key-confirm:confirm:autonomy:k1-y'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    face.sync(const DaemonWatch());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('a pair.jsonc confirm lists what it turns on', (tester) async {
    final (face, brain) = await pairPanel(
      tester,
      'settings',
      confirms: [
        {
          'id': 'confirm:rules:n2',
          'kind': 'rules',
          'nonce': 'n2',
          'line':
              '[y/n] use pair.jsonc as it is now? 1 rule, model off, learn '
              'borrow + export claude; until you say yes, none of it',
          'detail':
              'pair.jsonc (1 rule, model off, learn borrow + export claude):\n'
              '{\n  "learn": { "borrow": true, "export": ["claude"] },\n'
              '  "rules": [{ "name": "tests in api", "harness": "api*", '
              '"question": "npm (run )?test", "choice": "Yes" }]\n}',
          'actions': [
            {'key': 'y', 'label': 'confirm', 'choice': 'y'},
            {'key': 'n', 'label': 'keep it as it is', 'choice': 'n'},
          ],
        },
      ],
    );
    await _capture(
      tester,
      'panel-rules-confirm',
      const Size(560, 1500),
      act: () => settle(tester),
      (context) => panelFor(context, face, brain),
    );
    expect(find.textContaining('learn.borrow'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    face.sync(const DaemonWatch());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('panel: the dial at act within rules, a light terminal', (
    tester,
  ) async {
    final (face, brain) = await pairPanel(
      tester,
      'settings',
      zoo: _paired('tim').copyWith(autonomy: 'act-within-rules'),
      autonomy: 'act-within-rules',
    );
    await _capture(
      tester,
      'panel-autonomy-light',
      const Size(560, 1300),
      brightness: Brightness.light,
      (context) => panelFor(context, face, brain),
    );
    expect(find.text('(*) act within rules'), findsOneWidget);
    expect(find.text('[act within rules]'), findsOneWidget, reason: 'badge');
    await tester.pumpWidget(const SizedBox());
    face.sync(const DaemonWatch());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('what tim did: the journal and what it taught, with revert', (
    tester,
  ) async {
    final (face, brain) = await pairPanel(
      tester,
      'now',
      asks: false,
      brief: false,
    );
    await _capture(
      tester,
      'panel-what-tim-did',
      const Size(560, 900),
      act: () => settle(tester),
      (context) => panelFor(context, face, brain),
    );
    expect(find.byKey(const ValueKey('daemon-panel-did')), findsOneWidget);
    expect(find.text('noted for api · 2026-09-25'), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-did-revert:l0')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    face.sync(const DaemonWatch());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('a say with its detail: the disclosure under the status line, '
      'keys arming, then armed', (tester) async {
    final face = await _face(tester, watching(_paired('tim')));
    final brain = pairBrain(tester);
    face.sync(
      const DaemonWatch(
        needIds: {'office/a1#r1'},
        needs: {
          'office/a1#r1': DaemonSubject(
            'office/a1',
            who: 'claude@office',
            q: 'Bash: npm test',
          ),
        },
      ),
    );
    const detail =
        'Bash command\n\n  npm test -- --runInBand\n  Run the api tests\n\n'
        'Do you want to proceed?\n> 1. Yes\n  2. Yes, and don\'t ask again for '
        'npm test commands in ~/code/api\n  3. No, and tell Claude what to do '
        'differently (esc)';
    final say = DaemonSay.fromJson({
      'id': 'need:office:e:1',
      'about': {'machineId': 'office', 'agentId': 'a1', 'requestId': 'r1'},
      'mood': 'need',
      'line': '[y/n/g] api@office Bash: npm test',
      'detail': detail,
      'harness': {
        'machineId': 'office',
        'machine': 'office',
        'agentId': 'a1',
        'name': 'api',
      },
      'actions': [
        {'key': 'y', 'label': 'Yes', 'choice': '1. Yes'},
        {'key': 'n', 'label': 'No', 'choice': '3. No'},
        {'key': 'g', 'label': 'open', 'choice': 'open'},
      ],
      'ttlMs': 5200,
    })!;
    face.sayFromBrain(say);
    Widget scene(BuildContext context) => Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _bar(context, face, 'need, with detail', brain: brain),
        Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: workspaceBarCellSizeOf(context).width * 72,
            child: DaemonDetailNotice(
              title: 'api@office · exactly what a key does',
              detail: detail,
              actions: say.actions,
              onShown: () => brain.shown(say.id),
            ),
          ),
        ),
      ],
    );
    await _capture(
      tester,
      'status-detail-arming',
      const Size(900, 360),
      scene,
    );
    expect(find.byKey(const ValueKey('daemon-answer-y-arming')), findsOneWidget);
    expect(brain.wasShown(say.id), isTrue);
    await tester.pump(DaemonBrain.armAfter);
    await _capture(
      tester,
      'status-detail-armed',
      const Size(900, 360),
      scene,
    );
    expect(find.byKey(const ValueKey('daemon-answer-y')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    face.sync(const DaemonWatch());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('the pair speaking: its nick, no keys; its proposal keys first',
      (tester) async {
    final brain = pairBrain(tester, brief: false);
    Future<DaemonFace> saying(Map<String, dynamic> raw) async {
      final face = await _face(tester, watching(_paired('tim')));
      if (raw['mood'] == 'ask') face.sync(const DaemonWatch(asks: 1));
      face.sayFromBrain(DaemonSay.fromJson(raw)!);
      return face;
    }

    final rows = <(String, DaemonFace)>[
      (
        'the pair says',
        await saying({
          'id': 'say:1',
          'about': {'machineId': 'm', 'agentId': ''},
          'mood': 'say',
          'from': 'pair',
          'line': 'api waits on npm test, 40m. studio is asleep.',
          'actions': [],
          'ttlMs': 30000,
        }),
      ),
      (
        'a fact (daemon)',
        await saying({
          'id': 'set:autonomy:1',
          'about': {'machineId': 'm', 'agentId': ''},
          'mood': 'say',
          'from': 'daemon',
          'line': 'autonomy suggest -> act-on-key: it drives harnesses it '
              'started.',
          'actions': [],
          'ttlMs': 30000,
        }),
      ),
      (
        'the pair proposes',
        await saying({
          'id': 'ask:7',
          'about': {'machineId': 'm', 'agentId': ''},
          'mood': 'ask',
          'from': 'pair',
          'line': '[y/n] start codex in ~/code/api?',
          'actions': [
            {'key': 'y', 'label': 'do it', 'choice': 'y'},
            {'key': 'n', 'label': 'skip', 'choice': 'n'},
          ],
          'ttlMs': 5200,
        }),
      ),
    ];
    await _capture(
      tester,
      'status-pair-voice',
      Size(900, 30.0 * rows.length + 20),
      (context) => Column(
        children: [
          for (final (label, face) in rows)
            _bar(context, face, label, brain: brain),
        ],
      ),
    );
    expect(find.textContaining('<tim> ', findRichText: true), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    for (final (_, face) in rows) {
      face.sync(const DaemonWatch());
    }
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('the brief on return, under the status line', (tester) async {
    final brain = pairBrain(tester);
    await _capture(
      tester,
      'brief-notice',
      const Size(760, 320),
      act: () => settle(tester),
      (context) => Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: DaemonBriefNotice(
            name: 'tim',
            brief: brain.brief!,
            armed: brain.armed,
            arming: brain,
            onShown: brain.shown,
            onAnswer: (_, _, _) {},
          ),
        ),
      ),
    );
    expect(find.text('api@office: Bash: npm test (40m)'), findsOneWidget);
    expect(find.byKey(const ValueKey('daemon-brief-key-0-y')), findsOneWidget);
    expect(find.textContaining('npm test -- --runInBand'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (name, stage) in [
    ('hatch-consent', HatchStage.consent),
    ('hatch-consent-suggest', HatchStage.suggest),
  ]) {
    testWidgets('the consent after a hatch: $name', (tester) async {
      await _capture(
        tester,
        name,
        const Size(520, 620),
        (context) => Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: SizedBox(
              width: terminalCellSizeOf(context).width * 46,
              child: DaemonHatchReveal(
                roster: _roster,
                egg: egg,
                result: Future.value(
                  const ZooHatch(eggId: 'egg1', daemonId: 'tim', shiny: false),
                ),
                zoo: () => _paired('tim', version: '0.1'),
                needsConsent: true,
                onClose: () {},
                still: HatchFrame(stage: stage),
              ),
            ),
          ),
        ),
      );
      expect(
        find.byKey(
          ValueKey(
            stage == HatchStage.consent
                ? 'daemon-consent-watch'
                : 'daemon-consent-suggest-yes',
          ),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final (name, morph) in [
    ('hatch-levelup-morph-1', 1),
    ('hatch-levelup-morph-2', 2),
    ('hatch-levelup-morph-3', 3),
    ('hatch-levelup-held', null),
  ]) {
    testWidgets('level-up in the reveal: $name', (tester) async {
      final before = _paired('tim', version: '0.1');
      final after = before.copyWith(
        daemons: [
          const ZooDaemon(
            id: 'tim',
            hatchedAt: '2026-09-26T09:42:00Z',
            egg: 'first',
            dupes: 1,
            xp: 150,
            bond: 2,
            version: '1.0',
          ),
        ],
      );
      await _capture(
        tester,
        name,
        const Size(520, 480),
        (context) => Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: SizedBox(
              width: terminalCellSizeOf(context).width * 46,
              child: DaemonHatchReveal(
                roster: _roster,
                egg: egg,
                result: Future.value(
                  const ZooHatch(
                    eggId: 'egg1',
                    daemonId: 'tim',
                    shiny: false,
                    duplicate: true,
                    xp: 150,
                  ),
                ),
                zoo: () => after,
                before: before,
                onClose: () {},
                still: HatchFrame(stage: HatchStage.grew, morph: morph),
              ),
            ),
          ),
        ),
      );
      expect(
        find.byKey(
          ValueKey(
            morph == null
                ? 'daemon-hatch-portrait'
                : 'daemon-hatch-morph-$morph',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('daemon-hatch-changelog')),
        morph == null ? findsOneWidget : findsNothing,
      );
      if (morph == null) {
        expect(
          find.text(
            'tim 1.0: split-window -h: a second pane; learned your agents '
            'by name',
          ),
          findsOneWidget,
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final (name, stage) in [
    ('hatch-duplicate', HatchStage.merged),
    ('hatch-duplicate-grew', HatchStage.grew),
  ]) {
    testWidgets('hatch reveal: $name', (tester) async {
      final before = _paired('tim', version: '0.1', more: ['vim']);
      final after = before.copyWith(
        daemons: [
          before.daemons.first,
          const ZooDaemon(
            id: 'vim',
            hatchedAt: '2026-09-26T10:00:00Z',
            egg: 'turn',
            dupes: 1,
            shiny: true,
            xp: 150,
            bond: 2,
            version: '1.0',
          ),
        ],
      );
      await _capture(
        tester,
        name,
        const Size(520, 420),
        (context) => Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: SizedBox(
              width: terminalCellSizeOf(context).width * 46,
              child: DaemonHatchReveal(
                roster: _roster,
                egg: egg,
                result: Future.value(
                  const ZooHatch(
                    eggId: 'egg1',
                    daemonId: 'vim',
                    shiny: true,
                    duplicate: true,
                    xp: 150,
                  ),
                ),
                zoo: () => after,
                before: before,
                onClose: () {},
                still: HatchFrame(stage: stage),
              ),
            ),
          ),
        ),
      );
      expect(find.text('vim x2 · +150 xp'), findsOneWidget);
      expect(find.text('another vim. +150 xp. yours is shiny now.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('daemon-hatch-grew')),
        stage == HatchStage.grew ? findsOneWidget : findsNothing,
      );
      expect(find.byKey(const ValueKey('daemon-hatch-card')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
