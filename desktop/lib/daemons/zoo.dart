/// The zoo: your daemons and eggs, account state the same on every client
/// (`daemons/README.md`, "The zoo" and "Earning eggs and growing"). The server
/// is the authority for an account (`backend/src/lib/zoo.ts`); this file is the
/// wire shape and the same rules, applied on the client only for a guest's
/// local zoo (and a harnessd that predates the zoo).
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/dart.dart' show DartSha256;

import 'roster.dart';

final _printable = RegExp(r'^[\x20-\x7e]*$');
final _idSafe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _dayShape = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final _weekShape = RegExp(r'^\d{4}-W\d{2}$');

final _hashShape = RegExp(r'^[0-9a-f]{64}$');

/// The sha256 (hex) of an easter word as the server hashes it: trimmed and
/// lowercased. The roster lists only these (`rules.easterHashes`).
String easterHash(String word) => [
  for (final b
      in const DartSha256().hashSync(utf8.encode(word.trim().toLowerCase())).bytes)
    b.toRadixString(16).padLeft(2, '0'),
].join();

/// The one easter word a client may know by heart (README: "a client that
/// wants to react locally to `xyzzy` may hard-code that one classic").
const classicEasterWord = 'xyzzy';

/// A nickname: 1–24 printable ASCII characters.
bool validNickname(String? value) =>
    value != null &&
    value.trim().isNotEmpty &&
    value.trim().length <= 24 &&
    _printable.hasMatch(value);

// ── the autonomy dial ────────────────────────────────────────────────────────

/// How much the paired daemon may do on its own (`daemons/BRAIN.md`,
/// "Autonomy dial"; `backend/src/lib/zoo.ts` `ZOO_AUTONOMY_LEVELS`).
const zooAutonomyLevels = ['watch', 'suggest', 'act-on-key', 'act-within-rules'];

/// What a zoo that never set the dial means.
const zooDefaultAutonomy = 'suggest';

bool isZooAutonomy(Object? value) =>
    value is String && zooAutonomyLevels.contains(value);

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

String _dayOf(int n) =>
    localDayOf(DateTime.fromMillisecondsSinceEpoch(n * 86400000, isUtc: true));

/// The night a turn finishing at local [hour] of [day] belongs to, named by
/// the day it began, or null outside the night hours (which may run past
/// midnight: 02:00 on the 22nd is the night of the 21st).
String? nightOf(DaemonRoster roster, String day, int hour) {
  final from = roster.rules.earn.nightFrom, to = roster.rules.earn.nightTo;
  if (from <= to) return hour >= from && hour <= to ? day : null;
  if (hour >= from) return day;
  return hour <= to ? _dayOf(_dayNumber(day) - 1) : null;
}

