/// The window's half of the pair brain (`daemons/BRAIN.md`, "Frames" and
/// "As built"). harnessd senses every harness on every machine and thinks on
/// the computer you are at; this window hears what it decided and answers.
/// Frame shapes are `cli/src/pair/protocol.ts` and `cli/src/pair/brain.ts`.
///
/// In (local frames from this computer's own harnessd only):
///   `daemon_state { pair, needs[], working, failing[], machines[], done,
///     asks[], acted[] }`
///   `daemon_say { id, about, mood, line, actions[{key,label,choice}], ttlMs }`
///   `daemon_unsay { id, reason }`
///   `daemon_brief { desk, line, items[] }`
///   `daemon_act_result { requestId, id, ok, open?, error?, detail? }`
///   `daemon_talk_result { requestId, ok, agentId?, started? | resumed? |
///     sent?, error?, detail? }`
/// Out (only on the socket bound to this computer's harnessd):
///   `daemon_act { requestId, id, choice }`
///   `daemon_talk { requestId, text }`
///   `daemon_presence { active?, awayMs?, desk, pair?, autonomy?,
///     focusMachineId?, focusAgentId?, doneSeen? }`: the pane in front of you
///     is never spoken about
///
/// An older harnessd sends none of these; the face then keeps the roster's
/// lines and the window's own view of its harnesses.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/local_key_value_store.dart';
import 'roster.dart';

typedef DaemonAction = ({String key, String label, String choice});

List<DaemonAction> _actions(Object? raw) => [
  for (final a in raw is List ? raw : const [])
    if (a is Map &&
        a['key'] is String &&
        (a['key'] as String).isNotEmpty &&
        a['label'] is String)
      (
        key: (a['key'] as String).toLowerCase(),
        label: a['label'] as String,
        choice: a['choice'] is String
            ? a['choice'] as String
            : a['key'] as String,
      ),
];

String _str(Object? value) => value is String ? value : '';
String? _opt(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
int _int(Object? value) => value is num ? value.toInt() : 0;
DateTime? _at(Object? value) => value is num
    ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
    : null;

/// The keys a line offers, first, as the brain writes them (`voice.ts`
/// `keysPrefix`): `[y/n/g] `, in that order, only the ones offered.
String daemonKeysPrefix(List<DaemonAction> actions) {
  final keys = [
    for (final k in const ['y', 'n', 'g'])
      if (actions.any((a) => a.key == k)) k,
  ];
  return keys.isEmpty ? '' : '[${keys.join('/')}] ';
}

final _keysAtStart = RegExp(r'^\[([a-z](?:/[a-z])*)\] ');

/// A line split into the keys it starts with and the rest: `[y/n/g] api:
/// npm test` is `(['y','n','g'], 'api: npm test')`. A line that offers
/// answers but does not start with its keys gets them put first, so a key is
/// always where the eye starts.
({List<String> keys, String rest}) splitDaemonKeys(
  String line,
  List<DaemonAction> actions,
) {
  final match = _keysAtStart.firstMatch(line);
  if (match != null) {
    return (keys: match.group(1)!.split('/'), rest: line.substring(match.end));
  }
  final prefix = daemonKeysPrefix(actions);
  if (prefix.isEmpty) return (keys: const [], rest: line);
  return (keys: prefix.substring(1, prefix.length - 2).split('/'), rest: line);
}

/// What a line is about: a harness on a machine, and the question on it.
@immutable
class DaemonAbout {
  const DaemonAbout(this.machineId, this.agentId, {this.requestId});
  final String machineId, agentId;
  final String? requestId;

  /// `machineId/agentId`, the window's id for a harness; null when the line
  /// is about no harness in particular (a return, a batch of proposals).
  String? get key =>
      machineId.isEmpty || agentId.isEmpty ? null : '$machineId/$agentId';

  static DaemonAbout? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return DaemonAbout(
      _str(raw['machineId']),
      _str(raw['agentId']),
      requestId: _opt(raw['requestId']),
    );
  }
}

/// The mood a `daemon_say` was sent with (`protocol.ts` `DaemonMood`).
/// `auto` (a rule or the pair acted) is drawn like done, `say` (the pair
/// talking) like idle, `ask` (a proposal waiting for your key) like need.
enum DaemonSayMood {
  need,
  done,
  fail,
  back,
  auto,
  say,
  ask;

