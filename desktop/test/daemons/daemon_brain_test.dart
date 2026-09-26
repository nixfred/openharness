// The window's half of the pair brain (daemons/BRAIN.md): what it hears from
// this computer's harnessd, and what it sends back.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness/core/local_key_value_store.dart';
import 'package:harness/daemons/daemon_brain.dart';
import 'package:harness/daemons/roster.dart';

class _Memory implements LocalKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  late List<(String, Map<String, dynamic>)> sent;
  late bool reachable;
  late _Memory storage;
  late DaemonBrain brain;

  setUp(() {
    sent = [];
    reachable = true;
    storage = _Memory();
    brain = DaemonBrain(
      send: (type, payload) {
        if (!reachable) return false;
        sent.add((type, payload));
        return true;
      },
      storage: storage,
      random: Random(4),
    );
  });
  tearDown(() => brain.dispose());

  test('daemon_state makes the brain active and carries every machine', () {
    expect(brain.active, isFalse);
    brain.receive('daemon_state', {
      'pair': 'tim',
      'needs': [
        {
          'machineId': 'office',
          'machine': 'office',
          'agentId': 'a1',
          'name': 'migration',
          'requestId': 'r9',
          'question': 'Run npm run migrate?',
          'id': 'say1',
          'actions': [
            {'key': 'y', 'label': 'run it', 'choice': '1'},
            {'key': 'N', 'label': 'not now'},
          ],
        },
        {'machineId': 'broken'},
      ],
      'working': true,
      'failing': [
        {'name': 'billing', 'reason': 'exit 1'},
      ],
      'machines': [
        {'machineId': 'm2', 'name': 'm2', 'status': 'ok'},
        {'machineId': 'office', 'name': 'office', 'status': 'unreachable'},
      ],
    });
    final state = brain.state!;
    expect(brain.active, isTrue);
    expect(state.pair, 'tim');
    expect(state.needs.single.key, 'office/a1#r9');
    expect(state.needs.single.actions.map((a) => (a.key, a.choice)), [
      ('y', '1'),
      ('n', 'N'),
    ]);
    expect(state.working, isTrue);
    expect(state.failing, ['billing: exit 1']);
    expect(state.machines.last, ('office', 'unreachable'));
  });

  test('says, unsays and briefs are passed on', () async {
    final said = <DaemonSay>[];
    final unsaid = <String>[];
    brain.said.listen(said.add);
    brain.unsaid.listen(unsaid.add);
    brain.receive('daemon_say', {
      'id': 's1',
      'about': 'office/a1',
      'mood': 'need',
      'line': 'codex@office wants to run the migration. [y/n]',
      'actions': [
        {'key': 'y', 'label': 'yes', 'choice': 'y'},
      ],
      'ttlMs': 60000,
    });
    brain.receive('daemon_say', {'id': 's2', 'line': '   '});
    brain.receive('daemon_unsay', {'id': 's1', 'reason': 'answered'});
    brain.receive('daemon_brief', {
      'desk': 'd',
      'line': 'welcome back. 2 done, 1 waiting 40m.',
      'items': [
        {
          'id': 'i1',
          'kind': 'waiting',
          'machine': 'office',
          'line': 'migration waits 40m',
        },
      ],
    });
    expect(said.single.mood, DaemonMood.need);
    expect(said.single.ttl, const Duration(minutes: 1));
    expect(unsaid, ['s1']);
    expect(brain.brief!.line, startsWith('welcome back.'));
    expect(brain.brief!.items.single.machine, 'office');
  });

  test('an answer is one daemon_act; a failed one is worded', () async {
    final errors = <String>[];
    brain.errors.listen(errors.add);
    expect(brain.act('s1', '1'), isTrue);
    final (type, payload) = sent.single;
    expect(type, 'daemon_act');
    expect(payload['id'], 's1');
    expect(payload['choice'], '1');
    final requestId = payload['requestId'] as String;
    brain.receive('daemon_act_result', {
      'requestId': 'someone-else',
      'ok': false,
      'error': 'GONE',
    });
    expect(errors, isEmpty, reason: 'not an answer this window gave');
    brain.receive('daemon_act_result', {
      'requestId': requestId,
      'id': 's1',
      'ok': false,
      'error': 'STALE_QUESTION',
      'detail': 'The dialog changed before the answer; nothing was typed.',
    });
    expect(errors, [
      'The dialog changed before the answer; nothing was typed.',
    ]);
    brain.act('s2', 'n');
    brain.receive('daemon_act_result', {
      'requestId': sent.last.$2['requestId'],
      'ok': false,
      'error': 'MACHINE_UNREACHABLE',
    });
    expect(errors.last, 'that machine is unreachable.');
    reachable = false;
    expect(brain.act('s3', 'y'), isFalse);
    expect(errors.last, 'harnessd is not reachable.');
  });

  test('presence names a stable desk, and a guest names its pair', () async {
    await brain.presence(active: false);
    await brain.presence(
      active: true,
      away: const Duration(minutes: 40),
      pair: 'tim',
    );
    expect(sent.map((s) => s.$1), ['daemon_presence', 'daemon_presence']);
    expect(sent[0].$2, {'active': false, 'desk': sent[1].$2['desk']});
    expect(sent[1].$2['awayMs'], 40 * 60 * 1000);
    expect(sent[1].$2['pair'], 'tim');
    final again = DaemonBrain(send: (_, _) => true, storage: storage);
    addTearDown(again.dispose);
    expect(await again.desk(), sent[0].$2['desk']);
  });
}