/// The history dates whose egg is open on [day]: each `MM-DD` of
/// `rules.historyDates`, in the year its week began, when [day] is within
/// `earn.history.days` of it.
List<String> historyDatesOpen(DaemonRoster roster, String day) {
  final at = _dayNumber(day);
  final year = int.parse(day.substring(0, 4));
  final open = <String>[];
  for (final mmdd in roster.rules.historyDates.keys) {
    for (final y in [year - 1, year]) {
      final date = '$y-$mmdd';
      if (!isLocalDay(date)) continue;
      final since = at - _dayNumber(date);
      if (since >= 0 && since < roster.rules.earn.historyDays) open.add(date);
    }
  }
  return open..sort();
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
    this.dupes = 0,
    this.serial,
    this.origin,
  });
  static const maxDupes = 1000000, maxSerial = 1000000000;
  final String id;
  final String hatchedAt;
  final String egg;
  final bool shiny;
  final String? nickname;
  final int bond, xp;
  final String version;

  /// Duplicates merged into this one: the shelf's `x2` is one.
  final int dupes;

  /// Its mint number (`#0042`): the nth of its kind the server hatched. None
  /// for a guest's daemon ([origin] `local`) or one hatched before serials.
  final int? serial;

  /// `local`: hatched in a guest's zoo, brought in by `zoo.seed`.
  final String? origin;

  /// How many of it you have: 1 and its duplicates.
  int get count => 1 + dupes;

  DateTime get hatchedDate =>
      DateTime.tryParse(hatchedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);

  ZooDaemon copyWith({
    String? nickname,
    bool clearNickname = false,
    int? xp,
    int? bond,
    String? version,
    bool? shiny,
    int? dupes,
    String? origin,
    bool clearSerial = false,
  }) => ZooDaemon(
    id: id,
    hatchedAt: hatchedAt,
    egg: egg,
    shiny: shiny ?? this.shiny,
    nickname: clearNickname ? null : nickname ?? this.nickname,
    bond: bond ?? this.bond,
    xp: xp ?? this.xp,
    version: version ?? this.version,
    dupes: dupes ?? this.dupes,
    serial: clearSerial ? null : serial,
    origin: origin ?? this.origin,
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
    if (dupes > 0) 'dupes': dupes,
    'serial': ?serial,
    'origin': ?origin,
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
    final dupes = raw['dupes'], serial = raw['serial'];
    return ZooDaemon(
      id: id,
      hatchedAt: raw['hatchedAt'] is String ? raw['hatchedAt'] as String : '',
      egg: raw['egg'] is String ? raw['egg'] as String : 'first',
      shiny: raw['shiny'] == true,
      nickname: validNickname(nickname as String?) ? nickname!.trim() : null,
      bond: bond,
      xp: xp,
      version: versionFor(roster, bond),
      dupes: dupes is int && dupes > 0 ? min(dupes, maxDupes) : 0,
      serial: serial is int && serial >= 1 && serial <= maxSerial
          ? serial
          : null,
      origin: raw['origin'] == 'local' ? 'local' : null,
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
    this.autonomy = zooDefaultAutonomy,
    this.habits = const [],
    this.firstEgg = false,
    this.setupEgg = false,
    this.pity = 0,
    this.easter = const [],
    this.progress = ZooProgress.empty,
  });
  static const empty = Zoo();
  static const maxEggs = 12, maxDaemons = 64;

  final List<ZooDaemon> daemons;
  final List<ZooEgg> eggs;
  final String? pair;

  /// The pair's autonomy dial, one of [zooAutonomyLevels].
  final String autonomy;
  final List<String> habits;
  final bool firstEgg;

  /// The setup egg (at `rules.setupEgg.need` habits) has been granted.
  final bool setupEgg;

  /// Hatches of eggs that can hold a secret since the last secret.
  final int pity;

  /// sha256 of each easter word already used.
  final List<String> easter;
  final ZooProgress progress;

  /// Nothing a seed could carry: no daemon, egg, habit, word or progress.
  bool get isEmpty =>
      daemons.isEmpty &&
      eggs.isEmpty &&
      habits.isEmpty &&
      !firstEgg &&
      !setupEgg &&
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
    String? autonomy,
    List<String>? habits,
    bool? firstEgg,
    bool? setupEgg,
    int? pity,
    List<String>? easter,
    ZooProgress? progress,
  }) => Zoo(
    daemons: daemons ?? this.daemons,
    eggs: eggs ?? this.eggs,
    pair: pair ?? this.pair,
    autonomy: autonomy ?? this.autonomy,
    habits: habits ?? this.habits,
    firstEgg: firstEgg ?? this.firstEgg,
    setupEgg: setupEgg ?? this.setupEgg,
    pity: pity ?? this.pity,
    easter: easter ?? this.easter,
    progress: progress ?? this.progress,
  );

  Map<String, dynamic> toJson() => {
    'daemons': [for (final d in daemons) d.toJson()],
    'eggs': [for (final e in eggs) e.toJson()],
    'pair': pair,
    'autonomy': autonomy,
    'habits': habits,
    'firstEgg': firstEgg,
    'setupEgg': setupEgg,
    'pity': pity,
    'easter': easter,
    'progress': progress.toJson(),
  };

  /// Anything unknown to this roster is dropped, never an error. A second
  /// record of one daemon (a zoo from before duplicates merged) folds into
  /// the first: counted in its `dupes`, shiny if either was, no xp.
  static Zoo fromJson(Object? raw, DaemonRoster roster) {
    if (raw is! Map) return empty;
    final daemons = <ZooDaemon>[];
    for (final item in raw['daemons'] as List? ?? const []) {
      final d = ZooDaemon.fromJson(item, roster);
      if (d == null) continue;
      final at = daemons.indexWhere((x) => x.id == d.id);
      if (at >= 0) {
        final first = daemons[at];
        daemons[at] = first.copyWith(
          dupes: min(first.dupes + 1 + d.dupes, ZooDaemon.maxDupes),
          shiny: first.shiny || d.shiny,
        );
      } else if (daemons.length < maxDaemons) {
        daemons.add(d);
      }
    }
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
      autonomy: isZooAutonomy(raw['autonomy'])
          ? raw['autonomy'] as String
          : zooDefaultAutonomy,
      habits: <String>{
        for (final h in raw['habits'] as List? ?? const [])
          if (h is String && habitKeys.contains(h)) h,
      }.toList(),
      firstEgg: raw['firstEgg'] == true,
      setupEgg: raw['setupEgg'] == true,
      pity: raw['pity'] is int ? max(0, raw['pity'] as int) : 0,
      // A word stored before words were hashed reads as its hash.
      easter: <String>{
        for (final w in raw['easter'] as List? ?? const [])
          if (w is String && w.isNotEmpty && w.length <= 64)
            _hashShape.hasMatch(w) ? w : easterHash(w),
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
    this.duplicate = false,
    this.xp = 0,
    this.serial,
  });
  final String eggId, daemonId;

  /// This hatch's own shiny roll (a shiny duplicate makes yours shiny).
  final bool shiny;

  /// It drew a daemon you own: merged into yours, giving it [xp].
  final bool duplicate;
  final int xp;

  /// A new daemon's mint number, when the server gave one.
  final int? serial;

  static ZooHatch? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final eggId = raw['eggId'], daemonId = raw['daemonId'];
    if (eggId is! String || daemonId is! String) return null;
    final xp = raw['xp'], serial = raw['serial'];
    return ZooHatch(
      eggId: eggId,
      daemonId: daemonId,
      shiny: raw['shiny'] == true,
      duplicate: raw['duplicate'] == true,
      xp: xp is int && xp > 0 ? xp : 0,
      serial: serial is int && serial > 0 ? serial : null,
    );
  }
}

