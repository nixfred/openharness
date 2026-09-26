/// The zoo: your daemons and eggs, account state the same on every client
/// (`daemons/README.md`, "The zoo"). The server is the authority for an
/// account; this file is the wire shape and the same rules, applied on the
/// client only for a guest's local zoo (and a daemon that predates the zoo).
library;

import 'dart:math';

import 'roster.dart';

final _printable = RegExp(r'^[\x20-\x7e]*$');

/// A nickname: 1–24 printable ASCII characters.
bool validNickname(String? value) =>
    value != null &&
    value.trim().isNotEmpty &&
    value.trim().length <= 24 &&
    _printable.hasMatch(value);

class ZooDaemon {
  const ZooDaemon({
    required this.id,
    required this.hatchedAt,
    required this.egg,
    this.shiny = false,
    this.nickname,
    this.bond = 0,
    this.version = '0.1',
  });
  final String id;
  final String hatchedAt;
  final String egg;
  final bool shiny;
  final String? nickname;
  final int bond;
  final String version;

  DateTime get hatchedDate =>
      DateTime.tryParse(hatchedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);

  ZooDaemon copyWith({String? nickname, bool clearNickname = false}) =>
      ZooDaemon(
        id: id,
        hatchedAt: hatchedAt,
        egg: egg,
        shiny: shiny,
        nickname: clearNickname ? null : nickname ?? this.nickname,
        bond: bond,
        version: version,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'hatchedAt': hatchedAt,
    'egg': egg,
    'shiny': shiny,
    if (nickname != null) 'nickname': nickname,
    'bond': bond,
    'version': version,
  };

  static ZooDaemon? fromJson(Object? raw, DaemonRoster roster) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || roster.byId(id) == null) return null;
    final nickname = raw['nickname'];
    final version = raw['version'];
    return ZooDaemon(
      id: id,
      hatchedAt: raw['hatchedAt'] is String ? raw['hatchedAt'] as String : '',
      egg: raw['egg'] is String ? raw['egg'] as String : 'first',
      shiny: raw['shiny'] == true,
      nickname: validNickname(nickname as String?) ? nickname!.trim() : null,
      bond: raw['bond'] is int ? raw['bond'] as int : 0,
      version: roster.rules.versions.contains(version)
          ? version as String
          : roster.rules.versions.first,
    );
  }
}

class ZooEgg {
  const ZooEgg({required this.id, required this.kind, required this.grantedAt});
  final String id, kind, grantedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'grantedAt': grantedAt,
  };

  static ZooEgg? fromJson(Object? raw, DaemonRoster roster) {
    if (raw is! Map) return null;
    final id = raw['id'], kind = raw['kind'];
    if (id is! String || id.isEmpty || kind is! String) return null;
    if (!roster.rules.eggs.containsKey(kind)) return null;
    return ZooEgg(
      id: id,
      kind: kind,
      grantedAt: raw['grantedAt'] is String ? raw['grantedAt'] as String : '',
    );
  }
}

class Zoo {
  const Zoo({
    this.daemons = const [],
    this.eggs = const [],
    this.pair,
    this.habits = const [],
    this.firstEgg = false,
    this.pity = 0,
    this.easter = const [],
  });
  static const empty = Zoo();
  static const maxEggs = 12, maxDaemons = 64;

  final List<ZooDaemon> daemons;
  final List<ZooEgg> eggs;
  final String? pair;
  final List<String> habits;
  final bool firstEgg;
  final int pity;
  final List<String> easter;

  bool get isEmpty =>
      daemons.isEmpty &&
      eggs.isEmpty &&
      habits.isEmpty &&
      !firstEgg &&
      pity == 0 &&
      easter.isEmpty;
  bool owns(String id) => daemons.any((d) => d.id == id);

  /// The daemon in the status line: the pair, else (defensively) the first.
  ZooDaemon? get paired =>
      daemons.where((d) => d.id == pair).firstOrNull ?? daemons.firstOrNull;

