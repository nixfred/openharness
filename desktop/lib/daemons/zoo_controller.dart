/// The window's half of the zoo. An account's zoo lives on the server and is
/// reached the way the desk is: `GET /api/zoo` and `POST /api/zoo/ops` through
/// the local harnessd (its Unix socket, or loopback TCP), refreshed on the
/// `zoo_changed` local frame. A guest keeps a local zoo with the same shape and
/// rules, drawn here, and it is sent once with `zoo.seed` on first sign-in.
///
/// Nothing is shown until the zoo has loaded: [loaded] stays false while the
/// scope is unknown (a signed-in window before its profile arrives) and while
/// the first read is in flight, so a boot never flashes a stranger's nest.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../core/local_key_value_store.dart';
import 'roster.dart';
import 'zoo.dart';

abstract interface class ZooTransport {
  /// `{revision, zoo}`, or null when this harnessd has no zoo (it predates it).
  Future<Map<String, dynamic>?> fetch();

  /// `{revision, zoo, hatched}`, or null under the same condition.
  Future<Map<String, dynamic>?> apply(List<Map<String, dynamic>> ops);
}

class ApiZooTransport implements ZooTransport {
  ApiZooTransport(this.api);
  final ApiClient api;
  @override
  Future<Map<String, dynamic>?> fetch() => api.zoo();
  @override
  Future<Map<String, dynamic>?> apply(List<Map<String, dynamic>> ops) =>
      api.zooOps(ops);
}

enum ZooSource {
  /// Not loaded yet, or no scope.
  none,

  /// The account's zoo on the server.
  account,

  /// This installation's local zoo: a guest, or a harnessd without a zoo.
  local,
}

class ZooController extends ChangeNotifier {
  ZooController({
    this.storage,
    DaemonRoster? roster,
    Random? random,
    DateTime Function()? now,
  }) : roster = roster ?? daemonRoster,
       _random = random ?? Random.secure(),
       _now = now ?? DateTime.now;

  static const localZooKey = 'daemons.zoo.v1.local';
  static String prefsKey(String scope) =>
      'daemons.prefs.v1.${base64Url.encode(utf8.encode(scope))}';

  final LocalKeyValueStore? storage;
  final DaemonRoster roster;
  final Random _random;
  final DateTime Function() _now;

  String? _scope;
  ZooTransport? _remote;
  ZooSource _source = ZooSource.none;
  Zoo _zoo = Zoo.empty;
  int _revision = 0;
  int _generation = 0;
  bool _disposed = false;
  bool _seeded = false;
  Zoo _local = Zoo.empty;
  final _days = <String>{};
  bool _hintSeen = false;
  String? _hatchingEgg;
  Future<void> _queue = Future.value();
  Future<void> _saving = Future.value();
  final _unsent = <Map<String, dynamic>>[];
  Timer? _retry;
  int _failures = 0;

  String? get scope => _scope;
  ZooSource get source => _source;
  bool get loaded => _source != ZooSource.none;
  bool get isAccount => _source == ZooSource.account;
  Zoo get zoo => _zoo;
  int get revision => _revision;
  String? get hatchingEgg => _hatchingEgg;
  int get habitsDone => _zoo.habits.length;
  int get habitsNeeded => roster.rules.firstEggNeed;

  /// The daemon in the status line, with its roster entry.
  ZooDaemon? get paired => _zoo.paired;
  DaemonDef? get pairedDef => roster.byId(paired?.id);

  /// The first egg waiting to be hatched.
  ZooEgg? get readyEgg => _zoo.eggs.firstOrNull;

  bool get needsHint => loaded && _zoo.daemons.isEmpty && !_hintSeen;