// ── the draw ─────────────────────────────────────────────────────────────────

/// Whether an egg of [kind] can hold a secret (its `weights.secret` is above
/// 0); only its hatches count toward the pity.
bool eggHoldsSecret(DaemonRoster roster, String kind) =>
    (roster.rules.eggs[kind]?.weights['secret'] ?? 0) > 0;

/// Who can come out of an egg for this zoo at [now], and how likely
/// (README, "The draw"; `backend/src/lib/zoo.ts` `drawWeights`):
///
///  1. Regulars first: every released regular you do not own; once you own
///     them all, every released regular again (a duplicate). Secrets sit
///     outside the set: an unowned released secret is eligible only from an
///     egg that can hold one.
///  2. Weight: `weights[rarity] / (eligible of that rarity)`, plus
///     `pity * pityPerMiss` for a secret, times `boost[id]`.
///  3. The guarantee: from an egg that can hold a secret, when the pity is
///     one short of `secretGuaranteeAt`, only the unowned secrets.
///
/// An egg whose eligible daemons all weigh nothing draws as if everything
/// were owned.
List<(DaemonDef, double)> drawWeights(
  DaemonRoster roster,
  Zoo zoo,
  String kind, {
  required DateTime now,
}) {
  final egg = roster.rules.eggs[kind];
  if (egg == null) return const [];
  final secretsToo = eggHoldsSecret(roster, kind);
  final released = roster.released(now);
  final regulars = released.where((d) => !d.secret).toList();
  final fresh = regulars.where((d) => !zoo.owns(d.id)).toList();
  final secrets = secretsToo
      ? released.where((d) => d.secret && !zoo.owns(d.id)).toList()
      : const <DaemonDef>[];
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
                  (d.secret && secretsToo
                      ? zoo.pity * roster.rules.pityPerMiss
                      : 0)) *
              (egg.boost[d.id] ?? 1),
        ),
    ];
  }

  if (secrets.isNotEmpty &&
      roster.rules.secretGuaranteeAt > 0 &&
      zoo.pity + 1 >= roster.rules.secretGuaranteeAt) {
    return weigh(secrets);
  }
  final eligible = {...(fresh.isNotEmpty ? fresh : regulars), ...secrets};
  final weights = weigh(released.where(eligible.contains).toList());
  return weights.any((w) => w.$2 > 0) ? weights : weigh(released);
}

