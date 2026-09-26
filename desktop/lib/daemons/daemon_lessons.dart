/// The paired daemon's lessons (`daemons/LEARNING.md`, BRAIN.md "Learning
/// (L1, L2) as built"), as the panel lists them: pending and approved, with
/// show, skip and revert through the same local `pair` request `harness pair
/// lessons ...` uses (`pair/control.ts` `lessons { action, id? }`).
///
/// Approving is the person's alone (LEARNING.md, "Security"): it needs the
/// one-time nonce in the id of the lesson's live line (`lesson:<id>:<nonce>`,
/// in `daemon_state.asks`), keyed from a window that drew the line and its
/// whole text at least 400 ms before. So the panel teaches a lesson only
/// through that line's `[y]`; a lesson not being proposed right now is
/// approved at a terminal (`harness pair lessons approve <id>`). A window's
/// own `confirmed` would be refused (`NONCE_REQUIRED`).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'daemon_brain.dart';

@immutable
class DaemonLesson {
  const DaemonLesson({
    required this.id,
    required this.name,
    this.kind = 'skill',
    this.status = 'pending',
    this.description = '',
    this.learnedBy = '',
    this.signal = '',
    this.project,
    this.approved,
    this.from = const [],
  });
  final String id, name, kind, status, description, learnedBy, signal;
  final String? project, approved;

  /// `codex@office turn 12`, one per turn it came from.
  final List<String> from;

  bool get pending => status == 'pending';
  bool get approvedNow => status == 'approved';

  /// `skill "run-migrations-safely"` or `note for api`.
  String get title => kind == 'note'
      ? 'note${project == null ? '' : ' for $project'}'
      : '"$name"';

  static DaemonLesson? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String || raw['name'] is! String) {
      return null;
    }
    String str(String key) => raw[key] is String ? raw[key] as String : '';
    return DaemonLesson(
      id: raw['id'] as String,
      name: raw['name'] as String,
      kind: str('kind').isEmpty ? 'skill' : str('kind'),
      status: str('status').isEmpty ? 'pending' : str('status'),
      description: str('description'),
      learnedBy: str('learnedBy'),
      signal: str('signal'),
      project: raw['project'] is String ? raw['project'] as String : null,
      approved: raw['approved'] is String ? raw['approved'] as String : null,
      from: [
        for (final f in raw['from'] is List ? raw['from'] as List : const [])
          if (f is String) f,
      ],
    );
  }
}

class DaemonLessons extends ChangeNotifier {
  DaemonLessons(this.brain) {
    _results = brain.results.listen(_heard);
  }
  final DaemonBrain brain;
  late final StreamSubscription<DaemonActResult> _results;

  /// What approves [id] from a terminal, for a lesson not proposed now.
  static String approveCommand(String id) => 'harness pair lessons approve $id';

  List<DaemonLesson> _lessons = const [];
  bool _loaded = false, _busy = false, _disposed = false;
  String? _message, _note;
  String? _shownId, _shownText;

  /// Pending first, then approved; skipped and reverted ones are history.
  List<DaemonLesson> get lessons => _lessons;
  bool get loaded => _loaded;
  bool get busy => _busy;

  /// What the last action said (`learned "x".`, or why it did not).
  String? get message => _message;

  /// The store's own note (no git: a plain journal, and it says so).
  String? get note => _note;

  /// The lesson being read, and its text.
  String? get shownId => _shownId;
  String? get shownText => _shownText;

  Future<Map<String, dynamic>> _ask(Map<String, dynamic> payload) async {
    _busy = true;
    _notify();
    final result = await brain.request('lessons', payload);
    _busy = false;
    return result;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _words(Map<String, dynamic> result) {
    final detail = result['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    return switch (result['error']) {
      'UNSUPPORTED' => 'this harnessd does not keep lessons yet.',
      'UNREACHABLE' || 'TIMEOUT' => 'harnessd did not answer.',
      'NOT_FOUND' => 'that lesson is gone.',
      'NONCE_REQUIRED' || 'PERSON_ONLY' || 'UNVERIFIED' =>
        'only you approve a lesson: its [y] while it is proposed, or a terminal.',
      final String code => code.toLowerCase().replaceAll('_', ' '),
      _ => 'that did not go through.',
    };
  }

  /// Read the list again.
  Future<void> refresh() async {
    final result = await _ask({'action': 'list'});
    if (_disposed) return;
    _loaded = true;
    if (result['ok'] == true) {
      final all = [
        for (final raw
            in result['lessons'] is List ? result['lessons'] as List : const [])
          ?DaemonLesson.fromJson(raw),
      ];
      _lessons = [
        ...all.where((l) => l.pending),
        ...all.where((l) => l.approvedNow),
      ];
      _note = result['note'] is String ? result['note'] as String : null;
    } else {
      _message = _words(result);
    }
    _notify();
  }

  /// Show a lesson's text (a second show closes it).
  Future<void> show(String id) async {
    if (_shownId == id) {
      _shownId = null;
      _shownText = null;
      _notify();
      return;
    }
    final result = await _ask({'action': 'show', 'id': id});
    if (_disposed) return;
    if (result['ok'] == true && result['text'] is String) {
      _shownId = id;
      _shownText = result['text'] as String;
    } else {
      _message = _words(result);
    }
    _notify();
  }

  /// A key on a lesson's line (from the status line, the brief or the
  /// panel) taught or skipped it: say so, and read the list again.
  void _heard(DaemonActResult result) {
    if (_disposed || !result.id.startsWith('lesson:') || !result.ok) return;
    final learned = result.learned, skipped = result.skipped;
    if (learned == null && skipped == null) return;
    _message = learned != null
        ? 'learned "$learned". every harness session will load it.'
        : 'skipped "$skipped". it will not come back.';
    _shownId = null;
    _shownText = null;
    unawaited(refresh());
  }

  Future<void> skip(String id) => _act('skip', id);

  /// `harness pair lessons revert`: one git revert, and every agent forgets
  /// it. Not the person's-only kind: a window may ask.
  Future<void> revert(String id) => _act('revert', id);

  Future<void> _act(String action, String id) async {
    final result = await _ask({'action': action, 'id': id});
    if (_disposed) return;
    final name = _lessons.where((l) => l.id == id).firstOrNull?.name ?? id;
    _message = result['ok'] == true
        ? switch (action) {
            'skip' => 'skipped "$name". it will not come back.',
            'revert' => 'took "$name" back. every agent forgets it.',
            _ => null,
          }
        : _words(result);
    if (_shownId == id) {
      _shownId = null;
      _shownText = null;
    }
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_results.cancel());
    super.dispose();
  }
}
