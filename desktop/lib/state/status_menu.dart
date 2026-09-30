import 'app_state.dart';
import 'notification_inbox.dart';
import 'swarm.dart';
import 'workspace_status.dart';

/// The macOS menu lists unread harnesses in tab order, then Other sessions.
/// Receipts travel with each row so a menu left open cannot clear newer news.
List<Map<String, Object?>> statusMenuEntries(AppNotifier app) {
  final notifications = notificationInbox(app);
  if (notifications.isEmpty) return [];
  final names = workspaceTabNames(app);
  final owners = <(String, String), Swarm>{};
  // A shared session counts once. Prefer its active tab, otherwise the first
  // tab containing it. Include tabs hidden by the machine profile, too.
  for (final tab in app.swarms) {
    for (final pane in tab.panes) {
      if (pane.agentId == null) continue;
      final key = (pane.machineId, pane.agentId!);
      if (!owners.containsKey(key) || tab.id == app.activeSwarmId) {
        owners[key] = tab;
      }
    }
  }
  final groups = <String?, List<Map<String, Object?>>>{};
  for (final notification in notifications) {
    final tab = owners[(notification.machineId, notification.agentId)];
    (groups[tab?.id] ??= []).add({
      ..._entry(app, notification),
      'tabId': tab?.id,
      'tabName': tab == null ? 'Other sessions' : names[tab.id],
    });
  }
  return [for (final tab in app.swarms) ...?groups[tab.id], ...?groups[null]];
}

Map<String, Object?> _entry(AppNotifier app, InboxNotification notification) {
  final machineId = notification.machineId;
  final agentId = notification.agentId;
  return {
    'machineId': machineId,
    'agentId': agentId,
    'title': notification.title,
    'detail': notification.detail,
    'unavailable': notification.unavailable,
    'unread': true,
    'label': notification.label,
    'readToken': app.agentUnread.readTokenFor(machineId, agentId),
    'questionId': app.questionFor(machineId, agentId)?.requestId,
  };
}

bool statusMenuReceiptIsCurrent(AppNotifier app, Map receipt) {
  final machineId = receipt['machineId'], agentId = receipt['agentId'];
  return machineId is String &&
      agentId is String &&
      receipt['readToken'] ==
          app.agentUnread.readTokenFor(machineId, agentId) &&
      receipt['questionId'] == app.questionFor(machineId, agentId)?.requestId;
}

/// Dismiss the exact notifications displayed when Clear All was selected.
/// A pending question remains pending; a newer notification remains unread.
void clearStatusMenuNotifications(AppNotifier app, List receipts) {
  for (final receipt in receipts.whereType<Map>()) {
    if (receipt['unread'] != true ||
        !statusMenuReceiptIsCurrent(app, receipt)) {
      continue;
    }
    app.readAgentNotification(
      receipt['machineId'] as String,
      receipt['agentId'] as String,
      readToken: receipt['readToken'] as String?,
    );
  }
}
