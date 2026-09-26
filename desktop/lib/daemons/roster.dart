/// Daemons: the roster as Dart values, read once from the generated copy of
/// `daemons/roster.json` (see `daemons/README.md`, the contract).
library;

import 'dart:convert';
import 'dart:ui' show Color;

import 'roster.g.dart';

/// The eight moods, in the roster's order. Names match the roster's keys.
enum DaemonMood { idle, work, need, done, fail, back, nap, boop }

DaemonMood? daemonMoodNamed(String? name) =>
    DaemonMood.values.where((m) => m.name == name).firstOrNull;

class DaemonPart {
  const DaemonPart({required this.rest, required this.work, required this.ms});
  final String rest;
  final List<String> work;
  final int ms;
}

class DaemonHabit {
  const DaemonHabit(this.key, this.label);
  final String key, label;
}

class DaemonEggKind {
  const DaemonEggKind({
    required this.kind,
    required this.look,
    required this.weights,
    this.boost = const {},
  });
  final String kind, look;
  final Map<String, num> weights;
  final Map<String, num> boost;
}

class DaemonRules {
  DaemonRules._(Map raw)
    : moods = [for (final m in raw['moods'] as List) m as String],
      eyes = Map<String, String>.from(raw['eyes'] as Map),
      blinks = {
        for (final e in (raw['blinks'] as Map).entries)
          e.key as String: [
            for (final step in e.value as List)
              ((step as List)[0] as String, (step[1] as num).toInt()),
          ],
      },
      noBlinkMoods = [for (final m in raw['noBlinkMoods'] as List) m as String],
      holdMs = {
        for (final e in (raw['holdMs'] as Map).entries)
          e.key as String: (e.value as num).toInt(),
      },
      backFrameMs = (raw['backFrameMs'] as num).toInt(),
      versions = [for (final v in raw['versions'] as List) v as String],
      bondForVersion = {
        for (final e in (raw['bondForVersion'] as Map).entries)
          e.key as String: (e.value as num).toInt(),
      },
      xpPerTurn = ((raw['bond'] as Map?)?['xpPerTurn'] as num? ?? 1).toInt(),
      xpPerDay = ((raw['bond'] as Map?)?['xpPerDay'] as num? ?? 5).toInt(),
      bondLevels = [
        for (final l in (raw['bond'] as Map?)?['levels'] as List? ?? const [0])
          (l as num).toInt(),
      ],
      earn = DaemonEarn._(raw['earn'] as Map? ?? const {}),
      historyDates = {
        for (final e in (raw['historyDates'] as Map? ?? const {}).entries)
          e.key as String: e.value as String?,
      },
      statusCells = (raw['statusCells'] as num).toInt(),
      portraitMaxCols = (raw['portraitMaxCols'] as num).toInt(),
      portraitMaxRows = (raw['portraitMaxRows'] as num).toInt(),
      rarities = [for (final r in raw['rarities'] as List) r as String],
      shinyOneIn = (raw['shinyOneIn'] as num).toInt(),
      pityPerMiss = raw['pityPerMiss'] as num,
      firstEggNeed = ((raw['firstEgg'] as Map)['need'] as num).toInt(),
      habits = [
        for (final h in (raw['firstEgg'] as Map)['habits'] as List)
          DaemonHabit((h as Map)['key'] as String, h['label'] as String),
      ],
      eggs = {
        for (final e in (raw['eggs'] as Map).entries)
          e.key as String: DaemonEggKind(
            kind: e.key as String,
            look: (e.value as Map)['look'] as String,
            weights: Map<String, num>.from(e.value['weights'] as Map),
            boost: Map<String, num>.from(e.value['boost'] as Map? ?? const {}),
          ),
      },
      easterWords = [for (final w in raw['easterWords'] as List) w as String],
      nest = [for (final n in raw['nest'] as List) n as String],
      egg = [for (final n in raw['egg'] as List) n as String];

  final List<String> moods;
  final Map<String, String> eyes;
  final Map<String, List<(String, int)>> blinks;
  final List<String> noBlinkMoods;
  final Map<String, int> holdMs;
  final int backFrameMs;
  final List<String> versions;
  final Map<String, int> bondForVersion;

  /// Bond (README, "Earning eggs and growing"): xp per counted turn, per
  /// first counted turn of a day, and the xp each level starts at.
  final int xpPerTurn, xpPerDay;
  final List<int> bondLevels;
  final DaemonEarn earn;

  /// `MM-DD` → the daemon that date's history egg gives, or null.
  final Map<String, String?> historyDates;
  final int statusCells, portraitMaxCols, portraitMaxRows;
  final List<String> rarities;
  final int shinyOneIn;
  final num pityPerMiss;
  final int firstEggNeed;
  final List<DaemonHabit> habits;
  final Map<String, DaemonEggKind> eggs;
  final List<String> easterWords;
  final List<String> nest;
  final List<String> egg;

  Duration hold(DaemonMood mood) =>
      Duration(milliseconds: holdMs[mood.name] ?? 0);
}

