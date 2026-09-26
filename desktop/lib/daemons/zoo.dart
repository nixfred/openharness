/// The zoo: your daemons and eggs, account state the same on every client
/// (`daemons/README.md`, "The zoo" and "Earning eggs and growing"). The server
/// is the authority for an account (`backend/src/lib/zoo.ts`); this file is the
/// wire shape and the same rules, applied on the client only for a guest's
/// local zoo (and a harnessd that predates the zoo).
library;

import 'dart:math';

import 'roster.dart';

final _printable = RegExp(r'^[\x20-\x7e]*$');
final _idSafe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _dayShape = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final _weekShape = RegExp(r'^\d{4}-W\d{2}$');

/// A nickname: 1–24 printable ASCII characters.
bool validNickname(String? value) =>
    value != null &&
    value.trim().isNotEmpty &&
    value.trim().length <= 24 &&
    _printable.hasMatch(value);

// ── days, weeks and levels ───────────────────────────────────────────────────

/// A local calendar day, `YYYY-MM-DD`, that exists, in years 2000–2999.
bool isLocalDay(String s) {
  final m = _dayShape.firstMatch(s);
  if (m == null) return false;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (y < 2000 || y > 2999) return false;
  final t = DateTime.utc(y, mo, d);
  return t.year == y && t.month == mo && t.day == d;
}

String localDayOf(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}-'
    '${at.month.toString().padLeft(2, '0')}-'
    '${at.day.toString().padLeft(2, '0')}';

int _dayNumber(String day) {
  final p = day.split('-').map(int.parse).toList();
  return DateTime.utc(p[0], p[1], p[2]).millisecondsSinceEpoch ~/ 86400000;
}

/// The ISO 8601 week of a calendar day, `YYYY-Www` (Monday start).
String isoWeek(String day) {
  final p = day.split('-').map(int.parse).toList();
  var t = DateTime.utc(p[0], p[1], p[2]);
  t = t.add(Duration(days: 4 - t.weekday)); // the Thursday of that week
  final year = t.year;
  final week = (t.difference(DateTime.utc(year)).inDays / 7).floor() + 1;
  return '$year-W${week.toString().padLeft(2, '0')}';
}

/// Bond level for [xp]: the highest threshold of `rules.bond.levels` reached.
int levelFor(DaemonRoster roster, int xp) {
  var level = 0;
  for (var i = 0; i < roster.rules.bondLevels.length; i++) {
    if (xp >= roster.rules.bondLevels[i]) level = i;
  }
  return level;
}

/// The version a bond level has grown into (`rules.bondForVersion`).
String versionFor(DaemonRoster roster, int level) {
  var version = roster.rules.versions.first;
  for (final v in roster.rules.versions) {
    if (level >= (roster.rules.bondForVersion[v] ?? 0)) version = v;
  }
  return version;
}

// ── shapes ───────────────────────────────────────────────────────────────────

class ZooDaemon {
  const ZooDaemon({
    required this.id,
    required this.hatchedAt,
    required this.egg,
    this.shiny = false,
    this.nickname,
    this.bond = 0,
    this.xp = 0,
    this.version = '0.1',
  });
  final String id;
  final String hatchedAt;
  final String egg;
  final bool shiny;
  final String? nickname;
  final int bond, xp;
  final String version;

  DateTime get hatchedDate =>
      DateTime.tryParse(hatchedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);

  ZooDaemon copyWith({
    String? nickname,
    bool clearNickname = false,
    int? xp,
    int? bond,
    String? version,
  }) => ZooDaemon(
    id: id,
    hatchedAt: hatchedAt,
    egg: egg,
    shiny: shiny,
    nickname: clearNickname ? null : nickname ?? this.nickname,
    bond: bond ?? this.bond,
    xp: xp ?? this.xp,
    version: version ?? this.version,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'hatchedAt': hatchedAt,
    'egg': egg,
    'shiny': shiny,
    if (nickname != null) 'nickname': nickname,
    'bond': bond,
    'xp': xp,
    'version': version,
  };

