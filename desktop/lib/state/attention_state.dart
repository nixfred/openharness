import 'package:flutter/foundation.dart';

/// What each agent needs from a person, as the local daemon's `attention` frame reports it
/// (nixfred: cli/src/lib/attention.ts). Its own notifier, like [DialState], so a state change only
/// rebuilds the panes that draw it.
enum AgentAttention { working, waiting, permission, failed, done, idle, offline }

AgentAttention attentionFromWire(Object? v) => switch (v) {
      'working' => AgentAttention.working,
      'waiting' => AgentAttention.waiting,
      'permission' => AgentAttention.permission,
      'failed' => AgentAttention.failed,
      'done' => AgentAttention.done,
      'offline' => AgentAttention.offline,
      _ => AgentAttention.idle,
    };

@immutable
class AttentionRow {
  const AttentionRow({required this.agentId, required this.state, this.detail = '', this.spendFraction});
  final String agentId;
  final AgentAttention state;
  final String detail;
  final double? spendFraction;

  /// Needs a person now: the pane glows for these and only these.
  bool get needsYou => state == AgentAttention.waiting || state == AgentAttention.permission || state == AgentAttention.failed;

  // Value equality, so an identical frame (one arrives every second) does not repaint every pane.
  @override
  bool operator ==(Object other) =>
      other is AttentionRow && other.agentId == agentId && other.state == state && other.detail == detail && other.spendFraction == spendFraction;

  @override
  int get hashCode => Object.hash(agentId, state, detail, spendFraction);
}

class AttentionState extends ChangeNotifier {
  final Map<String, AttentionRow> _rows = {};

  AttentionRow? of(String agentId) => _rows[agentId];

  /// Replace from one `attention` frame payload. Unknown shapes are ignored, never thrown.
  void apply(Map<String, dynamic> payload) {
    final agents = payload['agents'];
    if (agents is! List) return;
    final next = <String, AttentionRow>{};
    for (final a in agents) {
      if (a is! Map) continue;
      final id = a['agentId'];
      if (id is! String || id.isEmpty) continue;
      final spend = a['spend'];
      next[id] = AttentionRow(
        agentId: id,
        state: attentionFromWire(a['state']),
        detail: a['detail'] is String ? a['detail'] as String : '',
        spendFraction: spend is Map && spend['fraction'] is num ? (spend['fraction'] as num).toDouble() : null,
      );
    }
    if (mapEquals(_rows, next)) return;
    _rows
      ..clear()
      ..addAll(next);
    notifyListeners();
  }
}
