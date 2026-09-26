// The window's half of the pair brain (daemons/BRAIN.md): what it hears from
// this computer's harnessd, and what it sends back. Frames are the shapes
// cli/src/pair/protocol.ts and brain.ts send.
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
  late DateTime now;

  setUp(() {
    sent = [];
    reachable = true;
    storage = _Memory();
    now = DateTime(2026, 9, 26, 9);
    brain = DaemonBrain(
      send: (type, payload) {
        if (!reachable) return false;
        sent.add((type, payload));
        return true;
      },
      storage: storage,
      random: Random(4),
      now: () => now,
    );
  });
  tearDown(() => brain.dispose());

  test('daemon_state: every machine, the +n, asks and what it did', () {
    expect(brain.active, isFalse);
    brain.receive('daemon_state', {
      'pair': 'tim',
      'needs': [
        {
          'machineId': 'office',
          'machine': 'office',
          'agentId': 'a1',
          'name': 'migration',
          'engine': 'codex',
          'requestId': 'r9',
          'question': 'Run npm run migrate?',
          'options': ['1. Yes', '3. No'],
          'deny': false,
          'allow': true,
          'since': 1790000000000,
          'id': 'need:office:e:1',
          'line': '[y/n/g] migration@office: Run npm run migrate?',
          'actions': [
            {'key': 'y', 'label': 'Yes', 'choice': '1. Yes'},
            {'key': 'N', 'label': 'No'},
          ],
        },
        {'machineId': 'broken'},
      ],
      'working': 2,
      'failing': [
        {
          'machineId': 'm',
          'machine': 'laptop',
          'agentId': 'b1',
          'name': 'billing',
          'reason': 'exit 1',
        },
      ],
      'machines': [
        {'machineId': 'm', 'name': 'laptop', 'status': 'ok', 'local': true},
        {'machineId': 'office', 'name': 'office', 'status': 'asleep'},
        {'machineId': 'studio', 'name': 'studio', 'status': 'connecting'},
      ],
      'done': {
        'count': 3,
        'last': [
          {
            'machineId': 'office',
            'machine': 'office',
            'agentId': 'a2',
            'name': 'api@office',
            'recap': 'tests pass.',
            'at': 1790000000000,
          },
        ],
      },
      'asks': [
        {
          'id': 'ask:7',
          'line': '[y/n] start codex in ~/api?',
          'actions': [
            {'key': 'y', 'label': 'do it', 'choice': 'y'},
            {'key': 'n', 'label': 'skip', 'choice': 'n'},
          ],
        },
      ],
      'acted': [
        {
          'machineId': 'office',
          'machine': 'office',
          'agentId': 'a3',
          'name': 'web@office',
          'by': 'rule',
          'action': 'answer',
          'text': 'answered "1. Yes"',
          'at': 1790000000000,
        },
      ],
    });
    final state = brain.state!;
    expect(brain.active, isTrue);
    expect(brain.paired, isTrue);
    expect(state.pair, 'tim');
    final need = state.needs.single;
    expect(need.key, 'office/a1#r9');
    expect(need.harness, 'office/a1');
    expect(need.sayId, 'need:office:e:1');
    expect(need.line, startsWith('[y/n/g] '));
    expect(need.since, DateTime.fromMillisecondsSinceEpoch(1790000000000));
    expect(need.actions.map((a) => (a.key, a.choice)), [
      ('y', '1. Yes'),
      ('n', 'N'),
    ]);
    expect(state.working, isTrue);
    expect(state.workingCount, 2, reason: 'a count, not a flag');
    expect(state.failing.single.reason, 'exit 1');
    expect(state.machines.map((m) => (m.name, m.status, m.away)), [
      ('laptop', 'ok', false),
      ('office', 'asleep', true),
      ('studio', 'connecting', false),
    ]);
    expect(state.doneCount, 3);
    expect(state.doneLast.single.line, 'api@office finished: tests pass.');
    expect(state.asks.single.id, 'ask:7');
    expect(state.acted.single.line, 'rule: web@office answered "1. Yes"');
    // Pairing off: the roster's lines again.
    brain.receive('daemon_state', {
      'pair': null,
      'needs': [],
      'working': 0,
      'failing': [],
      'machines': [],
      'done': {'count': 0, 'last': []},
      'asks': [],
      'acted': [],
    });
    expect(brain.active, isTrue);
    expect(brain.paired, isFalse);
  });

  test('says carry what they are about and their mood; unsays and briefs '
      'are passed on', () async {
    final said = <DaemonSay>[];
    final unsaid = <String>[];
    brain.said.listen(said.add);
    brain.unsaid.listen(unsaid.add);
    brain.receive('daemon_say', {
      'id': 'need:office:e:1',
      'about': {'machineId': 'office', 'agentId': 'a1', 'requestId': 'r1'},
      'mood': 'need',
      'line': '[y/n/g] api@office Bash: npm test',
      'actions': [
        {'key': 'y', 'label': 'Yes', 'choice': '1. Yes'},
        {'key': 'n', 'label': 'No', 'choice': '3. No'},
        {'key': 'g', 'label': 'open', 'choice': 'open'},
      ],
      'ttlMs': 5200,
    });
    brain.receive('daemon_say', {'id': 's2', 'line': '   '});
    brain.receive('daemon_unsay', {
      'id': 'need:office:e:1',
      'reason': 'answered',
    });
    final say = said.single;
    expect(say.mood, DaemonSayMood.need);
    expect(say.aboutKey, 'office/a1');
    expect(say.about!.requestId, 'r1');
    expect(say.ttl, const Duration(milliseconds: 5200));
    expect(unsaid, ['need:office:e:1']);
    // Moods map to faces as BRAIN.md draws them.
    expect(DaemonSayMood.auto.face, DaemonMood.done);
    expect(DaemonSayMood.say.face, DaemonMood.idle);
    expect(DaemonSayMood.ask.face, DaemonMood.need);
    expect(
      DaemonSay.fromJson({
        'id': 'b',
        'line': 'x',
        'about': {'machineId': 'm', 'agentId': ''},
      })!.aboutKey,
      isNull,
      reason: 'about no harness in particular',
    );
    brain.receive('daemon_brief', {
      'desk': 'd',
      'line': 'reattached. 2 done, 1 waiting 40m.',
      'items': [
        {
          'id': 'brief:office:r1:1',
          'kind': 'waiting',
          'machineId': 'office',
          'machine': 'office',
          'agentId': 'a1',
          'name': 'migration',
          'line': '[y/n/g] migration@office: Run npm run migrate? (40m)',
          'actions': [
            {'key': 'y', 'label': 'Yes', 'choice': '1. Yes'},
            {'key': 'g', 'label': 'open', 'choice': 'open'},
          ],
        },
        for (var i = 0; i < 6; i++)
          {
            'id': 'done:$i',
            'kind': 'done',
            'machineId': 'm',
            'machine': 'laptop',
            'line': 'web finished.',
          },
      ],
    });
    final brief = brain.brief!;
    expect(brief.line, startsWith('reattached.'));
    expect(brief.items, hasLength(5), reason: 'at most five');
    expect(brief.items.first.about?.key, 'office/a1');
    expect(brief.items.first.actions.map((a) => a.key), ['y', 'g']);
    expect(brief.items.last.about, isNull);
    expect(brief.keysLive(now), isTrue);
    expect(brief.keysLive(now.add(const Duration(seconds: 61))), isFalse);
  });

  test('keys first: a line is split into its keys and the rest', () {
    const y = (key: 'y', label: 'Yes', choice: '1');
    const g = (key: 'g', label: 'open', choice: 'open');
    final split = splitDaemonKeys('[y/g] api: npm test', const [y, g]);
    expect(split.keys, ['y', 'g']);
    expect(split.rest, 'api: npm test');
    // A line with answers that does not start with them gets them first.
    final put = splitDaemonKeys('api: npm test', const [g, y]);
    expect(put.keys, ['y', 'g']);
    expect(put.rest, 'api: npm test');
    final none = splitDaemonKeys('all quiet.', const []);
    expect(none.keys, isEmpty);
    expect(none.rest, 'all quiet.');
    expect(daemonKeysPrefix(const [g, y]), '[y/g] ');
  });

  test('an answer is one daemon_act; [g] comes back as a harness to open; '
      'a failed one is worded', () async {
    final errors = <String>[];
    final opens = <DaemonAbout>[];
    brain.errors.listen(errors.add);
    brain.opens.listen(opens.add);
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
    brain.act('s2', 'g');
    brain.receive('daemon_act_result', {
      'requestId': sent.last.$2['requestId'],
      'id': 's2',
      'ok': true,
      'open': {'machineId': 'office', 'agentId': 'a1'},
    });
    expect(opens.single.key, 'office/a1');
    brain.act('s2', 'n');
    brain.receive('daemon_act_result', {
      'requestId': sent.last.$2['requestId'],
      'ok': false,
      'error': 'MACHINE_UNREACHABLE',
    });
    expect(errors.last, 'that machine is unreachable.');
    brain.act('ask:1', 'y');
    brain.receive('daemon_act_result', {
      'requestId': sent.last.$2['requestId'],
      'ok': false,
      'error': 'AUTONOMY_WATCH',
    });
    expect(errors.last, contains('only watches'));
    reachable = false;
    expect(brain.act('s3', 'y'), isFalse);
    expect(errors.last, 'harnessd is not reachable.');
  });

  test('talk: daemon_talk, then started, resumed or sent; its answer comes '
      'back as a say', () {
    var changes = 0;
    brain.addListener(() => changes++);
    expect(brain.talkTo('   '), isFalse);
    expect(brain.talkTo('what needs me?'), isTrue);
    expect(sent.single.$1, 'daemon_talk');
    expect(sent.single.$2['text'], 'what needs me?');
    expect(brain.talkPhase, DaemonTalkPhase.waking);
    final requestId = sent.single.$2['requestId'];
    brain.receive('daemon_talk_result', {'requestId': 'other', 'ok': true});
    expect(brain.talkPhase, DaemonTalkPhase.waking);
    brain.receive('daemon_talk_result', {
      'requestId': requestId,
      'ok': true,
      'agentId': 'pair-1',
      'started': true,
    });
    expect(brain.talkPhase, DaemonTalkPhase.started);
    expect(brain.pairAgentId, 'pair-1');
    brain.receive('daemon_say', {
      'id': 'say:1',
      'about': {'machineId': 'm', 'agentId': ''},
      'mood': 'say',
      'line': 'api waits on you, 40m.',
      'actions': [],
      'ttlMs': 30000,
    });
    expect(brain.talkPhase, DaemonTalkPhase.idle);
    expect(brain.talk, [
      (you: true, text: 'what needs me?'),
      (you: false, text: 'api waits on you, 40m.'),
    ]);
    brain.talkTo('and office?');
    brain.receive('daemon_talk_result', {
      'requestId': sent.last.$2['requestId'],
      'ok': true,
      'agentId': 'pair-1',
      'resumed': true,
    });
    expect(brain.talkPhase, DaemonTalkPhase.resumed);
    brain.talkTo('thanks');
    brain.receive('daemon_talk_result', {
      'requestId': sent.last.$2['requestId'],
      'ok': false,
      'error': 'NO_ENGINE',
    });
    expect(brain.talkPhase, DaemonTalkPhase.failed);
    expect(brain.talkError, contains('Claude Code or Codex'));
    reachable = false;
    brain.talkTo('hello?');
    expect(brain.talkError, 'harnessd is not reachable.');
    expect(changes, greaterThan(4));
    for (var i = 0; i < 10; i++) {
      brain.talkTo('$i');
    }
    expect(brain.talk, hasLength(DaemonBrain.talkKept));
  });

  test('presence: a stable desk, the pane in front (null clears it), '
      'doneSeen, and a guest names its pair and dial', () async {
    await brain.presence(active: false);
    await brain.presence(
      active: true,
      away: const Duration(minutes: 40),
      pair: 'tim',
      autonomy: 'watch',
      focusMachineId: 'm',
      focusAgentId: 'a3',
    );
    expect(sent.map((s) => s.$1), ['daemon_presence', 'daemon_presence']);
    final desk = sent[1].$2['desk'];
    expect(sent[0].$2, {
      'active': false,
      'desk': desk,
      'focusMachineId': null,
      'focusAgentId': null,
    });
    expect(sent[1].$2['awayMs'], 40 * 60 * 1000);
    expect(sent[1].$2['pair'], 'tim');
    expect(sent[1].$2['autonomy'], 'watch');
    expect(sent[1].$2['focusAgentId'], 'a3');
    await brain.focus(machineId: 'm', agentId: null);
    expect(sent.last.$2, {
      'desk': desk,
      'focusMachineId': null,
      'focusAgentId': null,
    }, reason: 'a focus change only: no active, nothing else');
    await brain.doneSeen();
    expect(sent.last.$2, {'desk': desk, 'doneSeen': true});
    await brain.guest(pair: 'vim', autonomy: 'act-on-key');
    expect(sent.last.$2, {
      'desk': desk,
      'pair': 'vim',
      'autonomy': 'act-on-key',
    });
    final again = DaemonBrain(send: (_, _) => true, storage: storage);
    addTearDown(again.dispose);
    expect(await again.desk(), desk);
  });
}
