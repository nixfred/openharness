// The zoo: the README's rules (for a guest's local zoo) and the window's half
// of the account zoo, against a scripted harnessd.
import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness/core/local_key_value_store.dart';
import 'package:harness/daemons/roster.dart';
import 'package:harness/daemons/zoo.dart';
import 'package:harness/daemons/zoo_controller.dart';

class _Memory implements LocalKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// harnessd's `/api/zoo` proxy, scripted: the server's rules applied to a
/// document, a zoo-less daemon (null), or a failure.
class FakeZooTransport implements ZooTransport {
  FakeZooTransport({this.available = true});
  bool available;
  Object? failWith;
  Zoo zoo = Zoo.empty;
  int revision = 0;
  final batches = <List<Map<String, dynamic>>>[];
  int fetches = 0;
  Completer<void>? gate;
  final random = Random(7);

  Map<String, dynamic> get _doc => {'revision': revision, 'zoo': zoo.toJson()};

  @override
  Future<Map<String, dynamic>?> fetch() async {
    fetches++;
    await gate?.future;
    if (failWith != null) throw failWith!;
    return available ? _doc : null;
  }

  @override
  Future<Map<String, dynamic>?> apply(List<Map<String, dynamic>> ops) async {
    await gate?.future;
    if (failWith != null) throw failWith!;
    if (!available) return null;
    batches.add(ops);
    final result = applyZooOps(
      daemonRoster,
      zoo,
      ops,
      random: random,
      now: DateTime.utc(2026, 9, 26, 9, 42),
    );
    zoo = result.zoo;
    revision++;
    return {
      ..._doc,
      'hatched': [
        for (final h in result.hatched)
          {'eggId': h.eggId, 'daemonId': h.daemonId, 'shiny': h.shiny},
      ],
    };
  }
}

Map<String, dynamic> habit(String key) => {'op': 'zoo.habit', 'key': key};