  /// Choose whose zoo this window shows: `guest`, `account:<id>`, or null
  /// while that is not known yet. A new scope forgets everything.
  void bind(String? scope, {ZooTransport? remote}) {
    if (_disposed || scope == _scope) return;
    _scope = scope;
    _remote = remote;
    _source = ZooSource.none;
    _zoo = Zoo.empty;
    _revision = 0;
    _hatchingEgg = null;
    _unsent.clear();
    _retry?.cancel();
    _retry = null;
    _failures = 0;
    _days.clear();
    _hintSeen = false;
    final generation = ++_generation;
    notifyListeners();
    if (scope != null) unawaited(_load(generation));
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _load(int generation) async {
    final scope = _scope!;
    await _saving;
    final local = await _readJson(localZooKey);
    final prefs = await _readJson(prefsKey(scope));
    if (!_current(generation)) return;
    _local = Zoo.fromJson(local?['zoo'], roster);
    _seeded = local?['seeded'] == true;
    for (final day in prefs?['days'] as List? ?? const []) {
      if (day is String) _days.add(day);
    }
    _hintSeen = prefs?['hintSeen'] == true;
    final remote = _remote;
    if (remote == null) {
      _adoptLocal();
      return;
    }
    await _fetch(generation);
  }

  void _adoptLocal() {
    _source = ZooSource.local;
    _zoo = _local;
    _revision = 0;
    notifyListeners();
  }

  Future<void> _fetch(int generation) async {
    final remote = _remote;
    if (remote == null) return;
    Map<String, dynamic>? raw;
    try {
      raw = await remote.fetch();
    } catch (error) {
      if (!_current(generation)) return;
      debugPrint('zoo: read failed: $error');
      if (!loaded) _scheduleRetry(generation);
      return;
    }
    if (!_current(generation)) return;
    if (raw == null) {
      // This harnessd has no zoo yet. The local zoo stands in, and is seeded
      // into the account's the first time one answers.
      if (!loaded || isAccount) _adoptLocal();
      return;
    }
    final wasAccount = isAccount;
    _adopt(raw, force: !wasAccount);
    if (!wasAccount) {
      _failures = 0;
      unawaited(_seed(generation));
      if (_unsent.isNotEmpty) _flushUnsent(generation);
    }
  }

  void _scheduleRetry(int generation) {
    _failures++;
    final wait = Duration(
      seconds: (5 * (1 << (_failures - 1).clamp(0, 4))).clamp(5, 60),
    );
    _retry?.cancel();
    _retry = Timer(wait, () {
      if (!_current(generation)) return;
      if (!loaded) {
        unawaited(_fetch(generation));
      } else {
        _flushUnsent(generation);
      }
    });
  }

  /// Take the server's answer when it is not older than what is shown.
  bool _adopt(Map<String, dynamic> raw, {bool force = false}) {
    final revision = raw['revision'];
    if (revision is! int) return false;
    if (!force && isAccount && revision < _revision) return false;
    _source = ZooSource.account;
    _revision = revision;
    _zoo = _overlayUnsent(Zoo.fromJson(raw['zoo'], roster));
    notifyListeners();
    return true;
  }

  /// This window's unacknowledged ops laid back over the server's answer, so a
  /// reply to an earlier batch does not briefly undo a later one. Eggs are
  /// never granted here: that is the server's decision.
  Zoo _overlayUnsent(Zoo zoo) {
    var next = zoo;
    for (final op in _unsent) {
      switch (op['op']) {
        case 'zoo.habit':
          final key = op['key'] as String;
          if (!next.habits.contains(key)) {
            next = next.copyWith(habits: [...next.habits, key]);
          }
        case 'zoo.pair':
          if (next.owns(op['id'] as String)) {
            next = next.copyWith(pair: op['id'] as String);
          }
        case 'zoo.nickname':
          next = applyZooOps(
            roster,
            next,
            [op],
            random: _random,
            now: _now(),
          ).zoo;
      }
    }
    return next;
  }

  /// A guest's zoo goes to the account once. The server applies it only while
  /// the account's zoo is empty.
  Future<void> _seed(int generation) async {
    if (_seeded || _local.isEmpty) return;
    try {
      final answer = await _remote!.apply([
        {'op': 'zoo.seed', 'zoo': _local.toJson()},
      ]);
      if (!_current(generation) || answer == null) return;
      _seeded = true;
      _saveLocal();
      _adopt(answer);
    } catch (error) {
      debugPrint('zoo: seed failed: $error');
    }
  }

  /// `zoo_changed { revision }`: fetch only when the push is news.
  void pushed(int? revision) {
    if (_disposed || _scope == null || _remote == null) return;
    if (isAccount && revision != null && revision <= _revision) return;
    unawaited(_fetch(_generation));
  }

  /// Read again, e.g. when harnessd's backend link comes back.
  void refresh() {
    if (_disposed || _scope == null || _remote == null) return;
    unawaited(_fetch(_generation));
  }

  // ── ops ────────────────────────────────────────────────────────────────────

  /// Record a first-egg habit. Sent once; the server grants the egg.
  void habit(String key) {
    if (!loaded ||
        _zoo.habits.contains(key) ||
        !roster.rules.habits.any((h) => h.key == key)) {
      return;
    }
    final op = {'op': 'zoo.habit', 'key': key};
    if (!isAccount) {
      _applyLocal([op]);
      return;
    }
    // Optimistic for the habit only: the egg is the server's to grant.
    _zoo = _zoo.copyWith(habits: [..._zoo.habits, key]);
    notifyListeners();
    _sendLater(op);
  }

  void pair(String id) {
    if (!loaded || !_zoo.owns(id) || _zoo.pair == id) return;
    final op = {'op': 'zoo.pair', 'id': id};
    if (!isAccount) {
      _applyLocal([op]);
      return;
    }
    _zoo = _zoo.copyWith(pair: id);
    notifyListeners();
    _sendLater(op);
  }

  /// Rename, or clear with null. Answers false for a name the rules refuse.
  bool nickname(String id, String? nickname) {
    if (!loaded || !_zoo.owns(id)) return false;
    final value = nickname?.trim();
    if (value != null && value.isNotEmpty && !validNickname(value)) {
      return false;
    }
    final op = {
      'op': 'zoo.nickname',
      'id': id,
      'nickname': value == null || value.isEmpty ? null : value,
    };
    final result = applyZooOps(
      roster,
      _zoo,
      [op],
      random: _random,
      now: _now(),
    );
    if (!isAccount) {
      _local = result.zoo;
      _zoo = result.zoo;
      _saveLocal();
      notifyListeners();
      return true;
    }
    _zoo = result.zoo;
    notifyListeners();
    _sendLater(op);
    return true;
  }

  void easter(String word) {
    if (!loaded ||
        _zoo.easter.contains(word) ||
        !roster.rules.easterWords.contains(word)) {
      return;
    }
    final op = {'op': 'zoo.easter', 'word': word};
    if (!isAccount) {
      _applyLocal([op]);
      return;
    }
    _sendLater(op);
  }

  /// Open an egg. The draw happens on the server for an account (here only
  /// for a local zoo); null when the egg is gone or harnessd cannot be reached.
  Future<ZooHatch?> hatch(String eggId) async {
    if (!loaded || _hatchingEgg != null) return null;
    if (!_zoo.eggs.any((e) => e.id == eggId)) return null;
    _hatchingEgg = eggId;
    notifyListeners();
    final generation = _generation;
    try {
      final op = {'op': 'zoo.hatch', 'eggId': eggId};
      if (!isAccount) {
        return _applyLocal([op]).where((h) => h.eggId == eggId).firstOrNull;
      }
      final completer = Completer<Map<String, dynamic>?>();
      _enqueue(() async {
        try {
          completer.complete(await _remote!.apply([op]));
        } catch (error) {
          completer.completeError(error);
        }
      });
      final answer = await completer.future;
      if (!_current(generation) || answer == null) return null;
      _adopt(answer);
      return [
        for (final h in answer['hatched'] as List? ?? const [])
          ?ZooHatch.fromJson(h),
      ].where((h) => h.eggId == eggId).firstOrNull;
    } catch (error) {
      debugPrint('zoo: hatch failed: $error');
      return null;
    } finally {
      if (_current(generation)) {
        _hatchingEgg = null;
        notifyListeners();
      }
    }
  }

  List<ZooHatch> _applyLocal(List<Map<String, dynamic>> ops) {
    final result = applyZooOps(roster, _zoo, ops, random: _random, now: _now());
    _zoo = result.zoo;
    _local = result.zoo;
    _saveLocal();
    notifyListeners();
    return result.hatched;
  }

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) => work()).catchError((_) {});
  }

  void _sendLater(Map<String, dynamic> op) {
    _unsent.add(op);
    _flushUnsent(_generation);
  }

  void _flushUnsent(int generation) {
    _enqueue(() async {
      if (!_current(generation) || _unsent.isEmpty || !isAccount) return;
      final batch = List<Map<String, dynamic>>.of(_unsent);
      Map<String, dynamic>? answer;
      try {
        answer = await _remote!.apply(batch);
      } catch (error) {
        if (!_current(generation)) return;
        debugPrint('zoo: write failed (${batch.length} ops): $error');
        // Kept, not dropped: every op is idempotent, so a retry is safe.
        _scheduleRetry(generation);
        return;
      }
      if (!_current(generation)) return;
      _failures = 0;
      _unsent.removeRange(0, batch.length.clamp(0, _unsent.length));
      if (answer != null) _adopt(answer);
    });
  }

  // ── local preferences: days used, the arrival hint ──────────────────────────

  /// The `days` habit: Harness used on three different local days.
  void noteDay() {
    if (!loaded) return;
    final now = _now();
    final day =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    if (_days.add(day)) {
      while (_days.length > 7) {
        _days.remove((_days.toList()..sort()).first);
      }
      _savePrefs();
    }
    if (_days.length >= 3) habit('days');
  }

  int get daysUsed => _days.length;

  bool acknowledgeHint() {
    if (!needsHint) return false;
    _hintSeen = true;
    _savePrefs();
    notifyListeners();
    return true;
  }

  Future<Map?> _readJson(String key) async {
    try {
      final raw = await storage?.read(key);
      final decoded = raw == null ? null : jsonDecode(raw);
      return decoded is Map ? decoded : null;
    } catch (_) {
      // A missing or corrupt preference cannot block getting to work.
      return null;
    }
  }

  void _write(String key, Map<String, dynamic> value) {
    final data = jsonEncode(value);
    _saving = _saving.then((_) async {
      try {
        await storage?.write(key, data);
      } catch (_) {}
    });
  }

  void _saveLocal() =>
      _write(localZooKey, {'zoo': _local.toJson(), 'seeded': _seeded});

  void _savePrefs() {
    final scope = _scope;
    if (scope == null) return;
    _write(prefsKey(scope), {
      'days': (_days.toList()..sort()),
      'hintSeen': _hintSeen,
    });
  }

  Future<void> flush() async {
    await _queue;
    await _saving;
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    super.dispose();
  }
}