/// The draw (`zoo.hatch`): the README's rules, for a guest's local zoo only.
/// An account's draw happens on the server; clients never send a result.
String? drawDaemon(
  DaemonRoster roster,
  Zoo zoo,
  String kind,
  Random random, {
  required DateTime now,
}) {
  final weighted = drawWeights(roster, zoo, kind, now: now);
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

/// An egg that arrived in the nest during a request, or one earned past the
/// held queue that became [xp] for the paired daemon instead.
typedef ZooGrant = ({String kind, String? eggId, int? xp});

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
      autonomy = zoo.autonomy,
      habits = [...zoo.habits],
      firstEgg = zoo.firstEgg,
      setupEgg = zoo.setupEgg,
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
  String autonomy;
  List<String> habits;
  bool firstEgg, setupEgg;
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
    autonomy: autonomy,
    habits: habits,
    firstEgg: firstEgg,
    setupEgg: setupEgg,
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
    grants.add((kind: kind, eggId: egg.id, xp: null));
    return true;
  }

  /// An egg earned from work waits with the held ones, so a full nest loses
  /// nothing. Past 64 held it becomes `overflowXp` for the paired daemon.
  void _earn(String kind, {String? date}) {
    if (held.length < ZooProgress.maxHeld) {
      held = [...held, (kind, date)];
      return;
    }
    if (!daemons.any((d) => d.id == pair)) return;
    _addXp(roster.rules.overflowXp);
    grants.add((kind: kind, eggId: null, xp: roster.rules.overflowXp));
  }

  void _releaseHeld() {
    while (held.isNotEmpty && eggs.length < Zoo.maxEggs) {
      final (kind, date) = held.first;
      held = held.sublist(1);
      _grant(kind, date: date);
    }
  }

  /// The eggs habits earn, each once: the first at `firstEgg.need` habits,
  /// every required one (a finished turn) among them; then the setup egg.
  void _maybeHabitEggs() {
    final keys = roster.rules.habits.map((h) => h.key).toSet();
    final done = habits.where(keys.contains).toList();
    if (!firstEgg &&
        done.length >= roster.rules.firstEggNeed &&
        roster.rules.firstEggRequire.every(done.contains) &&
        _grant('first')) {
      firstEgg = true;
    }
    final setup = roster.rules.setupEggNeed;
    if (firstEgg &&
        !setupEgg &&
        setup != null &&
        roster.rules.eggs.containsKey('setup') &&
        done.length >= setup &&
        _grant('setup')) {
      setupEgg = true;
    }
  }

  void _addXp(int xp) => _grow(daemons.indexWhere((d) => d.id == pair), xp);

  /// xp for one daemon; a new level is answered in `levelUps`.
  void _grow(int at, int xp) {
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
        _maybeHabitEggs();
      case 'zoo.hatch':
        final egg = eggs.where((e) => e.id == op['eggId']).firstOrNull;
        if (egg == null || !roster.rules.eggs.containsKey(egg.kind)) return;
        final own = egg.kind == 'history' ? _historyDaemon(egg.date) : null;
        final id =
            own ?? drawDaemon(roster, zoo, egg.kind, random, now: now);
        if (id == null) return;
        final shiny = random.nextInt(roster.rules.shinyOneIn) == 0;
        final at = daemons.indexWhere((d) => d.id == id);
        if (at < 0 && daemons.length >= Zoo.maxDaemons) return;
        eggs = [...eggs.where((e) => e.id != egg.id)];
        // The pity counts only hatches that could have been a secret.
        if (roster.byId(id)!.secret) {
          pity = 0;
        } else if (eggHoldsSecret(roster, egg.kind)) {
          pity++;
        }
        if (at >= 0) {
          // A duplicate grows the one you have; a shiny one makes it shiny.
          daemons = [...daemons];
          daemons[at] = daemons[at].copyWith(
            dupes: min(daemons[at].dupes + 1, ZooDaemon.maxDupes),
            shiny: daemons[at].shiny || shiny,
          );
          _grow(at, roster.rules.duplicateXp);
          hatched.add(
            ZooHatch(
              eggId: egg.id,
              daemonId: id,
              shiny: shiny,
              duplicate: true,
              xp: roster.rules.duplicateXp,
            ),
          );
          return;
        }
        daemons = [
          ...daemons,
          ZooDaemon(
            id: id,
            hatchedAt: _stamp,
            egg: egg.kind,
            shiny: shiny,
            version: roster.rules.versions.first,
            // Only the server mints serials; a guest's daemon is local.
            origin: 'local',
          ),
        ];
        pair ??= id;
        hatched.add(ZooHatch(eggId: egg.id, daemonId: id, shiny: shiny));
      case 'zoo.pair':
        final id = op['id'];
        if (id is String && daemons.any((d) => d.id == id)) pair = id;
      case 'zoo.autonomy':
        // A level the server does not know is dropped.
        final level = op['level'];
        if (isZooAutonomy(level)) autonomy = level as String;
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
        if (word is! String || word.isEmpty || word.length > 64) return;
        final hash = easterHash(word);
        if (!roster.rules.easterHashes.contains(hash) ||
            easter.contains(hash)) {
          return;
        }
        // A full nest leaves the word unspent.
        if (_grant('easter')) easter = [...easter, hash];
      case 'zoo.seed':
        if (zoo.holdsAnything) return;
        final seed = Zoo.fromJson(op['zoo'], roster);
        final fresh = turns == 0 && batches.isEmpty;
        // A guest's daemons hatched on a client: marked local, never with a
        // serial (only the server mints).
        daemons = [
          for (final d in seed.daemons)
            d.copyWith(origin: 'local', clearSerial: true),
        ];
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
        // The guest's dial, if it set a real one; else the account's stays.
        final raw = op['zoo'];
        if (raw is Map && isZooAutonomy(raw['autonomy'])) {
          autonomy = seed.autonomy;
        }
        habits = [...seed.habits];
        firstEgg = seed.firstEgg;
        setupEgg = seed.setupEgg;
        pity = seed.pity;
        easter = [
          for (final h in seed.easter)
            if (roster.rules.easterHashes.contains(h)) h,
        ];
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
    return roster.drop(def.drop)?.releasedAt(now) ?? false ? def.id : null;
  }

  /// Turns finished on one machine in one local hour (README, "Earning eggs
  /// and growing"): the daily cap, turn, marathon, week, night and history
  /// eggs, and the paired daemon's xp.
  void _turn(Map<String, dynamic> op) {
    final batchId = op['batchId'], n = op['n'], day = op['day'];
    final hour = op['hour'], machineId = op['machineId'];
    final minutes = op['minutes'] ?? 0, away = op['away'] ?? 0;
    if (minutes is! int ||
        minutes < 0 ||
        minutes > 50 * 24 * 60 ||
        away is! int ||
        away < 0 ||
        batchId is! String ||
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
        !_idSafe.hasMatch(machineId) ||
        away > n) {
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
    // Long turns count more: one more for every minutesPerTurn they ran.
    final units =
        n + (earn.minutesPerTurn > 0 ? minutes ~/ earn.minutesPerTurn : 0);
    final counted = max(0, min(units, earn.dailyCap - before));
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
      // A night counts for a turn that finished while you were away.
      final night = away > 0 ? nightOf(roster, day, hour) : null;
      if (night != null && !nights.contains(night)) {
        nights = [...nights, night];
        if (nights.length >= earn.nights) {
          nights = [];
          _earn('night');
        }
      }
      for (final date in historyDatesOpen(roster, day)) {
        if (history.contains(date)) continue;
        history = ZooProgress._last([
          ...history,
          date,
        ], ZooProgress.historyMemory);
        _earn('history', date: date);
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
