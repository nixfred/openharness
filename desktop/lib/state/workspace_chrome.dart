import 'package:flutter/widgets.dart';

import 'swarm_search.dart';

/// The workspace's command table as a host composition sees it: the same ids
/// and callbacks keys, native menus and the command box already run.
class WorkspaceCommands {
  const WorkspaceCommands({
    required this.enabled,
    required this.canRun,
    required this.run,
  });

  /// False while a dialog or route owns the window; bar controls go inert.
  final bool Function() enabled;
  final bool Function(String id) canRun;
  final void Function(String id) run;
}

/// The open picker as a host composition's bar sees it: its search, and the
/// same focus and close the picker's own keys use.
class WorkspacePicker {
  const WorkspacePicker({
    required this.search,
    required this.focus,
    required this.close,
  });

  final SwarmSearchController search;

  /// Hands typing back to the picker's input after a click.
  final VoidCallback focus;
  final VoidCallback close;
}

/// What a host composition adds to the shared workspace. Desktop passes none;
/// the web build (`lib/web/`) puts its mouse-first menu before the tabs, a bar
/// over the picker, and names a machine for New Harness. [leadingWidth] is reserved before the tabs
/// are measured.
class WorkspaceChrome {
  const WorkspaceChrome({
    required this.leadingWidth,
    required this.leading,
    this.newHarnessMachine,
    this.pickerBar,
    this.showsKeyHints = true,
    this.viewMachineCloses = false,
    this.showsShareStatus = false,
    this.scrollsTabsByArrows = false,
    this.attachesFiles = false,
    this.compactTabs,
    this.compactBelow = 0,
  });

  final double Function(BuildContext context) leadingWidth;
  final Widget Function(BuildContext context, WorkspaceCommands commands)
  leading;

  /// Where New Harness starts when no machine is this computer — a browser
  /// runs none. Null (or no answer) keeps sending the person to Machines.
  final String? Function()? newHarnessMachine;

  /// A row above the picker's input, e.g. clickable scopes and Back.
  final Widget Function(BuildContext context, WorkspacePicker picker)?
  pickerBar;

  /// False hides keyboard hints inside the workspace's pickers ([KeyHints]).
  final bool showsKeyHints;

  /// True makes a machine's View pick it for New Harness and close the
  /// picker; false keeps View scoping the picker to its harnesses.
  final bool viewMachineCloses;

  /// True marks each shared harness's pane header Public or Private.
  final bool showsShareStatus;

  /// True puts arrows either side of a tab list too long for the bar.
  final bool scrollsTabsByArrows;

  /// True lets New Harness take files — a button and drops on its box.
  final bool attachesFiles;

  /// Below [compactBelow] of window width the workspace goes compact: this
  /// replaces the tab list (the Store button steps aside), and only the focused
  /// harness is drawn — a phone has room for neither a tab row nor a grid.
  final Widget Function(BuildContext context, WorkspaceCommands commands)?
  compactTabs;
  final double compactBelow;
}
