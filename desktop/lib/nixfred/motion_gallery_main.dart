import 'dart:async';

import 'package:flutter/material.dart';

import '../shared/theme/app_theme.dart' as grid;
import '../shared/theme/color_palette.dart';
import '../state/attention_state.dart';
import '../widgets/attention_glow.dart';
import 'dart:io';

import 'boot_splash.dart';
import 'brand_prefs.dart';
import 'brand_section.dart';
import 'fleet_graph.dart';
import '../core/local_key_value_store.dart';
import 'neon.dart';
import 'spend_ring.dart';

/// nixfred: a developer gallery for the motion work. It draws the REAL widgets (AttentionGlow,
/// SpendRing, FleetGraph, BootSplash) fed with sample frames in the daemon's `attention` shape, so
/// every state can be seen, screenshotted and CPU-measured without a daemon or a signed-in account.
/// Not part of the release app. Run:
///   flutter run -d linux -t lib/nixfred/motion_gallery_main.dart [--dart-define=GALLERY=idle]
/// `GALLERY=idle` puts every agent idle (the CPU-at-rest case); the default cycles the states.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  grid.AppTheme.palette.value = HarnessPalette.omarchy;
  if (_mode == 'settings') {
    // The real Appearance pickers on a throwaway store, so no personal setting is touched.
    final store = BrandPrefsStore(storage: _Memory(), dataDir: Directory.systemTemp.createTempSync('brand-gallery'));
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'nixfred motion gallery',
      theme: ThemeData.dark(),
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(24), child: SizedBox(width: 760, child: BrandSection(store: store)))),
    ));
    return;
  }
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, title: 'nixfred motion gallery', home: BootSplash(child: _Gallery())));
}

const _mode = String.fromEnvironment('GALLERY');

class _Gallery extends StatefulWidget {
  const _Gallery();
  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  final _attention = AttentionState();
  Timer? _timer;
  int _step = 0;

  static const _panes = [('a1', 'planner-1', 'planner'), ('a2', 'checker', 'checker'), ('a3', 'drafter', 'drafter'), ('a4', 'publisher', 'publisher'), ('a5', 'fixer', null), ('a6', 'scout', null)];
  static const _base = ['working', 'waiting', 'permission', 'failed', 'done', 'idle'];
  static const _spend = [0.42, 0.86, 1.0, 0.2, 0.6, null];

  @override
  void initState() {
    super.initState();
    _apply();
    if (_mode != 'idle' && _mode != 'still') {
      _timer = Timer.periodic(const Duration(seconds: 6), (_) {
        _step++;
        _apply();
      });
    }
  }

  void _apply() {
    _attention.apply({
      'hostname': 'host-a',
      'agents': [
        for (var i = 0; i < _panes.length; i++)
          {
            'agentId': _panes[i].$1,
            'name': _panes[i].$2,
            'machine': 'host-a',
            'lane': _panes[i].$3,
            'state': _mode == 'idle' ? 'idle' : _base[(i + _step) % _base.length],
            if (_spend[i] != null) 'spend': {'fraction': _spend[i], 'usd': (_spend[i]! * 5)},
          },
      ],
    });
    setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<FleetMachine> _fleet() => [
        FleetMachine(id: 'host-a', name: 'host-a', connected: true, local: true, agents: [
          for (final p in _panes.take(4))
            FleetAgent(id: p.$1, name: p.$2, state: _attention.of(p.$1)!.state, lane: p.$3, spendFraction: _attention.of(p.$1)!.spendFraction),
        ]),
        FleetMachine(id: 'host-b', name: 'host-b', connected: true, agents: [
          for (final p in _panes.skip(4)) FleetAgent(id: p.$1, name: p.$2, state: _attention.of(p.$1)!.state),
        ]),
        const FleetMachine(id: 'host-c', name: 'host-c', connected: false, agents: [FleetAgent(id: 'f1', name: 'mac-agent', state: AgentAttention.offline)]),
      ];

  @override
  Widget build(BuildContext context) {
    final neon = Neon.current();
    final mono = TextStyle(fontFamily: 'monospace', fontSize: 12, color: neon.foreground.withValues(alpha: 0.7));
    return Scaffold(
      backgroundColor: neon.background,
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: GridView.count(
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 3,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 1.25,
                children: [
                  for (final p in _panes)
                    ListenableBuilder(
                      listenable: _attention,
                      builder: (context, _) {
                        final row = _attention.of(p.$1)!;
                        return AttentionGlow(
                          attention: _attention,
                          agentId: p.$1,
                          child: ColoredBox(
                            color: neon.background,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    SpendRing(attention: _attention, agentId: p.$1, child: Icon(Icons.terminal, size: 17, color: neon.foreground)),
                                    const SizedBox(width: 12),
                                    Text(p.$2, style: mono.copyWith(color: neon.foreground, fontWeight: FontWeight.w700)),
                                    const Spacer(),
                                    Text('${row.glyph} ${row.label}', style: mono.copyWith(color: neon.of(row.state).withValues(alpha: 1))),
                                  ]),
                                  const SizedBox(height: 10),
                                  Text('\$ harness run --lane ${p.$3 ?? '-'}\n> reading src/lib/attention.ts\n> 42 files, 3 changed', style: mono),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 4,
              child: ListenableBuilder(
                listenable: _attention,
                builder: (context, _) => DecoratedBox(
                  decoration: BoxDecoration(border: Border.all(color: neon.accent.withValues(alpha: 0.4))),
                  child: FleetGraph(machines: _fleet(), hubLabel: 'this window'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Memory implements LocalKeyValueStore {
  final _data = <String, String>{};
  @override
  Future<String?> read(String key) async => _data[key];
  @override
  Future<void> write(String key, String value) async => _data[key] = value;
  @override
  Future<void> delete(String key) async => _data.remove(key);
}