  /// Bond and version always follow xp; a daemon stored before xp reads the
  /// least xp its stored bond needs, so reading never lowers a level.
  static ZooDaemon? fromJson(Object? raw, DaemonRoster roster) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || roster.byId(id) == null) return null;
    final nickname = raw['nickname'];
    final levels = roster.rules.bondLevels;
    final storedBond = raw['bond'] is int ? raw['bond'] as int : 0;
    final xp = raw['xp'] is int && (raw['xp'] as int) >= 0
        ? raw['xp'] as int
        : levels[storedBond.clamp(0, levels.length - 1)];
    final bond = levelFor(roster, xp);
    return ZooDaemon(
      id: id,
      hatchedAt: raw['hatchedAt'] is String ? raw['hatchedAt'] as String : '',
      egg: raw['egg'] is String ? raw['egg'] as String : 'first',
      shiny: raw['shiny'] == true,
      nickname: validNickname(nickname as String?) ? nickname!.trim() : null,
      bond: bond,
      xp: xp,
      version: versionFor(roster, bond),
    );
  }
}

class ZooEgg {
  const ZooEgg({
    required this.id,
    required this.kind,
    required this.grantedAt,
    this.date,
  });
  final String id, kind, grantedAt;

  /// The local day a history egg was earned on.
  final String? date;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'grantedAt': grantedAt,
    'date': ?date,
  };

  static ZooEgg? fromJson(Object? raw, DaemonRoster roster) {
    if (raw is! Map) return null;
    final id = raw['id'], kind = raw['kind'], date = raw['date'];
    if (id is! String || id.isEmpty || kind is! String) return null;
    if (!roster.rules.eggs.containsKey(kind)) return null;
    return ZooEgg(
      id: id,
      kind: kind,
      grantedAt: raw['grantedAt'] is String ? raw['grantedAt'] as String : '',
      date: date is String && isLocalDay(date) ? date : null,
    );
  }
}

/// What counts toward the eggs earned from work. The server writes it for an
/// account; a guest's client writes its own and seeds it once.
class ZooProgress {
  const ZooProgress({
    this.turns = 0,
    this.days = const {},
    this.weeks = const [],
    this.nights = const [],
    this.machines = const [],
    this.marathon = const [],
    this.history = const [],
    this.held = const [],
    this.batches = const [],
  });
  static const empty = ZooProgress();
  static const dayMemory = 14, weekMemory = 8, historyMemory = 16;
  static const batchMemory = 64, maxHeld = 64;

  final int turns;
  final Map<String, int> days;
  final List<String> weeks, nights, machines, marathon, history, batches;

  /// Eggs earned while the nest was full: `(kind, date)`, oldest first.
  final List<(String, String?)> held;

  bool get isEmpty =>
      turns == 0 && days.isEmpty && held.isEmpty && batches.isEmpty;

  Map<String, dynamic> toJson() => {
    'turns': turns,
    'days': days,
    'weeks': weeks,
    'nights': nights,
    'machines': machines,
    'marathon': marathon,
    'history': history,
    'held': [
      for (final (kind, date) in held) {'kind': kind, 'date': ?date},
    ],
    'batches': batches,
  };

  static List<String> _strings(Object? raw, bool Function(String) keep) =>
      <String>{
        for (final item in raw is List ? raw : const [])
          if (item is String &&
              (_idSafe.hasMatch(item) || isLocalDay(item)) &&
              keep(item))
            item,
      }.toList();

  static List<String> _last(List<String> list, int n) =>
      list.length <= n ? list : list.sublist(list.length - n);

