/// The paired daemon's lessons (`daemons/LEARNING.md`, BRAIN.md "Learning
/// (L1) as built"), as the panel lists them: pending and approved, with
/// approve, skip, show and revert. Every one goes through the same local
/// `pair` request `harness pair lessons ...` uses (`pair/control.ts`
/// `lessons { action, id?, confirmed? }`), so harnessd decides everything:
/// the panel only asks. Approving is the person's yes, so it is sent only
/// after the lesson has been shown and confirmed here (`confirmed: true`,
/// what the CLI sends after asking at a terminal).
library;

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
  DaemonLessons(this.brain);
  final DaemonBrain brain;

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

  /// Approve: only after it has been shown and the person confirmed it.
  Future<void> approve(String id) => _act('approve', id, confirmed: true);
  Future<void> skip(String id) => _act('skip', id);
  Future<void> revert(String id) => _act('revert', id);

  Future<void> _act(String action, String id, {bool confirmed = false}) async {
    final result = await _ask({
      'action': action,
      'id': id,
      if (confirmed) 'confirmed': true,
    });
    if (_disposed) return;
    final name = _lessons.where((l) => l.id == id).firstOrNull?.name ?? id;
    _message = result['ok'] == true
        ? switch (action) {
            'approve' =>
              result['line'] is String
                  ? result['line'] as String
                  : 'learned "$name".',
            'skip' => 'skipped "$name". it will not come back.',
            'revert' => 'took "$name" back.',
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
    super.dispose();
  }
}