/// How work earns eggs (`rules.earn`).
class DaemonEarn {
  DaemonEarn._(Map raw)
    : turnEvery = _int(raw, 'turn', 'every', 40),
      dailyCap = _int(raw, 'turn', 'dailyCap', 20),
      weekDays = _int(raw, 'week', 'days', 3),
      marathonTurns = _int(raw, 'marathon', 'turns', 500),
      marathonMachines = _int(raw, 'marathon', 'machines', 2),
      nights = _int(raw, 'night', 'nights', 3),
      nightFrom = _int(raw, 'night', 'fromHour', 0),
      nightTo = _int(raw, 'night', 'toHour', 4);

  static int _int(Map raw, String group, String key, int fallback) =>
      ((raw[group] as Map?)?[key] as num?)?.toInt() ?? fallback;

  final int turnEvery, dailyCap, weekDays, marathonTurns, marathonMachines;
  final int nights, nightFrom, nightTo;
}

class DaemonDrop {
  const DaemonDrop(this.id, this.n, this.name);
  final String id;
  final int n;
  final String name;
}

class DaemonDef {
  DaemonDef._(Map raw)
    : id = raw['id'] as String,
      n = (raw['n'] as num).toInt(),
      drop = raw['drop'] as String,
      rarity = raw['rarity'] as String,
      xterm = ((raw['color'] as Map)['xterm'] as num).toInt(),
      hex = (raw['color'] as Map)['hex'] as String,
      family = [
        for (final f in raw['family'] as List)
          ((f as List)[0] as String, (f[1] as num?)?.toInt()),
      ],
      lore = raw['lore'] as String,
      first = raw['first'] as String,
      lines = Map<String, String>.from(raw['lines'] as Map),
      suggest = Map<String, String>.from(raw['suggest'] as Map? ?? const {}),
      eyes = raw['eyes'] == null
          ? null
          : Map<String, String>.from(raw['eyes'] as Map),
      lid = raw['lid'] as String?,
      darkOnly = raw['darkOnly'] == true,
      sprites = Map<String, String>.from(raw['sprites'] as Map),
      work = [for (final w in raw['work'] as List) w as String],
      workMs = (raw['workMs'] as num).toInt(),
      portraits = {
        for (final e in (raw['portraits'] as Map).entries)
          e.key as String: [for (final l in e.value as List) l as String],
      },
      parts = {
        for (final e in (raw['parts'] as Map? ?? const {}).entries)
          e.key as String: DaemonPart(
            rest: (e.value as Map)['rest'] as String,
            work: [for (final w in e.value['work'] as List) w as String],
            ms: (e.value['ms'] as num).toInt(),
          ),
      },
      moodParts = {
        for (final e in (raw['moodParts'] as Map? ?? const {}).entries)
          e.key as String: Map<String, String>.from(e.value as Map),
      },
      turn = raw['turn'] as String? ?? '';

  final String id;
  final int n;
  final String drop, rarity;
  final int xterm;
  final String hex;
  final List<(String, int?)> family;
  final String lore, first;
  final Map<String, String> lines, suggest;
  final Map<String, String>? eyes;
  final String? lid;
  final bool darkOnly;
  final Map<String, String> sprites;
  final List<String> work;
  final int workMs;
  final Map<String, List<String>> portraits;
  final Map<String, DaemonPart> parts;
  final Map<String, Map<String, String>> moodParts;
  final String turn;

  bool get secret => rarity == 'secret';
  Color get color => Color(0xff000000 | int.parse(hex.substring(1), radix: 16));
  String line(DaemonMood mood) => lines[mood.name] ?? '';

  /// `screen -> tmux -> tim`
  String get familyLine => family.map((f) => f.$1).join(' -> ');

  /// `1987 -> 2007 -> 2026`, only the years that are known.
  String get familyYears =>
      family.map((f) => f.$2).whereType<int>().join(' -> ');
}

class DaemonRoster {
  DaemonRoster._(Map raw)
    : version = (raw['version'] as num).toInt(),
      rules = DaemonRules._(raw['rules'] as Map),
      drops = [
        for (final d in raw['drops'] as List)
          DaemonDrop(
            (d as Map)['id'] as String,
            (d['n'] as num).toInt(),
            d['name'] as String,
          ),
      ],
      daemons = [for (final d in raw['daemons'] as List) DaemonDef._(d as Map)];

  factory DaemonRoster.parse(String json) =>
      DaemonRoster._(jsonDecode(json) as Map);

  final int version;
  final DaemonRules rules;
  final List<DaemonDrop> drops;
  final List<DaemonDef> daemons;
  late final Map<String, DaemonDef> _byId = {for (final d in daemons) d.id: d};

  DaemonDef? byId(String? id) => id == null ? null : _byId[id];
  DaemonDrop? drop(String id) => drops.where((d) => d.id == id).firstOrNull;
  int dropSize(String id) => daemons.where((d) => d.drop == id).length;

  /// 0, 1 or 2 for `0.1`, `1.0`, `2.0`; unknown versions draw as the first.
  int versionIndex(String? version) {
    final at = rules.versions.indexOf(version ?? '');
    return at < 0 ? 0 : at;
  }
}

/// The roster every surface draws from.
final daemonRoster = DaemonRoster.parse(daemonRosterJson);