  Zoo copyWith({
    List<ZooDaemon>? daemons,
    List<ZooEgg>? eggs,
    String? pair,
    List<String>? habits,
    bool? firstEgg,
    int? pity,
    List<String>? easter,
  }) => Zoo(
    daemons: daemons ?? this.daemons,
    eggs: eggs ?? this.eggs,
    pair: pair ?? this.pair,
    habits: habits ?? this.habits,
    firstEgg: firstEgg ?? this.firstEgg,
    pity: pity ?? this.pity,
    easter: easter ?? this.easter,
  );

  Map<String, dynamic> toJson() => {
    'daemons': [for (final d in daemons) d.toJson()],
    'eggs': [for (final e in eggs) e.toJson()],
    'pair': pair,
    'habits': habits,
    'firstEgg': firstEgg,
    'pity': pity,
    'easter': easter,
  };

  /// Anything unknown to this roster is dropped, never an error.
  static Zoo fromJson(Object? raw, DaemonRoster roster) {
    if (raw is! Map) return empty;
    final daemons = [
      for (final d in raw['daemons'] as List? ?? const [])
        ?ZooDaemon.fromJson(d, roster),
    ];
    final eggs = [
      for (final e in raw['eggs'] as List? ?? const [])
        ?ZooEgg.fromJson(e, roster),
    ];
    final habitKeys = roster.rules.habits.map((h) => h.key).toSet();
    final pair = raw['pair'];
    return Zoo(
      daemons: daemons,
      eggs: eggs,
      pair: pair is String && daemons.any((d) => d.id == pair) ? pair : null,
      habits: <String>{
        for (final h in raw['habits'] as List? ?? const [])
          if (h is String && habitKeys.contains(h)) h,
      }.toList(),
      firstEgg: raw['firstEgg'] == true,
      pity: raw['pity'] is int ? raw['pity'] as int : 0,
      easter: [
        for (final w in raw['easter'] as List? ?? const [])
          if (w is String) w,
      ],
    );
  }
}

class ZooHatch {
  const ZooHatch({
    required this.eggId,
    required this.daemonId,
    required this.shiny,
  });
  final String eggId, daemonId;
  final bool shiny;

  static ZooHatch? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final eggId = raw['eggId'], daemonId = raw['daemonId'];
    if (eggId is! String || daemonId is! String) return null;
    return ZooHatch(
      eggId: eggId,
      daemonId: daemonId,
      shiny: raw['shiny'] == true,
    );
  }
}

/// The draw (`zoo.hatch`): the README's rules, for a guest's local zoo only.
/// An account's draw happens on the server; clients never send a result.
String? drawDaemon(
  DaemonRoster roster,
  Zoo zoo,
  DaemonEggKind egg,
  Random random,
) {
  final drops = roster.drops.map((d) => d.id).toSet();
  final released = roster.daemons.where((d) => drops.contains(d.drop)).toList();
  var eligible = released.where((d) => !zoo.owns(d.id)).toList();
  // When you own them all, duplicates are allowed again.
  if (eligible.isEmpty) eligible = released;
  List<(DaemonDef, double)> weigh(List<DaemonDef> pool) {
    final perRarity = <String, int>{};
    for (final d in pool) {
      perRarity[d.rarity] = (perRarity[d.rarity] ?? 0) + 1;
    }
    return [
      for (final d in pool)
        (
          d,
          ((egg.weights[d.rarity] ?? 0) / perRarity[d.rarity]! +
                  (d.secret ? zoo.pity * roster.rules.pityPerMiss : 0)) *
              (egg.boost[d.id] ?? 1),
        ),
    ];
  }

  var weighted = weigh(eligible);
  if (weighted.every((w) => w.$2 <= 0)) weighted = weigh(released);
  final total = weighted.fold<double>(0, (sum, w) => sum + max(0, w.$2));
  if (total <= 0) {
    return eligible.isEmpty
        ? null
        : eligible[random.nextInt(eligible.length)].id;
  }
  var x = random.nextDouble() * total;
  for (final (d, w) in weighted) {
    if (w <= 0) continue;
    x -= w;
    if (x < 0) return d.id;
  }
  return weighted.lastWhere((w) => w.$2 > 0).$1.id;
}

