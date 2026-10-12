/// A harness another harness's agent started opens beside it.
///
/// An agent in a Harness pane starts another harness with `harness new`, or
/// with `harness_start` through `harness mcp` run in that pane. The daemon
/// records which harness started it (the frame's `parentAgentId`, CLI
/// `registry.ts`), and a window that shows the starter in a tab opens the new
/// one in that tab, right beside it, so the person can watch, answer or stop it
/// (owner, 2026-10-11, mockup approved; docs/design/2026-10-11-agent-client.md,
/// "The person sees it"). Before this the child ran and answered and appeared
/// nowhere but the Harnesses count and ⌘O (a clean VM, CLI 0.3.75).
///
/// Only a child first seen live: never one restored with the window, one the
/// person already closed, or one that stopped. `AppNotifier` keeps what this
/// window has seen; this is the pure half, where it goes.
library;

import '../core/models.dart' show Agent;
import 'swarm.dart';
import 'terminal_pane.dart';

/// How long after it started a child still opens by itself. Long enough for a
/// launch the daemon held a while (a model waking, an engine being checked);
/// short enough that a laptop waking from a night's sleep does not fill a tab
/// with what its agents started while it was closed.
const startedChildFresh = Duration(minutes: 5);

/// Whether [child] is a harness started by another harness and running now:
/// what may open by itself.
bool startedChildLive(Agent child) =>
    child.parentAgentId != null &&
    child.parentAgentId != child.id &&
    !child.isStopped &&
    child.status != 'offline' &&
    child.terminalAvailable &&
    child.launchState != 'failed';

/// The tab [child] opens in and the pane it opens beside, or null: it is not
/// live, not new, already shown here, or its starter is in no tab here with
/// room for one more. A tab that is not for harnesses (the Store, an
/// orchestrator) never takes one.
///
/// Where the starter is in two tabs, the first in the row, never the one in
/// front: the row's order is the desk's, the same on every computer, and two
/// computers that each chose their own front tab would leave the child in both
/// (review of #1217).
({Swarm tab, TerminalPane parent})? startedChildPlacement({
  required Iterable<Swarm> tabs,
  required String machineId,
  required Agent child,
  required DateTime now,
  required int maxPanes,
}) {
  if (!startedChildLive(child)) return null;
  final created = child.createdAt;
  if (created == null || now.difference(created) > startedChildFresh) {
    return null;
  }
  TerminalPane? paneOf(Swarm tab, String agentId) => tab.panes
      .where((pane) => pane.machineId == machineId && pane.agentId == agentId)
      .firstOrNull;
  if (tabs.any((tab) => paneOf(tab, child.id) != null)) return null;
  bool takes(Swarm tab) =>
      tab.kind == 'harness' &&
      tab.panes.length < maxPanes &&
      paneOf(tab, child.parentAgentId!) != null;
  final tab = tabs.where(takes).firstOrNull;
  if (tab == null) return null;
  return (tab: tab, parent: paneOf(tab, child.parentAgentId!)!);
}
