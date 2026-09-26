/// The window's half of the pair brain (`daemons/BRAIN.md`, "Frames" and
/// "As built"). harnessd senses every harness on every machine and thinks on
/// the computer you are at; this window hears what it decided and answers.
///
/// In (local frames from this computer's own harnessd only):
///   `daemon_state { pair, needs[], working, failing[], machines[] }`
///   `daemon_say { id, about, mood, line, actions[{key,label,choice}], ttlMs }`
///   `daemon_unsay { id, reason }`
///   `daemon_brief { desk, line, items[] }`
///   `daemon_act_result { requestId, id, ok, error?, detail? }`
/// Out (only on the socket bound to this computer's harnessd):
///   `daemon_act { requestId, id, choice }`
///   `daemon_presence { active, awayMs?, desk, pair?, focusMachineId?,
///     focusAgentId? }`: the pane in front of you is never spoken about
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
    this.sayId,
    this.line,
    this.actions = const [],
  });
  final String machineId, agentId, requestId, machine, name, engine, question;
  final bool deny;
  final String? sayId, line;
  final List<DaemonAction> actions;

  /// The same id the window gives a question it sees itself.
  String get key => '$machineId/$agentId#$requestId';

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
      machine: raw['machine'] is String ? raw['machine'] as String : '',
      name: raw['name'] is String ? raw['name'] as String : '',
      engine: raw['engine'] is String ? raw['engine'] as String : '',
      question: raw['question'] is String ? raw['question'] as String : '',
      deny: raw['deny'] == true,
      sayId: raw['id'] is String ? raw['id'] as String : null,
      line: raw['line'] is String ? raw['line'] as String : null,
      actions: _actions(raw['actions']),
    );
  }
}

@immutable
class DaemonBrainState {
  const DaemonBrainState({
    this.pair,
    this.needs = const [],
    this.working = false,
    this.failing = const [],
    this.machines = const [],
  });

  /// The daemon the brain pairs with; null means "use the roster lines".
  final String? pair;
  final List<DaemonNeed> needs;
  final bool working;

  /// `name: reason` for each harness that is offline or failed to start.
  final List<String> failing;

  /// `(name, status)`: `ok`, `connecting`, `unreachable`, `unlinked`, `old`, `off`.
  final List<(String, String)> machines;

  static DaemonBrainState fromJson(Map raw) => DaemonBrainState(
    pair: raw['pair'] is String ? raw['pair'] as String : null,
    needs: [
      for (final n in raw['needs'] is List ? raw['needs'] as List : const [])
        ?DaemonNeed.fromJson(n),
    ],
    working: raw['working'] == true,
    failing: [
      for (final f
          in raw['failing'] is List ? raw['failing'] as List : const [])
        if (f is Map)
          '${f['name'] ?? f['agentId'] ?? 'a harness'}: ${f['reason'] ?? 'failed'}',
    ],
    machines: [
      for (final m
          in raw['machines'] is List ? raw['machines'] as List : const [])
        if (m is Map && m['name'] is String)
          (
            m['name'] as String,
            m['status'] is String ? m['status'] as String : 'ok',
          ),
    ],
  );
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
  final String? about;
  final DaemonMood? mood;
  final List<DaemonAction> actions;
  final Duration? ttl;

  static DaemonSay? fromJson(Map raw) {
    final id = raw['id'], line = raw['line'];
    if (id is! String || line is! String || line.trim().isEmpty) return null;
    final ttl = raw['ttlMs'];
    return DaemonSay(
      id: id,
      line: line.trim(),
      about: raw['about'] is String ? raw['about'] as String : null,
      mood: daemonMoodNamed(raw['mood'] as String?),
      actions: _actions(raw['actions']),
      ttl: ttl is int && ttl > 0 ? Duration(milliseconds: ttl) : null,
    );
  }
}

typedef DaemonBriefItem = ({String kind, String machine, String line});

@immutable
class DaemonBrief {
  const DaemonBrief({required this.line, this.items = const []});
  final String line;
  final List<DaemonBriefItem> items;
}

class DaemonBrain extends ChangeNotifier {
  DaemonBrain({required this.send, this.storage, Random? random})
    : _random = random ?? Random.secure();