  static ZooProgress fromJson(Object? raw, DaemonRoster roster) {
    if (raw is! Map) return empty;
    final earn = roster.rules.earn;
    final rawDays = raw['days'] is Map ? raw['days'] as Map : const {};
    final days = <String, int>{
      for (final e in rawDays.entries)
        if (e.key is String &&
            isLocalDay(e.key as String) &&
            e.value is int &&
            (e.value as int) > 0)
          e.key as String: min(e.value as int, earn.dailyCap),
    };
    final rawHeld = raw['held'] is List ? raw['held'] as List : const [];
    return ZooProgress(
      turns: raw['turns'] is int ? max(0, raw['turns'] as int) : 0,
      days: pruneDays(days),
      weeks: _last(_strings(raw['weeks'], _weekShape.hasMatch), weekMemory),
      nights: _last(_strings(raw['nights'], isLocalDay), earn.nights - 1),
      machines: _strings(
        raw['machines'],
        (_) => true,
      ).take(earn.marathonMachines).toList(),
      marathon: _strings(
        raw['marathon'],
        (r) => r == 'turns' || r == 'machines',
      ),
      history: _last(_strings(raw['history'], isLocalDay), historyMemory),
      held: [
        for (final h in rawHeld)
          if (h is Map &&
              h['kind'] is String &&
              roster.rules.eggs.containsKey(h['kind']))
            (
              h['kind'] as String,
              h['date'] is String && isLocalDay(h['date'] as String)
                  ? h['date'] as String
                  : null,
            ),
      ].take(maxHeld).toList(),
      batches: _last(_strings(raw['batches'], (_) => true), batchMemory),
    );
  }

