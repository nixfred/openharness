// The daemon's face: moods in the README's order, blinks only as answers,
// frames only while agents work, and one line of voice at a time. Every test
// runs in fake time and ends with no timer left: nothing runs on its own.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness/core/local_key_value_store.dart';
import 'package:harness/daemons/daemon_face.dart';
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

class _Clock {
  DateTime value = DateTime(2026, 9, 26, 9);
  DateTime call() => value;
}

void main() {
  late _Clock clock;
  late ZooController zoo;
  late DaemonFace face;

  Future<void> mount(
    WidgetTester tester, {
    String id = 'tim',
    String version = '2.0',
    Zoo? custom,
  }) async {
    clock = _Clock();
    final storage = _Memory();
    final seeded =
        custom ??
        Zoo(
          daemons: [
            ZooDaemon(
              id: id,
              hatchedAt: '2026-09-26T09:00:00Z',
              egg: 'first',
              version: version,
              // Bond and version follow xp: 0.1, 1.0 at level 2, 2.0 at 4.
              xp: const {'0.1': 0, '1.0': 150, '2.0': 600}[version]!,
            ),
          ],
          pair: id,
          habits: const ['turn', 'split', 'find', 'machine', 'store'],
          firstEgg: true,
        );
    storage.values[ZooController.localZooKey] = jsonEncode({
      'zoo': seeded.toJson(),
      'seeded': true,
    });
    zoo = ZooController(storage: storage, now: clock.call);
    face = DaemonFace(zoo, now: clock.call);
    addTearDown(() {
      face.dispose();
      zoo.dispose();
    });
    zoo.bind('guest');
    await tester.pump();
    face.sync(const DaemonWatch());
  }

  /// Advance the injected clock and fake time together.
  Future<void> pass(WidgetTester tester, Duration d) async {
    clock.value = clock.value.add(d);
    await tester.pump(d);
  }

  testWidgets('nothing shows until the zoo has loaded', (tester) async {
    final zoo = ZooController(storage: _Memory());
    final face = DaemonFace(zoo);
    addTearDown(() {
      face.dispose();
      zoo.dispose();
    });
    expect(face.visible, isFalse);
    expect(face.glyph, '');
    zoo.bind('guest');
    await tester.pump();
    expect(face.visible, isTrue);
    expect(face.glyph, r'\_O_/');
  });

  testWidgets('moods follow the README precedence', (tester) async {
    await mount(tester);
    expect(face.mood, DaemonMood.idle);
    expect(face.glyph, r'\[o|o]/');
    face.sync(const DaemonWatch(failing: true));
    expect(face.mood, DaemonMood.fail);
    face.sync(const DaemonWatch(failing: true, working: true));
    expect(face.mood, DaemonMood.work);
    face.nap();
    expect(face.mood, DaemonMood.nap);
    expect(face.glyph, r'\[-|-]/z');
    face.sync(const DaemonWatch(working: true, needIds: {'m/a'}));
    expect(face.mood, DaemonMood.need, reason: 'need wins and wakes a nap');
    expect(face.napping, isFalse);
    face.boop();
    expect(face.mood, DaemonMood.boop);
    await pass(tester, const Duration(milliseconds: 900));
    expect(face.mood, DaemonMood.need);
    face.sync(const DaemonWatch());
    await pass(tester, const Duration(seconds: 11));
  });

  testWidgets('restored state is a baseline, then a new need speaks once', (
    tester,
  ) async {
    clock = _Clock();
    await mount(tester);
    // The mount's first sync was the baseline; a restored question is not news
    // when it was already there at that point.
    face.sync(const DaemonWatch(needIds: {'m/old'}));
    expect(face.voice, isNotNull, reason: 'a question after the baseline');
    await pass(tester, const Duration(seconds: 6));
    expect(face.voice, isNull);
    face.sync(const DaemonWatch());
    face.sync(const DaemonWatch(needIds: {'m/old'}));
    expect(face.voice, isNull, reason: 'a reconnect re-announcing it is not');
    face.sync(const DaemonWatch());
    await pass(tester, const Duration(seconds: 11));
  });

  testWidgets('a finished turn: ack blink, done for 3 s, once per 20 s', (
    tester,
  ) async {
    await mount(tester);
    face.sync(const DaemonWatch(turns: {'m': 4}));
    expect(face.mood, DaemonMood.idle, reason: 'a first count is a baseline');
    face.sync(const DaemonWatch(turns: {'m': 5}));
    expect(face.mood, DaemonMood.done);
    expect(
      face.voice,
      'tim: claude finished the refactor. 3 files, tests pass.',
    );
    expect(face.lid, isNull);
    await pass(tester, const Duration(milliseconds: 170));
    expect(face.lid, '-');
    expect(face.glyph, r'\[-|-]/');
    await pass(tester, const Duration(milliseconds: 130));
    expect(face.lid, isNull);
    await pass(tester, const Duration(seconds: 3));
    expect(face.mood, DaemonMood.idle);
    face.sync(const DaemonWatch(turns: {'m': 7}));
    expect(face.mood, DaemonMood.idle, reason: 'the 20 s cooldown');
    await pass(tester, const Duration(seconds: 20));
    face.sync(const DaemonWatch(turns: {'m': 8}));
    expect(face.mood, DaemonMood.done);
    await pass(tester, const Duration(seconds: 11));
  });

  testWidgets('a failed turn holds fail for 4.2 s', (tester) async {
    await mount(tester);
    face.sync(const DaemonWatch(fails: {'m': 0}));
    face.sync(const DaemonWatch(fails: {'m': 1}));
    expect(face.mood, DaemonMood.fail);
    expect(face.glyph, r'\[x|x]/');
    await pass(tester, const Duration(milliseconds: 4100));
    expect(face.mood, DaemonMood.fail);
    await pass(tester, const Duration(milliseconds: 200));
    expect(face.mood, DaemonMood.idle);
    await pass(tester, const Duration(seconds: 11));
  });

  testWidgets('work frames run only while working, and stop for Reduce '
      'Motion and background windows', (tester) async {
    await mount(tester);
    face.sync(const DaemonWatch(working: true));
    final frames = <String>{face.glyph};
    for (var i = 0; i < 4; i++) {
      await pass(tester, const Duration(milliseconds: 150));
      frames.add(face.glyph);
    }
    expect(frames, {r'\[=|=]/', '|[=|=]|', r'/[=|=]\', '-[=|=]-'});
    face.setEnvironment(foreground: true, reduceMotion: true);
    final still = face.glyph;
    await pass(tester, const Duration(seconds: 1));
    expect(face.glyph, still);
    expect(face.mood, DaemonMood.work, reason: 'the face still changes');
    face.setEnvironment(foreground: false, reduceMotion: false);
    await pass(tester, const Duration(seconds: 1));
    expect(face.glyph, still);
    face.setEnvironment(foreground: true, reduceMotion: false);
    face.sync(const DaemonWatch());
    expect(face.glyph, r'\[o|o]/');
    await pass(tester, const Duration(seconds: 3));
  });

  testWidgets('younger versions borrow the baton while working', (
    tester,
  ) async {
    await mount(tester, version: '0.1');
    face.sync(const DaemonWatch(working: true));
    expect(face.glyph, '[==] |');
    await pass(tester, const Duration(milliseconds: 130));
    expect(face.glyph, '[==] /');
    face.sync(const DaemonWatch());
    expect(face.glyph, '[oo]');
  });

  testWidgets('coming back after 15 minutes: back, then a slow blink', (
    tester,
  ) async {
    await mount(tester);
    face.setEnvironment(foreground: false, reduceMotion: false);
    await pass(tester, const Duration(minutes: 16));
    face.setEnvironment(foreground: true, reduceMotion: false);
    expect(face.mood, DaemonMood.back);
    expect(face.voice, startsWith('tim: welcome back.'));
    await pass(tester, const Duration(milliseconds: 1300));
    expect(face.mood, DaemonMood.idle);
    await pass(tester, const Duration(milliseconds: 130));
    expect(face.lid, '_');
    await pass(tester, const Duration(milliseconds: 110));
    expect(face.lid, '-');
    await pass(tester, const Duration(milliseconds: 300));
    expect(face.lid, '_');
    await pass(tester, const Duration(milliseconds: 110));
    expect(face.lid, isNull);
    await pass(tester, const Duration(seconds: 6));
    // A quick switch away is only a look.
    face.setEnvironment(foreground: false, reduceMotion: false);
    await pass(tester, const Duration(minutes: 1));
    face.setEnvironment(foreground: true, reduceMotion: false);
    expect(face.mood, DaemonMood.idle);
    expect(face.voice, isNull);
    await pass(tester, const Duration(milliseconds: 260));
    expect(face.lid, '-');
    await pass(tester, const Duration(milliseconds: 200));
  });

  testWidgets('looks blink at most once per 2.5 s and never while working', (
    tester,
  ) async {
    await mount(tester);
    face.look();
    expect(face.lid, '-');
    await pass(tester, const Duration(milliseconds: 200));
    face.look();
    expect(face.lid, isNull);
    await pass(tester, const Duration(milliseconds: 2500));
    face.sync(const DaemonWatch(working: true));
    face.look();
    expect(face.lid, isNull);
    expect(face.glyph, r'\[=|=]/');
    face.sync(const DaemonWatch());
    await pass(tester, const Duration(milliseconds: 200));
  });

  testWidgets('it never speaks within 2 s of a key or while a dialog is open', (
    tester,
  ) async {
    await mount(tester);
    var dialog = true;
    face.quiet = () => dialog;
    face.boop();
    expect(face.voice, isNull);
    await pass(tester, const Duration(seconds: 1));
    expect(face.voice, isNull);
    dialog = false;
    face.noteKey();
    await pass(tester, const Duration(milliseconds: 600));
    expect(face.voice, isNull);
    await pass(tester, const Duration(seconds: 2));
    expect(face.voice, "tim: hey. that's my status line.");
    await pass(tester, const Duration(milliseconds: 5200));
    expect(face.voice, isNull);
  });

  testWidgets('a stale line expires instead of speaking late', (tester) async {
    await mount(tester);
    face.quiet = () => true;
    face.boop();
    await pass(tester, const Duration(seconds: 12));
    face.quiet = () => false;
    await pass(tester, const Duration(seconds: 1));
    expect(face.voice, isNull);
  });

  testWidgets('nap lasts 15 minutes or until a boop', (tester) async {
    await mount(tester);
    face.nap();
    expect(face.glyph, r'\[-|-]/z');
    await pass(tester, const Duration(minutes: 15));
    expect(face.napping, isFalse);
    face.nap();
    face.boop();
    expect(face.napping, isFalse);
    await pass(tester, const Duration(seconds: 6));
  });

  testWidgets('the reveal withholds the hatchling until it ends', (
    tester,
  ) async {
    await mount(
      tester,
      custom: const Zoo(
        habits: ['turn', 'split', 'find', 'machine', 'store'],
        firstEgg: true,
        eggs: [ZooEgg(id: 'egg1', kind: 'first', grantedAt: '')],
      ),
    );
    expect(face.eggReady, isTrue);
    expect(face.glyph, r'\_o.o_/');
    face.beginReveal();
    final hatched = await zoo.hatch('egg1');
    expect(hatched, isNotNull);
    expect(zoo.paired?.id, hatched!.daemonId);
    expect(face.daemon, isNull);
    expect(face.glyph, r'\_o.o_/');
    expect(face.label, 'Hatching');
    expect(face.tooltip.contains(hatched.daemonId), isFalse);
    face.endReveal();
    final def = daemonRoster.byId(hatched.daemonId)!;
    expect(face.label, def.id);
    expect(face.glyph, isNot(r'\_o.o_/'));
    expect(face.voice, '${def.id}: ${def.first}');
    await pass(tester, const Duration(seconds: 6));
  });

  testWidgets('the nest shows habits done', (tester) async {
    await mount(tester, custom: const Zoo(habits: ['turn', 'split']));
    expect(face.glyph, r'~\_O_/~');
    expect(face.label, 'Egg');
    expect(face.detail, '2 of 5 habits');
    zoo.habit('find');
    zoo.habit('store');
    expect(face.glyph, r'\_.._/');
    zoo.habit('resume');
    expect(face.glyph, r'\_o.o_/');
    expect(face.eggReady, isTrue);
  });
  testWidgets('a new egg shows in the slot for a moment and is announced', (
    tester,
  ) async {
    // At 1.0 (150 xp), two days of turns (200 xp) stay below the next level.
    await mount(tester, version: '1.0');
    // A guest's 40th counted turn earns a turn egg; two days at the cap.
    clock.value = DateTime(2026, 9, 21, 12);
    zoo.recordTurns(20, machineId: 'm');
    await tester.pump(const Duration(seconds: 6));
    clock.value = DateTime(2026, 9, 22, 12);
    zoo.recordTurns(20, machineId: 'm');
    expect(zoo.zoo.eggs.single.kind, 'turn');
    expect(face.glyph, r'\_O_/');
    expect(face.voice, 'tim: a turn egg arrived. it waits in the nest.');
    expect(face.detail, contains('1 egg waiting'));
    await pass(tester, const Duration(seconds: 3));
    expect(face.glyph, '[o|o]', reason: 'the daemon comes back');
    await pass(tester, const Duration(seconds: 6));
  });

  testWidgets('a level-up is a slow blink and one line of changelog', (
    tester,
  ) async {
    await mount(tester, version: '0.1');
    clock.value = DateTime(2026, 9, 21, 12);
    // 20 turns + the day's 5 = 25 xp; two days reach level 1 (50 xp).
    zoo.recordTurns(20, machineId: 'm');
    await pass(tester, const Duration(seconds: 6));
    clock.value = DateTime(2026, 9, 22, 12);
    zoo.recordTurns(20, machineId: 'm');
    expect(zoo.paired!.bond, 1);
    expect(face.voice, 'tim: bond level 1.');
    await pass(tester, const Duration(milliseconds: 210));
    expect(face.lid, '_', reason: 'a slow blink');
    await pass(tester, const Duration(seconds: 6));
    // Days later, level 2 releases 1.0 and the slot draws it.
    for (var d = 23; d <= 27; d++) {
      clock.value = DateTime(2026, 9, d, 12);
      zoo.recordTurns(20, machineId: 'm');
      await pass(tester, const Duration(seconds: 6));
    }
    expect(zoo.paired!.version, '1.0');
    expect(face.glyph, '[o|o]');
    await pass(tester, const Duration(seconds: 6));
  });
}