  static DaemonSayMood? named(Object? name) =>
      values.where((m) => m.name == name).firstOrNull;

  /// The face the line wants (BRAIN.md, "As built").
  DaemonMood get face => switch (this) {
    need || ask => DaemonMood.need,
    done || auto => DaemonMood.done,
    fail => DaemonMood.fail,
    back => DaemonMood.back,
    say => DaemonMood.idle,
  };
}

/// A harness waiting on you, as the brain sees it (on any machine).
@immutable
class DaemonNeed {
  const DaemonNeed({
    required this.machineId,
    required this.agentId,
    required this.requestId,
    this.machine = '',
    this.name = '',
    this.engine = '',
    this.question = '',
    this.deny = false,
    this.since,
    this.sayId,
    this.line,
    this.actions = const [],
  });
  final String machineId, agentId, requestId, machine, name, engine, question;
  final bool deny;
  final DateTime? since;

  /// Its line and keys, only while its line shows (the brain drops them
  /// after `ttlMs`; after that the need is listed for you to open).
  final String? sayId, line;
  final List<DaemonAction> actions;

  /// The same id the window gives a question it sees itself.
  String get key => '$machineId/$agentId#$requestId';

  /// `machineId/agentId`.
  String get harness => '$machineId/$agentId';

  static DaemonNeed? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final machineId = raw['machineId'], agentId = raw['agentId'];
    final requestId = raw['requestId'];
    if (machineId is! String || agentId is! String || requestId is! String) {
      return null;
    }
    return DaemonNeed(
      machineId: machineId,
      agentId: agentId,
      requestId: requestId,
      machine: _str(raw['machine']),
      name: _str(raw['name']),
      engine: _str(raw['engine']),
      question: _str(raw['question']),
      deny: raw['deny'] == true,
      since: _at(raw['since']),
      sayId: _opt(raw['id']),
      line: _opt(raw['line']),
      actions: _actions(raw['actions']),
    );
  }
}

/// One machine of the fleet. `asleep` (the account lists it offline) and
/// `unreachable` are calm facts, never a failure.
@immutable
class DaemonMachine {
  const DaemonMachine({
    required this.name,
    this.machineId = '',
    this.status = 'ok',
    this.local = false,
  });
  final String machineId, name;

  /// `ok`, `connecting`, `unreachable`, `asleep`, `unlinked`, `old`, `off`.
  final String status;
  final bool local;

  /// Something to say about it in the panel: everything but `ok` and a link
  /// still coming up.
  bool get away => status != 'ok' && status != 'connecting';

  static DaemonMachine? fromJson(Object? raw) {
    if (raw is! Map || raw['name'] is! String) return null;
    return DaemonMachine(
      machineId: _str(raw['machineId']),
      name: raw['name'] as String,
      status: _opt(raw['status']) ?? 'ok',
      local: raw['local'] == true,
    );
  }
}

/// How the panel says a machine that is not `ok`, calmly. `offline` is what
/// the window alone can tell: it cannot reach it.
String daemonMachineLine(String name, String status) => switch (status) {
  'asleep' => '$name is asleep. its harnesses wait.',
  'unreachable' => '$name is out of reach. its harnesses wait.',
  'unlinked' => '$name is not linked to this computer.',
  'old' => '$name runs an older harness. update it to see its harnesses.',
  'off' => '$name has pairing off.',
  _ => '$name is asleep or unreachable. its harnesses wait.',
};

/// A harness whose last turn failed, or that failed to start.
@immutable
class DaemonFailing {
  const DaemonFailing({
    this.machineId = '',
    this.machine = '',
    this.agentId = '',
    this.name = '',
    this.reason = '',
  });
  final String machineId, machine, agentId, name, reason;

  static DaemonFailing? fromJson(Object? raw) => raw is Map
      ? DaemonFailing(
          machineId: _str(raw['machineId']),
          machine: _str(raw['machine']),
          agentId: _str(raw['agentId']),
          name: _str(raw['name']),
          reason: _str(raw['reason']),
        )
      : null;
}

/// A turn that finished since you last looked (`daemon_state.done.last`).
@immutable
class DaemonDone {
  const DaemonDone({
    this.machineId = '',
    this.machine = '',
    this.agentId = '',
    this.name = '',
    this.recap,
    this.at,
  });
  final String machineId, machine, agentId, name;
  final String? recap;
  final DateTime? at;