void main() {
  final roster = daemonRoster;
  final now = DateTime.utc(2026, 9, 26);
  ZooOpsResult apply(Zoo zoo, List<Map<String, dynamic>> ops, [int seed = 1]) =>
      applyZooOps(roster, zoo, ops, random: Random(seed), now: now);

  group('rules', () {
    test('five of eight habits grant one first egg, once', () {
      var zoo = apply(Zoo.empty, [
        for (final key in ['turn', 'split', 'find', 'turn', 'bogus'])
          habit(key),
      ]).zoo;
      expect(zoo.habits, ['turn', 'split', 'find']);
      expect(zoo.eggs, isEmpty);
      zoo = apply(zoo, [habit('machine'), habit('store')]).zoo;
      expect(zoo.firstEgg, isTrue);
      expect(zoo.eggs.single.kind, 'first');
      zoo = apply(zoo, [habit('resume'), habit('days')]).zoo;
      expect(zoo.eggs, hasLength(1), reason: 'the first egg is granted once');
    });

    test('a hatch draws, removes the egg, pairs the first and counts pity', () {
      var zoo = apply(Zoo.empty, [
        for (final h in roster.rules.habits.take(5)) habit(h.key),
      ]).zoo;
      final egg = zoo.eggs.single;
      final result = apply(zoo, [
        {'op': 'zoo.hatch', 'eggId': egg.id},
        {'op': 'zoo.hatch', 'eggId': egg.id},
      ]);
      zoo = result.zoo;
      expect(result.hatched, hasLength(1), reason: 'a missing egg is dropped');
      expect(zoo.eggs, isEmpty);
      expect(zoo.daemons.single.id, result.hatched.single.daemonId);
      expect(zoo.pair, zoo.daemons.single.id);
      expect(zoo.daemons.single.version, '0.1');
      expect(zoo.daemons.single.egg, 'first');
      expect(zoo.pity, zoo.daemons.single.id == 'grue' ? 0 : 1);
    });

    test('no duplicates until the drop is complete', () {
      var zoo = Zoo.empty;
      final random = Random(3);
      final seen = <String>[];
      for (var i = 0; i < roster.daemons.length; i++) {
        final kind = roster.rules.eggs['marathon']!;
        final id = drawDaemon(roster, zoo, kind, random)!;
        expect(zoo.owns(id), isFalse);
        seen.add(id);
        zoo = zoo.copyWith(
          daemons: [
            ...zoo.daemons,
            ZooDaemon(id: id, hatchedAt: '', egg: 'marathon'),
          ],
        );
      }
      expect(seen.toSet(), roster.daemons.map((d) => d.id).toSet());
      // Everything owned: duplicates again.
      expect(
        drawDaemon(roster, zoo, roster.rules.eggs['first']!, random),
        isNotNull,
      );
    });

    test('odds follow the egg weights over eligible daemons', () {
      final random = Random(11);
      final counts = <String, int>{};
      const draws = 20000;
      for (var i = 0; i < draws; i++) {
        final id = drawDaemon(
          roster,
          Zoo.empty,
          roster.rules.eggs['first']!,
          random,
        )!;
        final rarity = roster.byId(id)!.rarity;
        counts[rarity] = (counts[rarity] ?? 0) + 1;
      }
      expect(counts['common']! / draws, closeTo(.60, .02));
      expect(counts['rare']! / draws, closeTo(.27, .02));
      expect(counts['legendary']! / draws, closeTo(.12, .015));
      expect(counts['secret']! / draws, closeTo(.01, .005));
      // A night egg boosts bat fourfold among the commons.
      final night = <String, int>{};
      for (var i = 0; i < draws; i++) {
        final id = drawDaemon(
          roster,
          Zoo.empty,
          roster.rules.eggs['night']!,
          random,
        )!;
        night[id] = (night[id] ?? 0) + 1;
      }
      expect(night['bat']! / night['tim']!, closeTo(4, .6));
    });

    test('pity raises the secret and resets on it', () {
      final egg = roster.rules.eggs['first']!;
      final random = Random(5);
      var grue = 0;
      for (var i = 0; i < 4000; i++) {
        if (drawDaemon(roster, const Zoo(pity: 40), egg, random) == 'grue') {
          grue++;
        }
      }
      // (1 + 40) against 60 + 27 + 12: about 29%.
      expect(grue / 4000, closeTo(41 / 140, .03));
    });

    test('pair, nickname, easter and seed follow the rules', () {
      var zoo = const Zoo(
        daemons: [
          ZooDaemon(id: 'tim', hatchedAt: '', egg: 'first'),
          ZooDaemon(id: 'vim', hatchedAt: '', egg: 'turn'),
        ],
        pair: 'tim',
      );
      zoo = apply(zoo, [
        {'op': 'zoo.pair', 'id': 'fzf'},
        {'op': 'zoo.pair', 'id': 'vim'},
        {'op': 'zoo.nickname', 'id': 'vim', 'nickname': 'x' * 25},
        {'op': 'zoo.nickname', 'id': 'vim', 'nickname': 'café'},
        {'op': 'zoo.nickname', 'id': 'tim', 'nickname': ' Pip '},
        {'op': 'zoo.easter', 'word': 'plugh'},
        {'op': 'zoo.easter', 'word': 'xyzzy'},
        {'op': 'zoo.easter', 'word': 'xyzzy'},
      ]).zoo;
      expect(zoo.pair, 'vim');
      expect(zoo.daemons[1].nickname, isNull);
      expect(zoo.daemons[0].nickname, 'Pip');
      expect(zoo.eggs.single.kind, 'easter');
      expect(zoo.easter, ['xyzzy']);
      zoo = apply(zoo, [
        {'op': 'zoo.nickname', 'id': 'tim', 'nickname': null},
      ]).zoo;
      expect(zoo.daemons[0].nickname, isNull);
      // Seed applies only to an empty zoo.
      final seeded = apply(Zoo.empty, [
        {'op': 'zoo.seed', 'zoo': zoo.toJson()},
      ]).zoo;
      expect(seeded.toJson(), zoo.toJson());
      expect(
        apply(seeded, [
          {'op': 'zoo.seed', 'zoo': Zoo.empty.toJson()},
        ]).zoo.toJson(),
        zoo.toJson(),
      );
    });

    test('unknown daemons, eggs and habits are dropped on read', () {
      final zoo = Zoo.fromJson({
        'daemons': [
          {'id': 'tim', 'hatchedAt': '2026-09-26', 'egg': 'first'},
          {'id': 'clippy', 'hatchedAt': '2026-09-26', 'egg': 'first'},
        ],
        'eggs': [
          {'id': 'e1', 'kind': 'week', 'grantedAt': ''},
          {'id': 'e2', 'kind': 'mystery', 'grantedAt': ''},
        ],
        'pair': 'clippy',
        'habits': ['turn', 'turn', 'fly'],
      }, roster);
      expect(zoo.daemons.map((d) => d.id), ['tim']);
      expect(zoo.eggs.map((e) => e.id), ['e1']);
      expect(zoo.pair, isNull);
      expect(zoo.paired?.id, 'tim');
      expect(zoo.habits, ['turn']);
    });
  });

  group('controller', () {
    late _Memory storage;
    setUp(() => storage = _Memory());

    ZooController controller() => ZooController(
      storage: storage,
      random: Random(2),
      now: () => DateTime(2026, 9, 26, 9, 42),
    );

    test(
      'nothing is shown until a scope is known and the zoo is read',
      () async {
        final remote = FakeZooTransport()..gate = Completer();
        final zoo = controller();
        addTearDown(zoo.dispose);
        zoo.bind(null);
        expect(zoo.loaded, isFalse);
        zoo.bind('account:u1', remote: remote);
        await pumpEventQueue();
        expect(
          zoo.loaded,
          isFalse,
          reason: 'the first read is still in flight',
        );
        remote.gate!.complete();
        await pumpEventQueue();
        expect(zoo.loaded, isTrue);
        expect(zoo.isAccount, isTrue);
      },
    );

    test('a guest zoo is local, drawn here and remembered', () async {
      final zoo = controller();
      addTearDown(zoo.dispose);
      zoo.bind('guest');
      await pumpEventQueue();
      expect(zoo.source, ZooSource.local);
      for (final h in roster.rules.habits.take(5)) {
        zoo.habit(h.key);
      }
      expect(zoo.readyEgg, isNotNull);
      final hatched = await zoo.hatch(zoo.readyEgg!.id);
      expect(hatched, isNotNull);
      expect(zoo.paired?.id, hatched!.daemonId);
      await zoo.flush();
      final again = controller();
      addTearDown(again.dispose);
      again.bind('guest');
      await pumpEventQueue();
      expect(again.paired?.id, hatched.daemonId);
    });

    test('first sign-in seeds the guest zoo once', () async {
      final guest = controller();
      addTearDown(guest.dispose);
      guest.bind('guest');
      await pumpEventQueue();
      guest.habit('turn');
      guest.habit('split');
      await guest.flush();

      final remote = FakeZooTransport();
      final account = controller();
      addTearDown(account.dispose);
      account.bind('account:u1', remote: remote);
      await pumpEventQueue();
      await account.flush();
      expect(remote.batches.single.single['op'], 'zoo.seed');
      expect(account.zoo.habits, ['turn', 'split']);

      final later = controller();
      addTearDown(later.dispose);
      later.bind('account:u2', remote: remote);
      await pumpEventQueue();
      await later.flush();
      expect(remote.batches, hasLength(1), reason: 'sent once');
    });

    test(
      'habits are sent once, optimistically, and the server grants the egg',
      () async {
        final remote = FakeZooTransport();
        final zoo = controller();
        addTearDown(zoo.dispose);
        zoo.bind('account:u1', remote: remote);
        await pumpEventQueue();
        for (final h in roster.rules.habits.take(5)) {
          zoo.habit(h.key);
          zoo.habit(h.key);
        }
        expect(zoo.habitsDone, 5);
        expect(
          zoo.readyEgg,
          isNull,
          reason: 'the egg is the server\'s to grant',
        );
        await zoo.flush();
        expect(
          remote.batches
              .expand((b) => b)
              .where((op) => op['op'] == 'zoo.habit'),
          hasLength(5),
        );
        expect(zoo.readyEgg?.kind, 'first');
        final hatched = await zoo.hatch(zoo.readyEgg!.id);
        expect(hatched?.daemonId, remote.zoo.daemons.single.id);
        expect(zoo.paired?.id, hatched!.daemonId);
        expect(zoo.revision, remote.revision);
      },
    );

    test('zoo_changed refetches only when it is news', () async {
      final remote = FakeZooTransport()..revision = 3;
      final zoo = controller();
      addTearDown(zoo.dispose);
      zoo.bind('account:u1', remote: remote);
      await pumpEventQueue();
      expect(remote.fetches, 1);
      zoo.pushed(3);
      await pumpEventQueue();
      expect(remote.fetches, 1);
      remote
        ..zoo = const Zoo(
          daemons: [ZooDaemon(id: 'fzf', hatchedAt: '', egg: 'first')],
          pair: 'fzf',
        )
        ..revision = 4;
      zoo.pushed(4);
      await pumpEventQueue();
      expect(remote.fetches, 2);
      expect(zoo.paired?.id, 'fzf');
      // An older answer never replaces a newer one.
      remote
        ..zoo = Zoo.empty
        ..revision = 2;
      zoo.pushed(null);
      await pumpEventQueue();
      expect(zoo.paired?.id, 'fzf');
    });

    test('a harnessd without a zoo falls back to the local zoo', () async {
      final remote = FakeZooTransport(available: false);
      final zoo = controller();
      addTearDown(zoo.dispose);
      zoo.bind('account:u1', remote: remote);
      await pumpEventQueue();
      expect(zoo.source, ZooSource.local);
      zoo.habit('turn');
      await zoo.flush();
      remote.available = true;
      zoo.pushed(1);
      await pumpEventQueue();
      await zoo.flush();
      expect(zoo.isAccount, isTrue);
      expect(remote.zoo.habits, ['turn'], reason: 'seeded on first answer');
    });

    testWidgets('a failed read retries and stays hidden meanwhile', (
      tester,
    ) async {
      final remote = FakeZooTransport()..failWith = StateError('offline');
      final zoo = controller();
      addTearDown(zoo.dispose);
      zoo.bind('account:u1', remote: remote);
      await tester.pump();
      expect(zoo.loaded, isFalse);
      remote.failWith = null;
      await tester.pump(const Duration(seconds: 6));
      expect(zoo.loaded, isTrue);
    });

    testWidgets('a failed write is kept and retried', (tester) async {
      final remote = FakeZooTransport();
      final zoo = controller();
      addTearDown(zoo.dispose);
      zoo.bind('account:u1', remote: remote);
      await tester.pump();
      remote.failWith = StateError('offline');
      zoo.habit('turn');
      await tester.pump();
      expect(remote.batches, isEmpty);
      remote.failWith = null;
      await tester.pump(const Duration(seconds: 6));
      expect(remote.zoo.habits, ['turn']);
    });

    test('days are local dates; the third reports the habit', () async {
      var day = DateTime(2026, 9, 24, 23);
      final zoo = ZooController(storage: storage, now: () => day);
      addTearDown(zoo.dispose);
      zoo.bind('guest');
      await pumpEventQueue();
      zoo.noteDay();
      zoo.noteDay();
      day = DateTime(2026, 9, 25, 1);
      zoo.noteDay();
      expect(zoo.zoo.habits, isEmpty);
      day = DateTime(2026, 9, 27, 8);
      zoo.noteDay();
      expect(zoo.zoo.habits, ['days']);
    });

    test('a new scope forgets the previous account at once', () async {
      final remote = FakeZooTransport()
        ..zoo = const Zoo(
          daemons: [ZooDaemon(id: 'vim', hatchedAt: '', egg: 'first')],
          pair: 'vim',
        );
      final zoo = controller();
      addTearDown(zoo.dispose);
      zoo.bind('account:u1', remote: remote);
      await pumpEventQueue();
      expect(zoo.paired?.id, 'vim');
      zoo.bind('account:u2', remote: FakeZooTransport()..gate = Completer());
      expect(zoo.loaded, isFalse);
      expect(zoo.paired, isNull);
    });
  });
}
