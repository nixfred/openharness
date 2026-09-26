// The Dart renderer against the reference renderer's pinned frames
// (daemons/frames.json, written by daemons/tools/generate.mjs). Every frame,
// byte for byte, so the status line, the panel and the card draw exactly what
// hn and the lookbook draw.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness/daemons/render.dart';
import 'package:harness/daemons/roster.dart';

void main() {
  final frames =
      jsonDecode(File('../daemons/frames.json').readAsStringSync()) as Map;
  final roster = daemonRoster;

  test('the generated roster parses and matches roster.json', () {
    final source =
        jsonDecode(File('../daemons/roster.json').readAsStringSync()) as Map;
    expect(roster.daemons.map((d) => d.id), [
      for (final d in source['daemons'] as List) (d as Map)['id'],
    ]);
    expect(roster.rules.statusCells, 8);
    expect(roster.rules.habits.map((h) => h.key), [
      'turn',
      'split',
      'find',
      'elsewhere',
      'machine',
      'store',
      'resume',
      'days',
    ]);
  });

  test('every sprite frame matches the reference renderer', () {
    final sprites = frames['sprites'] as List;
    expect(sprites, hasLength(greaterThan(900)));
    var checked = 0;
    for (final raw in sprites) {
      final f = raw as Map;
      final d = roster.byId(f['id'] as String)!;
      final out = renderSprite(
        roster,
        d,
        roster.versionIndex(f['v'] as String),
        daemonMoodNamed(f['mood'] as String)!,
        t: f['t'] as int,
        lid: f['lid'] as String?,
      );
      expect(
        out,
        f['out'],
        reason: '${f['id']} ${f['v']} ${f['mood']} t=${f['t']} lid=${f['lid']}',
      );
      // The status cell is always the eight cells plus both gutters.
      expect(statusCell(roster, out).length, roster.rules.statusCells + 2);
      checked++;
    }
    expect(checked, sprites.length);
  });

  test('every portrait frame matches the reference renderer', () {
    final portraits = frames['portraits'] as List;
    expect(portraits, hasLength(greaterThan(400)));
    for (final raw in portraits) {
      final f = raw as Map;
      final d = roster.byId(f['id'] as String)!;
      final out = renderPortrait(
        roster,
        d,
        f['v'] as String,
        daemonMoodNamed(f['mood'] as String)!,
        t: f['t'] as int,
      );
      expect(out, [
        for (final l in f['out'] as List) l as String,
      ], reason: '${f['id']} ${f['v']} ${f['mood']} t=${f['t']}');
    }
  });

  test('status cell centres the sprite with one cell of gutter', () {
    expect(statusCell(roster, '[oo]'), '   [oo]   ');
    // Odd widths lean left, as render.mjs rounds.
    expect(statusCell(roster, r'\[o|o]/'), r' \[o|o]/  ');
    expect(statusCell(roster, '><(((o>'), ' ><(((o>  ');
    expect(statusCell(roster, ';:(oo):;'), ' ;:(oo):; ');
  });

  test('nest stages follow habits done', () {
    expect(
      [for (var h = 0; h <= 6; h++) nestFor(roster, h)],
      [
        r'\_O_/',
        r'\_O_/',
        r'~\_O_/~',
        r'~\_O_/~',
        r'\_.._/',
        r'\_o.o_/',
        r'\_o.o_/',
      ],
    );
  });

  test('the card matches the README', () {
    final card = daemonCard(
      roster,
      roster.byId('tim')!,
      shiny: false,
      eggKind: 'first',
      hatchedAt: DateTime.utc(2026, 9, 26, 9, 42),
    );
    expect(
      card,
      r'''
.----------------------------------------.
| #01/10  DROP 1: UNIX            COMMON |
|                                        |
|  [oo]    tim 0.1                       |
|  screen -> tmux -> tim                 |
|                                        |
|  "oh hi. i'm tim. tmux, improved.      |
|  what are we building?"                |
|                                        |
|  hatched 2026-09-26, first egg         |
'----------------------------------------'
'''
          .trim(),
    );
    for (final d in roster.daemons) {
      final lines = daemonCard(
        roster,
        d,
        shiny: true,
        eggKind: 'easter',
        hatchedAt: DateTime.utc(2026),
      ).split('\n');
      expect(lines.every((l) => l.length == 42), isTrue, reason: d.id);
      expect(lines.every((l) => RegExp(r'^[\x20-\x7e]*$').hasMatch(l)), isTrue);
    }
  });

  test('banner draws every drop 1 name with the lookbook face', () {
    expect(bannerRows('tim'), ['_|_ .  _ _ ', ' |_ | | | |']);
    for (final d in roster.daemons) {
      final rows = bannerRows(d.id);
      expect(rows, isNotEmpty);
      expect(rows.join().contains('?'), isFalse, reason: d.id);
    }
    expect(silhouette('[oo]'), '####');
    expect(silhouette('o   o'), '#   #');
  });

  test('egg frames keep their width while they wobble and crack', () {
    for (final frame in [
      eggFrame(roster),
      eggFrame(roster, offset: -1),
      eggFrame(roster, offset: 1, crack: 1),
      eggFrame(roster, crack: 2),
      eggPopFrame(roster),
    ]) {
      final rows = frame.split('\n');
      expect(rows.every((r) => r.length == 18), isTrue, reason: frame);
    }
  });
}
