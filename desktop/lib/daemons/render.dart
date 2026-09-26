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

/// The status cell: the sprite centred in statusCells, with one cell of gutter
/// each side.
String statusCell(DaemonRoster roster, String sprite) {
  final pad = roster.rules.statusCells - sprite.length;
  final left = (pad / 2).floor(), right = (pad / 2).ceil();
  return ' ${' ' * (left < 0 ? 0 : left)}$sprite${' ' * (right < 0 ? 0 : right)} ';
}

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

/// The top pops off.
String eggPopFrame(DaemonRoster roster) => [
  "    '  .--.  .    ",
  r'      /\/\/\      ',
  "         '        ",
  r'     |\/\/\/|     ',
  '     |      |     ',
  r'      \    /      ',
  _eggRows(roster).last,
].join('\n');

// ── the banner: a small FIGlet-style face, ported from the lookbook ──────────

const _banner = <String, List<String>>{
  'a': ['   ', ' _.', '(_|', '   '],
  'b': ['|  ', '|_ ', '|_)', '   '],
  'c': ['  ', ' _', '(_', '  '],
  'd': ['  |', ' _|', '(_|', '   '],
  'e': ['   ', ' _ ', '(/_', '   '],
  'f': ['  _', '_|_', ' | ', '   '],
  'g': ['   ', ' _ ', '(_|', ' _|'],
  'h': ['|  ', '|_ ', '| |', '   '],
  'i': [' ', '.', '|', ' '],
  'l': ['|', '|', '|', ' '],
  'm': ['     ', ' _ _ ', '| | |', '     '],
  'n': ['   ', ' _ ', '| |', '   '],
  'p': ['   ', ' _ ', '|_)', '|  '],
  'r': ['  ', ' _', '| ', '  '],
  's': ['  ', ' _', '_>', '  '],
  't': ['   ', '_|_', ' |_', '   '],
  'u': ['   ', '   ', '|_|', '   '],
  'v': ['  ', '  ', r'\/', '  '],
  'x': ['  ', '  ', '><', '  '],
  'z': ['  ', '_ ', '/_', '  '],
};

/// A name as the banner draws it, blank rows dropped. Letters the face does
/// not have draw as `?`.
List<String> bannerRows(String word) => [
  for (var row = 0; row < 4; row++)
    [
      for (final ch in word.split(''))
        (_banner[ch] ?? const ['?', '?', '?', '?'])[row],
    ].join(' '),
].where((line) => line.trim().isNotEmpty).toList();

// ── the card ─────────────────────────────────────────────────────────────────

/// Words wrapped the way the lookbook wraps them.
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

/// The hatch card, 42 columns, as it copies into Slack or GitHub. Laid out as
/// the README's example (the contract), one cell further left than the
/// lookbook's draft.
String daemonCard(
  DaemonRoster roster,
  DaemonDef d, {
  required bool shiny,
  required String eggKind,
  required DateTime hatchedAt,
}) {
  const w = 42, inner = w - 4;
  String row(String s) {
    final padded = s.padRight(inner);
    return '| ${padded.substring(0, inner)} |';
  }

  final drop = roster.drop(d.drop);
  final head =
      '#${d.n.toString().padLeft(2, '0')}/${roster.dropSize(d.drop)}  '
      'DROP ${drop?.n ?? 1}: ${(drop?.name ?? d.drop).toUpperCase()}';
  final rarity = '${shiny ? 'SHINY ' : ''}${d.rarity.toUpperCase()}';
  final gap = inner - head.length - rarity.length;
  final date = hatchedAt.toIso8601String().substring(0, 10);
  return [
    '.${'-' * (w - 2)}.',
    row('$head${' ' * (gap < 1 ? 1 : gap)}$rarity'),
    row(''),
    row(' ${renderSprite(roster, d, 0, DaemonMood.idle)}    ${d.id} 0.1'),
    row(' ${d.familyLine}'),
    row(''),
    for (final line in wrapWords('"${d.first}"', inner - 2)) row(' $line'),
    row(''),
    row(' hatched $date, ${eggName(eggKind)}'),
    "'${'-' * (w - 2)}'",
  ].join('\n');
}

/// `[ SHINY RARE ]  #05/10`
String rarityStamp(DaemonRoster roster, DaemonDef d, {required bool shiny}) =>
    '[ ${shiny ? '* SHINY * ' : ''}${d.rarity.toUpperCase()} ]  '
    '#${d.n.toString().padLeft(2, '0')}/${roster.dropSize(d.drop)}';
