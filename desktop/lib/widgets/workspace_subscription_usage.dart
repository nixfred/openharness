import 'package:flutter/painting.dart';

import '../shared/theme/status_line_style.dart';
import '../shared/theme/workspace_bar_style.dart'
    show workspaceBarGroupSeparator;

enum WorkspaceUsageTone { normal, low, exhausted }

/// One shared reading for the Flutter and native workspace footers. The Models
/// controller owns freshness, limiting windows and account deduplication.
class WorkspaceSubscriptionUsage {
  const WorkspaceSubscriptionUsage._(this.segments, this.detail);

  final List<({String text, WorkspaceUsageTone tone})> segments;
  String get text => segments.map((part) => part.text).join();
  final String detail;

  /// All footer figures report usage in the same neutral ink. Limit state and
  /// reset windows remain available in the subscriptions panel and tooltip.
  List<StatusLinePaintSegment> paintSegments({
    required Color foreground,
    required Color surface,
  }) => [
    for (final part in segments)
      StatusLinePaintSegment(
        part.text,
        statusLineInkOnSurface(foreground, surface),
        null,
      ),
  ];

  factory WorkspaceSubscriptionUsage.fromRows(List<Map<String, Object?>> rows) {
    final accounts = rows
        .where((row) => row['status'] != 'Not signed in')
        .toList();
    final counts = <Object?, int>{};
    for (final row in accounts) {
      counts.update(row['engine'], (count) => count + 1, ifAbsent: () => 1);
    }
    final segments = <({String text, WorkspaceUsageTone tone})>[];
    final details = <String>['Subscription allowance used'];
    final positions = <Object?, int>{};
    for (final row in accounts) {
      final engine = row['engine'];
      final provider = switch (engine) {
        'claude' => 'Claude',
        'codex' => 'Codex',
        _ => row['title'] as String? ?? 'Subscription',
      };
      final account = row['account'] as String? ?? '';
      final position = positions.update(
        engine,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      final name = counts[engine]! > 1
          ? '$provider ${account.isEmpty ? position : account}'
          : provider;
      final status = row['status'] as String? ?? 'Usage unavailable';
      final remaining = row['remainingPercent'];
      final figure = remaining is num && remaining.isFinite
          ? '${(100 - remaining).clamp(0, 100).round()}%'
          : '-';
      segments.add((
        text: '${segments.isEmpty ? '' : workspaceBarGroupSeparator}$name ',
        tone: WorkspaceUsageTone.normal,
      ));
      segments.add((text: figure, tone: WorkspaceUsageTone.normal));
      details.add(
        '$name${account.isNotEmpty && counts[engine] == 1 ? ' ($account)' : ''}: ${figure == '-' ? status : '$figure used'}',
      );
      final windows = row['details'];
      if (windows is List) details.addAll(windows.whereType<String>());
    }
    return WorkspaceSubscriptionUsage._(
      segments.isEmpty
          ? const [(text: 'Subscriptions', tone: WorkspaceUsageTone.normal)]
          : List.unmodifiable(segments),
      segments.isEmpty
          ? 'View subscription usage and reset times'
          : details.join('\n'),
    );
  }
}
