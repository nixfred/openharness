/// The Dart port of `daemons/tools/render.mjs`, the reference renderer. Every
/// frame it draws must match `daemons/frames.json` byte for byte
/// (`test/daemons/render_frames_test.dart` checks all of them).
///
/// Placeholders in sprites and portraits:
///   `{e}`          an eye: the mood's eye, or the lid while blinking (never in noBlinkMoods)
///   `{<part>}`     a moving part (d.parts): its `rest` glyph, or a frame of `work` every `ms` while working
///   `{<moodPart>}` a mood-driven part (d.moodParts): its value for the mood, else its idle value
///
/// The rest of this file draws what the lookbook draws around a daemon: the
/// nest, the egg while it hatches, the banner name and the copyable card.
library;

import 'dart:math';

import 'roster.dart';

final _placeholder = RegExp(r'\{([a-zA-Z]+)\}');

String eyeFor(DaemonRoster roster, DaemonDef d, DaemonMood mood) =>
    d.eyes?[mood.name] ?? roster.rules.eyes[mood.name] ?? 'o';

String _fill(
  String tpl,
  DaemonRoster roster,
  DaemonDef d,
  DaemonMood mood, {
  int t = 0,
  String? lid,
  bool motion = true,
}) {
  final blinking =
      lid != null &&
      lid.isNotEmpty &&
      !roster.rules.noBlinkMoods.contains(mood.name);
  final eye = blinking ? (d.lid ?? lid) : eyeFor(roster, d, mood);
  final moving = motion && mood == DaemonMood.work;
  return tpl.replaceAllMapped(_placeholder, (match) {
    final key = match[1]!;
    if (key == 'e') return eye;
    final moodPart = d.moodParts[key];
    if (moodPart != null) return moodPart[mood.name] ?? moodPart['idle']!;
    final part = d.parts[key];
    if (part != null) {
      return moving ? part.work[(t ~/ part.ms) % part.work.length] : part.rest;
    }
    return match[0]!;
  });
}

/// One line for the status bar. [versionIndex] is 0, 1 or 2 (0.1, 1.0, 2.0);
/// [t] is milliseconds.
String renderSprite(
  DaemonRoster roster,
  DaemonDef d,
  int versionIndex,
  DaemonMood mood, {
  int t = 0,
  String? lid,
  bool motion = true,
}) {
  final rules = roster.rules;
  final last = rules.versions.length - 1;
  final moving = motion && (mood == DaemonMood.work || mood == DaemonMood.back);
  var tpl = d.sprites[rules.versions[versionIndex]]!;
  if (moving && versionIndex == last) {
    final ms = mood == DaemonMood.back ? rules.backFrameMs : d.workMs;
    tpl = d.work[(t ~/ ms) % d.work.length];
  }
  var s = _fill(tpl, roster, d, mood, t: t, lid: lid, motion: false);
  // Younger versions have no moving part yet; they borrow the twirling baton.
  if (moving && versionIndex < last && s.length <= rules.statusCells - 2) {
    s += ' ${r'|/-\'[(t ~/ 130) % 4]}';
  }
  if (mood == DaemonMood.nap && s.length < rules.statusCells) s += 'z';
  return s;
}

/// The portrait for a version, falling back to the nearest one drawn.
List<String> portraitFor(DaemonRoster roster, DaemonDef d, String version) {
  final own = d.portraits[version];
  if (own != null) return own;
  final versions = roster.rules.versions;
  final drawn = versions.where(d.portraits.containsKey).toList();
  final at = versions.indexOf(version);
  final below = drawn.where((v) => versions.indexOf(v) <= at).toList();
  return d.portraits[below.isNotEmpty ? below.last : drawn.first]!;
}

List<String> renderPortrait(
  DaemonRoster roster,
  DaemonDef d,
  String version,
  DaemonMood mood, {
  int t = 0,
  String? lid,
  bool motion = true,
}) => [
  for (final line in portraitFor(roster, d, version))
    _fill(line, roster, d, mood, t: t, lid: lid, motion: motion),
];