class ZooOpsResult {
  const ZooOpsResult(this.zoo, this.hatched);
  final Zoo zoo;
  final List<ZooHatch> hatched;
}

/// Apply ops in order with the server's rules. Every op is idempotent; an op
/// on something missing is dropped, never an error.
ZooOpsResult applyZooOps(
  DaemonRoster roster,
  Zoo zoo,
  List<Map<String, dynamic>> ops, {
  required Random random,
  required DateTime now,
}) {
  var next = zoo;
  final hatched = <ZooHatch>[];
  final stamp = now.toUtc().toIso8601String();
  String eggId() =>
      List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
  Zoo grant(Zoo z, String kind) => z.eggs.length >= Zoo.maxEggs
      ? z
      : z.copyWith(
          eggs: [
            ...z.eggs,
            ZooEgg(id: eggId(), kind: kind, grantedAt: stamp),
          ],
        );
  for (final op in ops) {
    switch (op['op']) {
      case 'zoo.habit':
        final key = op['key'];
        if (key is! String ||
            !roster.rules.habits.any((h) => h.key == key) ||
            next.habits.contains(key)) {
          break;
        }
        next = next.copyWith(habits: [...next.habits, key]);
        if (next.habits.length >= roster.rules.firstEggNeed && !next.firstEgg) {
          next = grant(next.copyWith(firstEgg: true), 'first');
        }
      case 'zoo.hatch':
        final egg = next.eggs.where((e) => e.id == op['eggId']).firstOrNull;
        final kind = egg == null ? null : roster.rules.eggs[egg.kind];
        if (egg == null ||
            kind == null ||
            next.daemons.length >= Zoo.maxDaemons) {
          break;
        }
        final id = drawDaemon(roster, next, kind, random);
        if (id == null) break;
        final shiny = random.nextInt(roster.rules.shinyOneIn) == 0;
        final secret = roster.byId(id)!.secret;
        next = next.copyWith(
          daemons: [
            ...next.daemons,
            ZooDaemon(
              id: id,
              hatchedAt: stamp,
              egg: egg.kind,
              shiny: shiny,
              version: roster.rules.versions.first,
            ),
          ],
          eggs: [...next.eggs.where((e) => e.id != egg.id)],
          pair: next.pair ?? id,
          pity: secret ? 0 : next.pity + 1,
        );
        hatched.add(ZooHatch(eggId: egg.id, daemonId: id, shiny: shiny));
      case 'zoo.pair':
        final id = op['id'];
        if (id is String && next.owns(id)) next = next.copyWith(pair: id);
      case 'zoo.nickname':
        final id = op['id'], nickname = op['nickname'];
        final at = next.daemons.indexWhere((d) => d.id == id);
        if (at < 0 ||
            (nickname != null && !validNickname(nickname as String?))) {
          break;
        }
        final daemons = [...next.daemons];
        daemons[at] = nickname == null
            ? daemons[at].copyWith(clearNickname: true)
            : daemons[at].copyWith(nickname: (nickname as String).trim());
        next = next.copyWith(daemons: daemons);
      case 'zoo.easter':
        final word = op['word'];
        if (word is! String ||
            !roster.rules.easterWords.contains(word) ||
            next.easter.contains(word)) {
          break;
        }
        next = grant(next.copyWith(easter: [...next.easter, word]), 'easter');
      case 'zoo.seed':
        if (next.isEmpty) next = Zoo.fromJson(op['zoo'], roster);
    }
  }
  return ZooOpsResult(next, hatched);
}
