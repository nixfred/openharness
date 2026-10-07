import 'package:flutter/widgets.dart';

import 'nixfred/fleet_overview.dart';
import 'screens/swarm_screen.dart';
import 'state/app_state.dart';
import 'ws/terminal_transport_plugin.dart';
import 'community/fork_host.dart';

/// The signed-in screen of a native build. A browser build compiles
/// `web/web_entry.dart` in its place (the conditional import in `main.dart`),
/// so native code never reaches `lib/web/`.
///
/// nixfred: the fleet overview wraps the native workspace only, around
/// upstream's community fork host.
Widget authenticatedWorkspace(AppNotifier app) => FleetOverviewHost(
  app: app,
  child: CommunityForkHost(app: app, child: SwarmScreen(notifier: app)),
);

/// A native build draws nothing around its screens.
Widget appFrame(Widget app) => CommunityLinkHost(child: app);

/// A native build reaches machines through the local CLI, which carries its
/// own P2P transport (`remoteRelay.ts`): nothing to plug in here.
const TerminalTransportPluginFactory? terminalTransportPlugins = null;