  /// Per-day counts older than two weeks before the newest day are forgotten.
  static Map<String, int> pruneDays(Map<String, int> days) {
    if (days.isEmpty) return days;
    final newest = days.keys.map(_dayNumber).reduce(max);
    return {
      for (final e in days.entries)
        if (_dayNumber(e.key) > newest - dayMemory) e.key: e.value,
    };
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
    this.progress = ZooProgress.empty,
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
  final ZooProgress progress;

  /// Nothing a seed could carry: no daemon, egg, habit, word or progress.
  bool get isEmpty =>
      daemons.isEmpty &&
      eggs.isEmpty &&
      habits.isEmpty &&
      !firstEgg &&
      pity == 0 &&
      easter.isEmpty &&
      progress.isEmpty;

  /// What the server's seed refuses to overwrite: any daemon, egg or habit.
  bool get holdsAnything =>
      daemons.isNotEmpty || eggs.isNotEmpty || habits.isNotEmpty;

  bool owns(String id) => daemons.any((d) => d.id == id);

  /// The daemon in the status line: the pair (the first hatched with that
  /// id), else, defensively, the first.
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
    ZooProgress? progress,
  }) => Zoo(
    daemons: daemons ?? this.daemons,
    eggs: eggs ?? this.eggs,
    pair: pair ?? this.pair,
    habits: habits ?? this.habits,
    firstEgg: firstEgg ?? this.firstEgg,
    pity: pity ?? this.pity,
    easter: easter ?? this.easter,
    progress: progress ?? this.progress,
  );

  Map<String, dynamic> toJson() => {
    'daemons': [for (final d in daemons) d.toJson()],
    'eggs': [for (final e in eggs) e.toJson()],
    'pair': pair,
    'habits': habits,
    'firstEgg': firstEgg,
    'pity': pity,
    'easter': easter,
    'progress': progress.toJson(),
  };

  /// Anything unknown to this roster is dropped, never an error.
  static Zoo fromJson(Object? raw, DaemonRoster roster) {
    if (raw is! Map) return empty;
    final daemons = [
      for (final d in raw['daemons'] as List? ?? const [])
        ?ZooDaemon.fromJson(d, roster),
    ].take(maxDaemons).toList();
    final eggs = <ZooEgg>[];
    for (final e in raw['eggs'] as List? ?? const []) {
      final egg = ZooEgg.fromJson(e, roster);
      if (egg != null && !eggs.any((x) => x.id == egg.id)) eggs.add(egg);
    }
    final habitKeys = roster.rules.habits.map((h) => h.key).toSet();
    final pair = raw['pair'];
    return Zoo(
      daemons: daemons,
      eggs: eggs.take(maxEggs).toList(),
      pair: pair is String && daemons.any((d) => d.id == pair) ? pair : null,
      habits: <String>{
        for (final h in raw['habits'] as List? ?? const [])
          if (h is String && habitKeys.contains(h)) h,
      }.toList(),
      firstEgg: raw['firstEgg'] == true,
      pity: raw['pity'] is int ? max(0, raw['pity'] as int) : 0,
      easter: <String>{
        for (final w in raw['easter'] as List? ?? const [])
          if (w is String) w,
      }.toList(),
      progress: ZooProgress.fromJson(raw['progress'], roster),
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

// ── the draw ─────────────────────────────────────────────────────────────────

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
  final unowned = released.where((d) => !zoo.owns(d.id)).toList();
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

  // Nothing new to give (or nothing unowned): draw as if everything were owned.
  var weighted = weigh(unowned);
  if (weighted.every((w) => w.$2 <= 0)) weighted = weigh(released);
  final total = weighted.fold<double>(0, (sum, w) => sum + max(0, w.$2));
  if (total <= 0) return null;
  var x = random.nextDouble() * total;
  for (final (d, w) in weighted) {
    if (w <= 0) continue;
    x -= w;
    if (x < 0) return d.id;
  }
  return weighted.lastWhere((w) => w.$2 > 0).$1.id;
}

// ── ops ──────────────────────────────────────────────────────────────────────

/// An egg that arrived in the nest during a request.
typedef ZooGrant = ({String kind, String eggId});

/// A daemon whose bond reached a new level, and the version it is now.
typedef ZooLevelUp = ({String id, int level, String version});

class ZooOpsResult {
  const ZooOpsResult(this.zoo, this.hatched, this.grants, this.levelUps);
  final Zoo zoo;
  final List<ZooHatch> hatched;
  final List<ZooGrant> grants;
  final List<ZooLevelUp> levelUps;
}

/// Apply ops in order with the server's rules (`backend/src/lib/zoo.ts`).
/// Every op is idempotent; an op on something missing is dropped, never an
/// error. After every op, eggs held while the nest was full land if they fit.
ZooOpsResult applyZooOps(
  DaemonRoster roster,
  Zoo zoo,
  List<Map<String, dynamic>> ops, {
  required Random random,
  required DateTime now,
}) => _ZooRules(roster, zoo, random, now).run(ops);

class _ZooRules {
  _ZooRules(this.roster, Zoo zoo, this.random, this.now)
    : daemons = [...zoo.daemons],
      eggs = [...zoo.eggs],
      pair = zoo.pair,
      habits = [...zoo.habits],
      firstEgg = zoo.firstEgg,
      pity = zoo.pity,
      easter = [...zoo.easter],
      turns = zoo.progress.turns,
      days = {...zoo.progress.days},
      weeks = [...zoo.progress.weeks],
      nights = [...zoo.progress.nights],
      machines = [...zoo.progress.machines],
      marathon = [...zoo.progress.marathon],
      history = [...zoo.progress.history],
      held = [...zoo.progress.held],
      batches = [...zoo.progress.batches];

  final DaemonRoster roster;
  final Random random;
  final DateTime now;
  List<ZooDaemon> daemons;
  List<ZooEgg> eggs;
  String? pair;
  List<String> habits;
  bool firstEgg;
  int pity;
  List<String> easter;
  int turns;
  Map<String, int> days;
  List<String> weeks, nights, machines, marathon, history, batches;
  List<(String, String?)> held;
  final hatched = <ZooHatch>[];
  final grants = <ZooGrant>[];
  final levelUps = <ZooLevelUp>[];

  String get _stamp => now.toUtc().toIso8601String();

  Zoo get zoo => Zoo(
    daemons: daemons,
    eggs: eggs,
    pair: pair,
    habits: habits,
    firstEgg: firstEgg,
    pity: pity,
    easter: easter,
    progress: ZooProgress(
      turns: turns,
      days: days,
      weeks: weeks,
      nights: nights,
      machines: machines,
      marathon: marathon,
      history: history,
      held: held,
      batches: batches,
    ),
  );

  ZooOpsResult run(List<Map<String, dynamic>> ops) {
    for (final op in ops) {
      _apply(op);
      _releaseHeld();
    }
    return ZooOpsResult(zoo, hatched, grants, levelUps);
  }

  String _eggId() {
    const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
    for (;;) {
      final id = List.generate(
        10,
        (_) => alphabet[random.nextInt(alphabet.length)],
      ).join();
      if (!eggs.any((e) => e.id == id)) return id;
    }
  }

  bool _grant(String kind, {String? date}) {
    if (eggs.length >= Zoo.maxEggs) return false;
    final egg = ZooEgg(id: _eggId(), kind: kind, grantedAt: _stamp, date: date);
    eggs = [...eggs, egg];
    grants.add((kind: kind, eggId: egg.id));
    return true;
  }

  /// An egg earned from work waits with the held ones, so a full nest loses
  /// nothing.
  void _earn(String kind, {String? date}) {
    if (held.length >= ZooProgress.maxHeld) return;
    held = [...held, (kind, date)];
  }

  void _releaseHeld() {
    while (held.isNotEmpty && eggs.length < Zoo.maxEggs) {
      final (kind, date) = held.first;
      held = held.sublist(1);
      _grant(kind, date: date);
    }
  }

  void _maybeFirstEgg() {
    if (firstEgg) return;
    final keys = roster.rules.habits.map((h) => h.key).toSet();
    if (habits.where(keys.contains).length < roster.rules.firstEggNeed) return;
    if (_grant('first')) firstEgg = true;
  }

  void _addXp(int xp) {
    final at = daemons.indexWhere((d) => d.id == pair);
    if (at < 0 || xp <= 0) return;
    final d = daemons[at];
    final next = d.xp + xp;
    final level = levelFor(roster, next);
    daemons = [...daemons];
    if (level <= d.bond) {
      daemons[at] = d.copyWith(xp: next);
      return;
    }
    final version = versionFor(roster, level);
    daemons[at] = d.copyWith(xp: next, bond: level, version: version);
    levelUps.add((id: d.id, level: level, version: version));
  }

  void _apply(Map<String, dynamic> op) {
    switch (op['op']) {
      case 'zoo.habit':
        final key = op['key'];
        if (key is! String || !roster.rules.habits.any((h) => h.key == key)) {
          return;
        }
        if (!habits.contains(key)) habits = [...habits, key];
        _maybeFirstEgg();
      case 'zoo.hatch':
        final egg = eggs.where((e) => e.id == op['eggId']).firstOrNull;
        final kind = egg == null ? null : roster.rules.eggs[egg.kind];
        if (egg == null || kind == null || daemons.length >= Zoo.maxDaemons) {
          return;
        }
        final own = egg.kind == 'history' ? _historyDaemon(egg.date) : null;
        final id = own ?? drawDaemon(roster, zoo, kind, random);
        if (id == null) return;
        final shiny = random.nextInt(roster.rules.shinyOneIn) == 0;
        eggs = [...eggs.where((e) => e.id != egg.id)];
        daemons = [
          ...daemons,
          ZooDaemon(
            id: id,
            hatchedAt: _stamp,
            egg: egg.kind,
            shiny: shiny,
            version: roster.rules.versions.first,
          ),
        ];
        pity = roster.byId(id)!.secret ? 0 : pity + 1;
        pair ??= id;
        hatched.add(ZooHatch(eggId: egg.id, daemonId: id, shiny: shiny));
      case 'zoo.pair':
        final id = op['id'];
        if (id is String && daemons.any((d) => d.id == id)) pair = id;
      case 'zoo.nickname':
        final id = op['id'], nickname = op['nickname'];
        final at = daemons.indexWhere((d) => d.id == id);
        if (at < 0 ||
            (nickname != null && !validNickname(nickname as String?))) {
          return;
        }
        daemons = [...daemons];
        daemons[at] = nickname == null
            ? daemons[at].copyWith(clearNickname: true)
            : daemons[at].copyWith(nickname: (nickname as String).trim());
      case 'zoo.easter':
        final word = op['word'];
        if (word is! String ||
            !roster.rules.easterWords.contains(word) ||
            easter.contains(word)) {
          return;
        }
        // A full nest leaves the word unspent.
        if (_grant('easter')) easter = [...easter, word];
      case 'zoo.seed':
        if (zoo.holdsAnything) return;
        final seed = Zoo.fromJson(op['zoo'], roster);
        final fresh = turns == 0 && batches.isEmpty;
        daemons = [...seed.daemons];
        eggs = [];
        for (final e in seed.eggs) {
          eggs = [
            ...eggs,
            ZooEgg(
              id: _eggId(),
              kind: e.kind,
              grantedAt: e.grantedAt,
              date: e.date,
            ),
          ];
        }
        pair = seed.pair ?? seed.daemons.firstOrNull?.id;
        habits = [...seed.habits];
        firstEgg = seed.firstEgg;
        pity = seed.pity;
        easter = [...seed.easter];
        if (fresh) {
          final p = seed.progress;
          turns = p.turns;
          days = {...p.days};
          weeks = [...p.weeks];
          nights = [...p.nights];
          machines = [];
          marathon = [...p.marathon];
          history = [...p.history];
          held = [...p.held];
          batches = [];
        }
      case 'zoo.turn':
        _turn(op);
    }
  }

  String? _historyDaemon(String? date) {
    if (date == null || date.length < 10) return null;
    final id = roster.rules.historyDates[date.substring(5)];
    final def = roster.byId(id);
    if (def == null || daemons.any((d) => d.id == id)) return null;
    return roster.drops.any((d) => d.id == def.drop) ? def.id : null;
  }

  /// Turns finished on one machine in one local hour (README, "Earning eggs
  /// and growing"): the daily cap, turn, marathon, week, night and history
  /// eggs, and the paired daemon's xp.
  void _turn(Map<String, dynamic> op) {
    final batchId = op['batchId'], n = op['n'], day = op['day'];
    final hour = op['hour'], machineId = op['machineId'];
    if (batchId is! String ||
        !_idSafe.hasMatch(batchId) ||
        n is! int ||
        n < 1 ||
        n > 50 ||
        day is! String ||
        !isLocalDay(day) ||
        hour is! int ||
        hour < 0 ||
        hour > 23 ||
        machineId is! String ||
        !_idSafe.hasMatch(machineId)) {
      return;
    }
    if (batches.contains(batchId)) return;
    // A day that cannot be today anywhere on Earth, allowing one day late.
    final today = now.toUtc().millisecondsSinceEpoch ~/ 86400000;
    final at = _dayNumber(day);
    if (at < today - 2 || at > today + 1) return;
    final earn = roster.rules.earn;
    var changed = false;

    if (!machines.contains(machineId) &&
        machines.length < earn.marathonMachines) {
      machines = [...machines, machineId];
      changed = true;
      if (machines.length >= earn.marathonMachines &&
          !marathon.contains('machines')) {
        marathon = [...marathon, 'machines'];
        _earn('marathon');
      }
    }

    final before = days[day] ?? 0;
    final counted = max(0, min(n, earn.dailyCap - before));
    if (counted > 0) {
      changed = true;
      days = ZooProgress.pruneDays({...days, day: before + counted});
      final turnsBefore = turns;
      turns += counted;
      for (
        var k = turnsBefore ~/ earn.turnEvery;
        k < turns ~/ earn.turnEvery;
        k++
      ) {
        _earn('turn');
      }
      if (turns >= earn.marathonTurns && !marathon.contains('turns')) {
        marathon = [...marathon, 'turns'];
        _earn('marathon');
      }
      final week = isoWeek(day);
      if (!weeks.contains(week) &&
          days.keys.where((d) => isoWeek(d) == week).length >= earn.weekDays) {
        weeks = ZooProgress._last([...weeks, week], ZooProgress.weekMemory);
        _earn('week');
      }
      if (hour >= earn.nightFrom &&
          hour <= earn.nightTo &&
          !nights.contains(day)) {
        nights = [...nights, day];
        if (nights.length >= earn.nights) {
          nights = [];
          _earn('night');
        }
      }
      if (roster.rules.historyDates.containsKey(day.substring(5)) &&
          !history.contains(day)) {
        history = ZooProgress._last([
          ...history,
          day,
        ], ZooProgress.historyMemory);
        _earn('history', date: day);
      }
      _addXp(
        counted * roster.rules.xpPerTurn +
            (before == 0 ? roster.rules.xpPerDay : 0),
      );
    }
    // A batch that changed nothing is not remembered.
    if (changed) {
      batches = ZooProgress._last([
        ...batches,
        batchId,
      ], ZooProgress.batchMemory);
    }
  }
}
