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
      // A status cell is always exactly the eight cells plus both gutters (a
      // six-cell 1.0 sprite with a borrowed baton runs into the right one).
      expect(
        statusCell(
          roster,
          out,
          baseWidth(roster, d, roster.versionIndex(f['v'] as String)),
        ).length,
        roster.rules.statusCells + 2,
      );
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

  test('every status cell matches the reference: centred on the base '
      'sprite', () {
    final cells = frames['cells'] as List;
    expect(cells, hasLength(greaterThan(400)));
    for (final raw in cells) {
      final f = raw as Map;
      final d = roster.byId(f['id'] as String)!;
      final vi = roster.versionIndex(f['v'] as String);
      final sprite = renderSprite(
        roster,
        d,
        vi,
        daemonMoodNamed(f['mood'] as String)!,
        t: f['t'] as int,
      );
      expect(
        statusCell(roster, sprite, baseWidth(roster, d, vi)),
        f['out'],
        reason: '${f['id']} ${f['v']} ${f['mood']} t=${f['t']}',
      );
      expect((f['out'] as String).length, roster.rules.statusCells + 2);
    }
    // The widest case: a six-cell sprite centred one cell in, plus a baton,
    // ends on the right gutter (the old port padded it to eleven).
    expect(
      statusCell(roster, '[=|==] |', 6),
      ' ' * 2 + '[=|==] |',
      reason: 'ten cells, the baton in the right gutter',
    );
    // A borrowed baton or a nap's z grows to the right: the face stays put.
    final tim = roster.byId('tim')!;
    final idle = statusCell(roster, '[oo]', baseWidth(roster, tim, 0));
    final working = statusCell(roster, '[==] |', baseWidth(roster, tim, 0));
    expect(idle.indexOf('['), working.indexOf('['));
    // Without a base width it centres the sprite as drawn.
    expect(statusCell(roster, '[oo]'), '   [oo]   ');
    expect(statusCell(roster, ';:(oo):;'), ' ;:(oo):; ');
  });

  test('every card matches card.mjs', () {
    final cards = frames['cards'] as List;
    expect(cards, hasLength(roster.daemons.length * 6));
    for (final raw in cards) {
      final f = raw as Map;
      final d = roster.byId(f['id'] as String)!;
      final out = cardLines(
        roster,
        d,
        version: f['version'] as String,
        shiny: f['shiny'] == true,
        serial: f['serial'] as int?,
        nickname: f['nickname'] as String?,
        hatched: f['hatched'] as String?,
        egg: f['egg'] as String?,
      );
      expect(out, [
        for (final l in f['out'] as List) l as String,
      ], reason: '${f['id']} ${f['version']} shiny=${f['shiny']}');
      expect(out.every((l) => l.length == cardWidth), isTrue);
    }
    // Secrets sit outside the numbered set.
    expect(cardNumber(roster, roster.byId('tim')!), '#01/09');
    expect(cardNumber(roster, roster.byId('tldr')!), '#09/09');
    expect(cardNumber(roster, roster.byId('grue')!), '#S/09');
    expect(
      rarityStamp(roster, roster.byId('vim')!, shiny: true),
      '[ SHINY RARE ]  #05/09',
    );
    // The zoo's card reads its date from hatchedAt and its egg kind.
    final zooCard = zooCardLines(
      roster,
      roster.byId('tim')!,
      version: '1.0',
      nickname: 'pip',
      hatchedAt: '2026-09-26T09:42:00Z',
      egg: 'week',
    );
    expect(zooCard, contains('|   pip the tim 1.0                      |'));
    expect(zooCard, contains('|   hatched 2026-09-26, week egg         |'));
    expect(cardCodeBlock(zooCard), startsWith('```\n.---'));
  });

  test('every nest matches render.mjs nestStage', () {
    final nests = frames['nests'] as List;
    expect(nests, isNotEmpty);
    for (final raw in nests) {
      final f = raw as Map;
      final habits = [for (final h in f['habits'] as List) h as String];
      expect(nestStage(roster, habits), f['stage'], reason: '$habits');
      expect(nestFor(roster, habits), f['out'], reason: '$habits');
    }
  });

  test('every banner matches renderBanner in the shared face', () {
    final banners = frames['banners'] as List;
    expect(banners, hasLength(roster.daemons.length));
    for (final raw in banners) {
      final f = raw as Map;
      expect(renderBanner(daemonBanner, f['id'] as String), [
        for (final l in f['out'] as List) l as String,
      ], reason: f['id'] as String);
      expect(bannerRows(f['id'] as String), f['out']);
    }
    // Every row fits the reveal's 42 columns at its own size.
    for (final d in roster.daemons) {
      expect(bannerRows(d.id).every((r) => r.length <= 42), isTrue);
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