  /// `api@office finished: tests pass.`
  String get line =>
      '$name finished${recap == null ? '.' : ': ${recap!.trim()}'}';

  static DaemonDone? fromJson(Object? raw) => raw is Map
      ? DaemonDone(
          machineId: _str(raw['machineId']),
          machine: _str(raw['machine']),
          agentId: _str(raw['agentId']),
          name: _str(raw['name']),
          recap: _opt(raw['recap']),
          at: _at(raw['at']),
        )
      : null;
}

/// A proposal waiting for your key (`daemon_state.asks`): the pair wants to
/// do something and the dial says to ask. Its keys work for ten minutes.
@immutable
class DaemonAsk {
  const DaemonAsk({
    required this.id,
    required this.line,
    this.actions = const [],
  });
  final String id, line;
  final List<DaemonAction> actions;

  static DaemonAsk? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String || raw['line'] is! String) {
      return null;
    }
    return DaemonAsk(
      id: raw['id'] as String,
      line: raw['line'] as String,
      actions: _actions(raw['actions']),
    );
  }
}

/// Something a rule or the pair did on its own, reported afterwards.
@immutable
class DaemonActed {
  const DaemonActed({
    this.machineId = '',
    this.machine = '',
    this.agentId = '',
    this.name = '',
    this.by = '',
    this.action = '',
    this.text = '',
    this.at,
  });
  final String machineId, machine, agentId, name;

  /// `rule` or `pair`.
  final String by;
  final String action, text;
  final DateTime? at;

  /// `rule: api@office answered "Yes"`, as the brain's `auto` line says it.
  String get line =>
      '$by: $name ${text.isNotEmpty ? text : action.isNotEmpty ? action : 'acted'}';

  static DaemonActed? fromJson(Object? raw) => raw is Map
      ? DaemonActed(
          machineId: _str(raw['machineId']),
          machine: _str(raw['machine']),
          agentId: _str(raw['agentId']),
          name: _str(raw['name']),
          by: _str(raw['by']),
          action: _str(raw['action']),
          text: _str(raw['text']),
          at: _at(raw['at']),
        )
      : null;
}

@immutable
class DaemonBrainState {
  const DaemonBrainState({
    this.pair,
    this.needs = const [],
    this.workingCount = 0,
    this.failing = const [],
    this.machines = const [],
    this.doneCount = 0,
    this.doneLast = const [],
    this.asks = const [],
    this.acted = const [],
  });

  /// The daemon the brain pairs with; null means "use the roster lines".
  final String? pair;
  final List<DaemonNeed> needs;

  /// Harnesses working (not waiting on a question), on every machine.
  final int workingCount;
  bool get working => workingCount > 0;
  final List<DaemonFailing> failing;
  final List<DaemonMachine> machines;

  /// Turns finished since you last looked (the `+n`), and the last few.
  final int doneCount;
  final List<DaemonDone> doneLast;

  /// Proposals waiting for your key.
  final List<DaemonAsk> asks;

  /// What a rule or the pair did on its own, newest first.
  final List<DaemonActed> acted;

  static List<T> _list<T>(Object? raw, T? Function(Object?) parse) => [
    for (final item in raw is List ? raw : const []) ?parse(item),
  ];

  static DaemonBrainState fromJson(Map raw) {
    final done = raw['done'] is Map ? raw['done'] as Map : const {};
    final working = raw['working'];
    return DaemonBrainState(
      pair: _opt(raw['pair']),
      needs: _list(raw['needs'], DaemonNeed.fromJson),
      workingCount: working is num
          ? max(0, working.toInt())
          : working == true
          ? 1
          : 0,
      failing: _list(raw['failing'], DaemonFailing.fromJson),
      machines: _list(raw['machines'], DaemonMachine.fromJson),
      doneCount: max(0, _int(done['count'])),
      doneLast: _list(done['last'], DaemonDone.fromJson),
      asks: _list(raw['asks'], DaemonAsk.fromJson),
      acted: _list(raw['acted'], DaemonActed.fromJson),
    );
  }
}

/// One line the brain wants said, maybe with answers.
@immutable
class DaemonSay {
  const DaemonSay({
    required this.id,
    required this.line,
    this.about,
    this.mood,
    this.actions = const [],
    this.ttl,
  });
  final String id, line;
  final DaemonAbout? about;
  final DaemonSayMood? mood;
  final List<DaemonAction> actions;
  final Duration? ttl;