/// The status cell: statusCells wide plus one cell of gutter each side. The
/// sprite is centred on its [baseWidth] (the version's sprite, before a
/// borrowed baton or a nap's `z` is added), so those additions grow to the
/// right and the face never shifts a cell.
String statusCell(DaemonRoster roster, String sprite, [int? baseWidth]) {
  final cells = roster.rules.statusCells;
  final base = baseWidth ?? sprite.length;
  final left = max(0, ((cells - min(base, cells)) / 2).floor());
  final right = max(0, cells - left - sprite.length);
  return ' ${' ' * left}$sprite${' ' * right} ';
}

/// The base width [statusCell] centres on: the version's sprite in its idle
/// mood.
int baseWidth(DaemonRoster roster, DaemonDef d, int versionIndex) =>
    renderSprite(roster, d, versionIndex, DaemonMood.idle, motion: false).length;

/// The hatchling before it has colour: every drawn cell becomes `#`.
String silhouette(String sprite) => sprite.replaceAll(RegExp(r'[^ ]'), '#');

/// The nest while the first egg incubates: 0–1, 2–3, 4 and 5 habits done.
String nestFor(DaemonRoster roster, int habitsDone) {
  final nest = roster.rules.nest;
  final need = roster.rules.firstEggNeed;
  if (habitsDone >= need) return nest[3];
  if (habitsDone >= need - 1) return nest[2];
  if (habitsDone >= 2) return nest[1];
  return nest[0];
}

// ── the egg, as the hatch reveal draws it ────────────────────────────────────

const _eggWidth = 18;

List<String> _eggRows(DaemonRoster roster) => [
  for (final row in roster.rules.egg) row.padRight(_eggWidth),
];

/// One frame of the egg: [offset] -1, 0 or 1 cell of wobble, [crack] 0–2.
String eggFrame(DaemonRoster roster, {int offset = 0, int crack = 0}) {
  final all = _eggRows(roster);
  final rows = all.sublist(0, all.length - 1);
  final nest = all.last;
  if (crack == 1) rows[2] = r'     | /\/  |     ';
  if (crack == 2) rows[2] = r'     |/\/\/\|     ';
  String shift(String r) => offset < 0
      ? '${r.substring(1)} '
      : offset > 0
      ? ' ${r.substring(0, r.length - 1)}'
      : r;
  return [' ' * _eggWidth, ...rows.map(shift), nest].join('\n');
}

/// Where a legendary's sparks fly around the pop: row, column and glyph.
const eggSparks = <(int, int, String)>[
  (0, 1, '*'),
  (0, 16, '*'),
  (1, 2, "'"),
  (1, 15, '.'),
  (2, 4, '.'),
  (2, 13, '*'),
  (3, 1, "'"),
  (3, 16, "'"),
  (4, 2, '*'),
  (4, 15, '.'),
];

/// The top pops off; a legendary's pop throws [eggSparks] around it.
String eggPopFrame(DaemonRoster roster, {bool sparks = false}) {
  final rows = [
    "    '  .--.  .    ",
    r'      /\/\/\      ',
    "         '        ",
    r'     |\/\/\/|     ',
    '     |      |     ',
    r'      \    /      ',
    _eggRows(roster).last,
  ];
  if (sparks) {
    for (final (row, col, glyph) in eggSparks) {
      final r = rows[row];
      rows[row] = '${r.substring(0, col)}$glyph${r.substring(col + 1)}';
    }
  }
  return rows.join('\n');
}

// ── the banner: a daemon's name in the face from daemons/banner.json ──────────

/// A daemon's name as a banner (render.mjs `renderBanner`): every glyph padded
/// to its own widest row, `gap` columns between letters, blank rows dropped.
/// A character the face does not have is drawn as its blank.
List<String> renderBanner(DaemonBanner banner, String word) {
  final blank = banner.glyphs[' '] ?? List.filled(banner.rows, '');
  final glyphs = [
    for (final ch in word.toLowerCase().split(''))
      if (banner.glyphs[ch] ?? blank case final g)
        [
          for (final r in g)
            r.padRight(g.fold(0, (w, row) => max(w, row.length))),
        ],
  ];
  return [
    for (var r = 0; r < banner.rows; r++)
      glyphs.map((g) => g[r]).join(' ' * banner.gap).trimRight(),
  ].where((line) => line.trim().isNotEmpty).toList();
}

/// A name as the reveal's banner draws it.
List<String> bannerRows(String word) => renderBanner(daemonBanner, word);

// ── the card (a port of `daemons/tools/card.mjs`) ───────────────────────────