  /// Sends one frame on the socket bound to this computer's harnessd; false
  /// when there is none (then nothing is sent anywhere else).
  final bool Function(String type, Map<String, dynamic> payload) send;
  final LocalKeyValueStore? storage;
  final Random _random;
  static const deskKey = 'daemons.desk.v1';

  DaemonBrainState? _state;
  DaemonBrief? _brief;
  final _pendingActs = <String, String>{}; // requestId -> say id
  final _said = StreamController<DaemonSay>.broadcast(sync: true);
  final _unsaid = StreamController<String>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);
  String? _desk;
  bool _disposed = false;

  /// Whether this harnessd has a brain (it has sent `daemon_state`).
  bool get active => _state != null;
  DaemonBrainState? get state => _state;
  DaemonBrief? get brief => _brief;
  Stream<DaemonSay> get said => _said.stream;
  Stream<String> get unsaid => _unsaid.stream;

  /// A failed answer, worded for the status line.
  Stream<String> get errors => _errors.stream;

  /// A stable id for this computer's desk, so a brief is not repeated.
  Future<String> desk() async {
    if (_desk case final desk?) return desk;
    try {
      final stored = await storage?.read(deskKey);
      if (stored != null && stored.isNotEmpty) return _desk = stored;
    } catch (_) {}
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _desk = id;
    try {
      await storage?.write(deskKey, id);
    } catch (_) {}
    return id;
  }

  /// A local frame from this computer's harnessd.
  void receive(String type, Map<String, dynamic> payload) {
    if (_disposed) return;
    switch (type) {
      case 'daemon_state':
        _state = DaemonBrainState.fromJson(payload);
        notifyListeners();
      case 'daemon_say':
        final say = DaemonSay.fromJson(payload);
        if (say != null) _said.add(say);
      case 'daemon_unsay':
        final id = payload['id'];
        if (id is String) _unsaid.add(id);
      case 'daemon_brief':
        final line = payload['line'];
        _brief = DaemonBrief(
          line: line is String ? line : '',
          items: [
            for (final item
                in payload['items'] is List
                    ? payload['items'] as List
                    : const [])
              if (item is Map && item['line'] is String)
                (
                  kind: item['kind'] is String ? item['kind'] as String : '',
                  machine: item['machine'] is String
                      ? item['machine'] as String
                      : '',
                  line: item['line'] as String,
                ),
          ],
        );
        notifyListeners();
      case 'daemon_act_result':
        final requestId = payload['requestId'];
        if (requestId is! String || _pendingActs.remove(requestId) == null) {
          return;
        }
        if (payload['ok'] != true) {
          final detail = payload['detail'];
          _errors.add(
            detail is String && detail.isNotEmpty
                ? detail
                : _actError(payload['error'] as String?),
          );
        }
    }
  }

  static String _actError(String? code) => switch (code) {
    'STALE_QUESTION' => 'that question changed before the answer landed.',
    'GONE' => 'that question is gone.',
    'PAIR_OFF' => 'pairing is off.',
    'NOT_OFFERED' => 'that answer was not offered.',
    'DENY_CLASS' => 'that one needs you at the harness.',
    'UNSUPPORTED' => 'harnessd cannot answer that yet.',
    final String code when code.startsWith('MACHINE_') =>
      'that machine is ${code.substring(8).toLowerCase()}.',
    _ => 'the answer did not go through.',
  };

  /// Answer a line with one of its actions.
  bool act(String sayId, String choice) {
    final requestId = List.generate(
      12,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
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

  /// Whether you are at this window, and for how long you were away. A guest
  /// says which daemon its local zoo pairs with.
  Future<void> presence({
    required bool active,
    Duration? away,
    String? pair,
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
      // The harness in front of you: the brain never speaks about it.
      'focusMachineId': ?focusMachineId,
      'focusAgentId': ?focusAgentId,
    });
  }

  /// A new account or harnessd: nothing heard so far still holds.
  void reset() {
    _state = null;
    _brief = null;
    _pendingActs.clear();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_said.close());
    unawaited(_unsaid.close());
    unawaited(_errors.close());
    super.dispose();
  }
}