  /// `machineId/agentId` of the harness it is about, if any.
  String? get aboutKey => about?.key;

  static DaemonSay? fromJson(Map raw) {
    final id = raw['id'], line = raw['line'];
    if (id is! String || line is! String || line.trim().isEmpty) return null;
    final ttl = raw['ttlMs'];
    return DaemonSay(
      id: id,
      line: line.trim(),
      about: DaemonAbout.fromJson(raw['about']),
      mood: DaemonSayMood.named(raw['mood']),
      actions: _actions(raw['actions']),
      ttl: ttl is num && ttl > 0 ? Duration(milliseconds: ttl.toInt()) : null,
    );
  }
}

/// One item of a brief: what waits on you (with its keys first), what
/// failed, a machine asleep or out of reach, what finished.
@immutable
class DaemonBriefItem {
  const DaemonBriefItem({
    required this.line,
    this.id = '',
    this.kind = '',
    this.machineId = '',
    this.machine = '',
    this.agentId,
    this.name,
    this.actions = const [],
  });
  final String id, kind, machineId, machine, line;
  final String? agentId, name;
  final List<DaemonAction> actions;

  /// The harness it is about, when it is about one.
  DaemonAbout? get about => agentId == null || machineId.isEmpty
      ? null
      : DaemonAbout(machineId, agentId!);

  static DaemonBriefItem? fromJson(Object? raw) {
    if (raw is! Map || raw['line'] is! String) return null;
    return DaemonBriefItem(
      id: _str(raw['id']),
      kind: _str(raw['kind']),
      machineId: _str(raw['machineId']),
      machine: _str(raw['machine']),
      agentId: _opt(raw['agentId']),
      name: _opt(raw['name']),
      line: raw['line'] as String,
      actions: _actions(raw['actions']),
    );
  }
}

@immutable
class DaemonBrief {
  const DaemonBrief({required this.line, this.items = const [], this.at});

  /// A brief's keys work this long (`brain.ts` `BRIEF_KEYS_MS`).
  static const keysFor = Duration(seconds: 60);

  /// At most this many items (`brief.ts` `BRIEF_ITEMS_MAX`).
  static const maxItems = 5;
  final String line;
  final List<DaemonBriefItem> items;

  /// When it arrived.
  final DateTime? at;

  /// Its answer keys still work (`[g]` opens a harness at any time).
  bool keysLive(DateTime now) => at != null && now.difference(at!) < keysFor;
}

/// Where the talk with the pair harness is.
enum DaemonTalkPhase {
  /// Nothing said yet, or it has answered.
  idle,

  /// Sent; harnessd is starting, resuming or reaching the pair harness.
  waking,

  /// The pair harness was started for these words (a new conversation).
  started,

  /// It was paused and has been resumed.
  resumed,

  /// It was running: the words went straight in.
  sent,

  /// The words did not reach it ([DaemonBrain.talkError] says why).
  failed,
}

/// One turn of the talk: yours, or the daemon's reply (`daemon_say`, `say`).
typedef DaemonTalkEntry = ({bool you, String text});

class DaemonBrain extends ChangeNotifier {
  DaemonBrain({
    required this.send,
    this.storage,
    Random? random,
    DateTime Function()? now,
  }) : _random = random ?? Random.secure(),
       _now = now ?? DateTime.now;

  /// Sends one frame on the socket bound to this computer's harnessd; false
  /// when there is none (then nothing is sent anywhere else).
  final bool Function(String type, Map<String, dynamic> payload) send;
  final LocalKeyValueStore? storage;
  final Random _random;
  final DateTime Function() _now;
  static const deskKey = 'daemons.desk.v1';

  /// The talk keeps this many turns for the panel.
  static const talkKept = 8;