const cardWidth = 42;
const _cardInner = cardWidth - 4;

/// `#03/09`, or `#S/09` for a secret: secrets sit outside the numbered set.
String cardNumber(DaemonRoster roster, DaemonDef d) {
  final set = [
    for (final x in roster.daemons)
      if (!x.secret && x.drop == d.drop) x,
  ];
  final of = set.length.toString().padLeft(2, '0');
  if (d.secret) return '#S/$of';
  return '#${(set.indexOf(d) + 1).toString().padLeft(2, '0')}/$of';
}

/// Words wrapped the way card.mjs wraps them.
List<String> wrapWords(String text, int width) {
  final out = <String>[];
  var line = '';
  for (final word in text.split(' ')) {
    if ('$line $word'.trim().length > width) {
      out.add(line.trim());
      line = word;
    } else {
      line += ' $word';
    }
  }
  if (line.trim().isNotEmpty) out.add(line.trim());
  return out;
}

String eggName(String kind) => '$kind egg';

/// The card as lines of printable ASCII, 42 columns wide: the portrait at its
/// version, the number (secrets `#S/09`), the rarity, the name with a nickname
/// and serial when there are any, the family, the first words and the hatched
/// line. Never a live mood: a card is a portrait, not a presence indicator.
List<String> cardLines(
  DaemonRoster roster,
  DaemonDef d, {
  String? version,
  bool shiny = false,
  int? serial,
  String? nickname,
  String? hatched,
  String? egg,
}) {
  final v = version ?? roster.rules.versions.first;
  final drop = roster.drop(d.drop);
  String row(String s) {
    final padded = s.padRight(_cardInner);
    return '| ${padded.substring(0, _cardInner)} |';
  }

  final head =
      '${cardNumber(roster, d)}  DROP ${drop?.n ?? 1}: '
      '${(drop?.name ?? d.drop).toUpperCase()}';
  final rarity = '${shiny ? 'SHINY ' : ''}${d.rarity.toUpperCase()}';
  final name =
      '${nickname != null && nickname.isNotEmpty ? '$nickname the ' : ''}'
      '${d.id} $v'
      '${serial != null ? '  #${serial.toString().padLeft(4, '0')}' : ''}';
  final portrait = renderPortrait(roster, d, v, DaemonMood.idle, motion: false);
  final width = portrait.fold(0, (w, l) => max(w, l.length));
  final pad = max(0, ((_cardInner - width) / 2).floor());
  final hasHatched = (hatched != null && hatched.isNotEmpty) ||
      (egg != null && egg.isNotEmpty);
  return [
    '.${'-' * (cardWidth - 2)}.',
    row('$head${' ' * max(1, _cardInner - head.length - rarity.length)}$rarity'),
    row(''),
    for (final l in portrait) row('${' ' * pad}$l'),
    row(''),
    row('  $name'),
    row('  ${d.familyLine}'),
    row(''),
    for (final l in wrapWords('"${d.first}"', _cardInner - 2)) row('  $l'),
    if (hasHatched) ...[
      row(''),
      row(
        '  hatched ${hatched ?? ''}'
                '${egg != null && egg.isNotEmpty ? ', ${eggName(egg)}' : ''}'
            .replaceFirst(RegExp(r'\s+,'), ','),
      ),
    ],
    "'${'-' * (cardWidth - 2)}'",
  ];
}

/// The card for a daemon in the zoo: at its version, with its nickname, the
/// day it hatched and the egg it came from.
List<String> zooCardLines(
  DaemonRoster roster,
  DaemonDef d, {
  required String version,
  bool shiny = false,
  String? nickname,
  String? hatchedAt,
  String? egg,
}) => cardLines(
  roster,
  d,
  version: version,
  shiny: shiny,
  nickname: nickname,
  hatched: hatchedAt == null || hatchedAt.length < 10
      ? null
      : hatchedAt.substring(0, 10),
  egg: egg,
);

/// A card as it copies: a fenced code block.
String cardCodeBlock(List<String> lines) => '```\n${lines.join('\n')}\n```';

/// `[ SHINY RARE ]  #05/09`
String rarityStamp(DaemonRoster roster, DaemonDef d, {required bool shiny}) =>
    '[ ${shiny ? 'SHINY ' : ''}${d.rarity.toUpperCase()} ]  '
    '${cardNumber(roster, d)}';
