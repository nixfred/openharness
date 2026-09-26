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
import 'package:xterm/xterm.dart' show TerminalStyle;

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
final _output = Platform.environment['HARNESS_DAEMON_CAPTURE_DIR'];

Zoo _paired(
  String id, {
  String version = '2.0',
  bool shiny = false,
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
  addTearDown(() {
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
Widget _bar(BuildContext context, DaemonFace face, String caption) {
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
    for (final (done, label) in [
      (0, 'nest 0/5'),
      (2, 'nest 2/5'),
      (4, 'nest 4/5'),
      (5, 'egg ready'),
    ]) {
      final face = await _face(
        tester,
        Zoo(
          habits: _roster.rules.habits.take(done).map((h) => h.key).toList(),
          firstEgg: done >= 5,
          eggs: [
            if (done >= 5)
              const ZooEgg(id: 'egg1', kind: 'first', grantedAt: ''),
          ],
        ),
      );
      rows.add((label, face));
    }
    for (final kind in ['week', 'night', 'history', 'easter']) {
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
      const DaemonWatch(away: ['office', 'studio']),
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
      _paired('zsh', shiny: true, more: ['tim']),
      Brightness.dark,
      const DaemonWatch(),
      'daemon-card',
    ),
  ];
  for (final (name, zoo, brightness, watch, tap) in panels) {
    testWidgets('panel: $name', (tester) async {
      final face = await _face(tester, zoo);
      face.sync(watch);
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
      await tester.pumpWidget(const SizedBox());
      face.sync(const DaemonWatch());
      await tester.pump(const Duration(minutes: 3));
    });
  }
}