  DaemonBrainState? _state;
  DaemonBrief? _brief;
  final _pendingActs = <String, String>{}; // requestId -> say id
  final _said = StreamController<DaemonSay>.broadcast(sync: true);
  final _unsaid = StreamController<String>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);
  final _opens = StreamController<DaemonAbout>.broadcast(sync: true);
  String? _desk;
  bool _disposed = false;

  String? _talkRequest;
  DaemonTalkPhase _talkPhase = DaemonTalkPhase.idle;
  String? _talkError;
  String? _pairAgentId;
  final _talk = <DaemonTalkEntry>[];

  /// Whether this harnessd has a brain (it has sent `daemon_state`).
  bool get active => _state != null;

  /// Whether a daemon is paired: its lines, its talk and its asks are live.
  bool get paired => _state?.pair != null;
  DaemonBrainState? get state => _state;
  DaemonBrief? get brief => _brief;
  DateTime now() => _now();
  Stream<DaemonSay> get said => _said.stream;
  Stream<String> get unsaid => _unsaid.stream;

  /// A failed answer, worded for the status line.
  Stream<String> get errors => _errors.stream;

  /// A harness to open: the brain answered `[g]` with it.
  Stream<DaemonAbout> get opens => _opens.stream;

  DaemonTalkPhase get talkPhase => _talkPhase;
  String? get talkError => _talkError;

  /// The pair harness's agent id on this computer, once a talk reached it.
  String? get pairAgentId => _pairAgentId;

  /// The talk so far, oldest first: what you said and what it answered.
  List<DaemonTalkEntry> get talk => List.unmodifiable(_talk);

  /// A stable id for this computer's desk, so a brief is not repeated.
  Future<String> desk() async {
    if (_desk case final desk?) return desk;
    try {
      final stored = await storage?.read(deskKey);
      if (stored != null && stored.isNotEmpty) return _desk = stored;
    } catch (_) {}
    final id = _id(16);
    _desk = id;
    try {
      await storage?.write(deskKey, id);
    } catch (_) {}
    return id;
  }

  String _id(int bytes) => List.generate(
    bytes,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  /// A local frame from this computer's harnessd.
  void receive(String type, Map<String, dynamic> payload) {
    if (_disposed) return;
    switch (type) {
      case 'daemon_state':
        _state = DaemonBrainState.fromJson(payload);
        notifyListeners();
      case 'daemon_say':
        final say = DaemonSay.fromJson(payload);
        if (say == null) return;
        if (say.mood == DaemonSayMood.say) _heard(say.line);
        _said.add(say);
      case 'daemon_unsay':
        final id = payload['id'];
        if (id is String) _unsaid.add(id);
      case 'daemon_brief':
        final items = payload['items'];
        _brief = DaemonBrief(
          line: _str(payload['line']),
          items: [
            for (final item in items is List ? items : const [])
              ?DaemonBriefItem.fromJson(item),
          ].take(DaemonBrief.maxItems).toList(),
          at: _now(),
        );
        notifyListeners();
      case 'daemon_act_result':
        final requestId = payload['requestId'];
        if (requestId is! String || _pendingActs.remove(requestId) == null) {
          return;
        }
        if (payload['ok'] == true) {
          final about = DaemonAbout.fromJson(payload['open']);
          if (about?.key != null) _opens.add(about!);
          return;
        }
        final detail = payload['detail'];
        _errors.add(
          detail is String && detail.isNotEmpty
              ? detail
              : actError(payload['error'] as String?),
        );
      case 'daemon_talk_result':
        final requestId = payload['requestId'];
        if (_talkRequest == null || requestId != _talkRequest) return;
        _talkRequest = null;
        if (payload['ok'] == true) {
          _talkError = null;
          _pairAgentId = _opt(payload['agentId']) ?? _pairAgentId;
          _talkPhase = payload['started'] == true
              ? DaemonTalkPhase.started
              : payload['resumed'] == true
              ? DaemonTalkPhase.resumed
              : DaemonTalkPhase.sent;
        } else {
          _talkPhase = DaemonTalkPhase.failed;
          final detail = payload['detail'];
          _talkError = detail is String && detail.isNotEmpty
              ? detail
              : talkErrorWords(payload['error'] as String?);
        }
        notifyListeners();
    }
  }

  static String actError(String? code) => switch (code) {
    'STALE_QUESTION' => 'that question changed before the answer landed.',
    'GONE' => 'that is gone.',
    'PAIR_OFF' => 'pairing is off.',
    'NOT_OFFERED' => 'that answer was not offered.',
    'DENY_CLASS' => 'that one needs you at the harness.',
    'PERSISTENT' => 'only you can choose an answer for more than this once.',
    'AUTONOMY_WATCH' => 'the daemon only watches. change it in the panel.',
    'UNTOUCHABLE' => 'the daemon never drives that one.',
    'UNSUPPORTED' => 'harnessd cannot answer that yet.',
    final String code when code.startsWith('MACHINE_') =>
      'that machine is ${code.substring(8).toLowerCase()}.',
    _ => 'the answer did not go through.',
  };

  static String talkErrorWords(String? code) => switch (code) {
    'PAIR_OFF' => 'nothing is paired: pair a daemon first.',
    'NO_ENGINE' => 'the pair runs on Claude Code or Codex; neither is here.',
    'INSTALL_FAILED' => 'the pair harness could not be installed. try again.',
    'EMPTY' => 'say something first.',
    'UNSUPPORTED' => 'this harnessd cannot talk yet. update it.',
    _ => 'the words did not reach it.',
  };

  /// Answer a line (or an ask, or a brief item) with one of its actions.
  bool act(String sayId, String choice) {
    final requestId = _id(12);
    final sent = send('daemon_act', {
      'requestId': requestId,
      'id': sayId,
      'choice': choice,
    });
    if (sent) {
      _pendingActs[requestId] = sayId;
    } else {
      _errors.add('harnessd is not reachable.');
    }
    return sent;
  }

  /// Your words to the paired daemon: harnessd starts, resumes or reaches the
  /// pair harness, and its answer comes back as a `daemon_say` (`say`).
  bool talkTo(String text) {
    final words = text.trim();
    if (_disposed || words.isEmpty) return false;
    final requestId = _id(12);
    final sent = send('daemon_talk', {'requestId': requestId, 'text': words});
    _remember((you: true, text: words));
    if (sent) {
      _talkRequest = requestId;
      _talkPhase = DaemonTalkPhase.waking;
      _talkError = null;
    } else {
      _talkRequest = null;
      _talkPhase = DaemonTalkPhase.failed;
      _talkError = 'harnessd is not reachable.';
    }
    notifyListeners();
    return sent;
  }

  void _heard(String line) {
    _remember((you: false, text: line));
    if (_talkPhase != DaemonTalkPhase.failed) {
      _talkPhase = DaemonTalkPhase.idle;
    }
    notifyListeners();
  }

  void _remember(DaemonTalkEntry entry) {
    _talk.add(entry);
    if (_talk.length > talkKept) _talk.removeAt(0);
  }

  /// Whether you are at this window, and for how long you were away, with the
  /// pane in front of you (null clears it: the brain says nothing about what
  /// you are looking at). A guest adds which daemon its local zoo pairs and
  /// its dial.
  Future<void> presence({
    required bool active,
    Duration? away,
    String? pair,
    String? autonomy,
    String? focusMachineId,
    String? focusAgentId,
  }) async {
    final desk = await this.desk();
    if (_disposed) return;
    send('daemon_presence', {
      'active': active,
      if (away != null) 'awayMs': away.inMilliseconds,
      'desk': desk,
      'pair': ?pair,
      'autonomy': ?autonomy,
      'focusMachineId': focusAgentId == null ? null : focusMachineId,
      'focusAgentId': focusAgentId,
    });
  }

  /// The pane in front of you changed, and nothing else did.
  Future<void> focus({String? machineId, String? agentId}) async {
    final desk = await this.desk();
    if (_disposed) return;
    send('daemon_presence', {
      'desk': desk,
      'focusMachineId': agentId == null ? null : machineId,
      'focusAgentId': agentId,
    });
  }

  /// You looked at the `+n`: the brain clears its count of finished turns.
  Future<void> doneSeen() async {
    final desk = await this.desk();
    if (_disposed) return;
    send('daemon_presence', {'desk': desk, 'doneSeen': true});
  }

  /// A guest's local zoo changed its pair or dial: the brain hears it.
  Future<void> guest({String? pair, String? autonomy}) async {
    final desk = await this.desk();
    if (_disposed) return;
    send('daemon_presence', {'desk': desk, 'pair': pair, 'autonomy': autonomy});
  }

  /// A new account or harnessd: nothing heard so far still holds.
  void reset() {
    _state = null;
    _brief = null;
    _pendingActs.clear();
    _talkRequest = null;
    _talkPhase = DaemonTalkPhase.idle;
    _talkError = null;
    _pairAgentId = null;
    _talk.clear();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_said.close());
    unawaited(_unsaid.close());
    unawaited(_errors.close());
    unawaited(_opens.close());
    super.dispose();
  }
}
