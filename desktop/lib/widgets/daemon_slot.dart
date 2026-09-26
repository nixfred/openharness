import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

import '../daemons/daemon_face.dart';
import '../daemons/roster.dart';
import '../shared/theme/app_theme.dart';
import '../shared/theme/workspace_bar_style.dart';
import '../terminal/terminal_theme.dart';
import '../terminal/terminal_theme_store.dart';
import 'box_chrome.dart';
import 'workspace_bar_control.dart';

const daemonTextFeatures = [
  FontFeature.disable('liga'),
  FontFeature.disable('calt'),
];

TerminalTheme currentTerminalTheme() =>
    terminalThemeFor(AppTheme.palette.value, terminalThemeStore.value);

bool isDarkTerminal(TerminalTheme theme) =>
    theme.background.computeLuminance() < .4;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance() + .05, lb = b.computeLuminance() + .05;
  return la > lb ? la / lb : lb / la;
}

/// A daemon's one xterm colour, moved toward legible only where the terminal
/// background would swallow it. Colour is a filter over the drawing, never the
/// only signal.
Color readableInk(Color ink, Color background, {double minimum = 3}) {
  if (_contrast(ink, background) >= minimum) return ink;
  final toward = background.computeLuminance() > .5
      ? const Color(0xff000000)
      : const Color(0xffffffff);
  for (var step = 1; step <= 10; step++) {
    final candidate = Color.lerp(ink, toward, step / 10)!;
    if (_contrast(candidate, background) >= minimum) return candidate;
  }
  return toward;
}

/// The colour of a daemon on [theme]. The grue shows up only in the dark.
Color daemonColor(DaemonDef def, TerminalTheme theme, {bool shiny = false}) {
  if (def.darkOnly && !isDarkTerminal(theme)) {
    return theme.foreground.withValues(alpha: .12);
  }
  final base = shiny ? const Color(0xff87afd7) : def.color;
  return readableInk(base, theme.background);
}

/// The slot's ink: the paired daemon's colour, or the nest warming toward the
/// terminal's yellow as habits are done.
Color daemonSlotInk(DaemonFace face, TerminalTheme theme) {
  final def = face.def;
  if (def != null) return daemonColor(def, theme);
  if (face.revealing || face.eggReady) return theme.yellow;
  final progress = (face.zoo.habitsDone / face.zoo.habitsNeeded).clamp(0, 1);
  return Color.lerp(theme.foreground, theme.yellow, .28 + .72 * progress)!;
}

/// The status line's daemon: eight cells and a one-cell gutter each side, in
/// the workspace bar's font. Only this widget repaints when the face changes.
class DaemonSlotButton extends StatelessWidget {
  const DaemonSlotButton({
    super.key,
    required this.face,
    required this.onPressed,
    this.selected = false,
  });
  final DaemonFace face;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        face,
        terminalThemeStore,
        AppTheme.palette,
      ]),
      builder: (context, _) {
        if (!face.visible) return const SizedBox.shrink();
        final cell = workspaceBarCellSizeOf(context);
        final theme = currentTerminalTheme();
        return MouseRegion(
          onEnter: (_) => face.look(),
          child: Semantics(
            value: face.detail,
            child: WorkspaceBarControl(
              key: const ValueKey('daemon-slot'),
              label: face.label,
              tooltip: face.tooltip,
              selected: selected,
              onPressed: face.revealing || face.zoo.hatchingEgg != null
                  ? null
                  : onPressed,
              builder: (context, emphasized) => SizedBox(
                width: cell.width * (face.roster.rules.statusCells + 2),
                height: workspaceBarControlHeight(context),
                child: Center(
                  child: Text(
                    face.glyph,
                    key: const ValueKey('daemon-slot-glyph'),
                    maxLines: 1,
                    softWrap: false,
                    style: workspaceBarTextStyle(
                      color: daemonSlotInk(face, theme),
                      emphasized: emphasized,
                    ).copyWith(fontFeatures: daemonTextFeatures),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The daemon's one line, in tmux's yellow message colour, where the status
/// line's context sits. [fallback] shows whenever it is silent.
class DaemonVoiceLine extends StatelessWidget {
  const DaemonVoiceLine({
    super.key,
    required this.face,
    required this.fallback,
  });
  final DaemonFace face;
  final Widget fallback;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: face.voiceLine,
    builder: (context, voice, _) {
      if (voice == null) return fallback;
      return Semantics(
        liveRegion: true,
        child: Text(
          voice,
          key: const ValueKey('daemon-voice'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: workspaceBarTextStyle(color: currentTerminalTheme().yellow)
              .copyWith(fontFeatures: daemonTextFeatures),
        ),
      );
    },
  );
}

/// A short terminal note beside the slot. It never takes focus on arrival.
class DaemonNotice extends StatelessWidget {
  const DaemonNotice({
    super.key,
    required this.message,
    this.action,
    this.onAction,
  });
  final String message;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ListenableBuilder(
      listenable: Listenable.merge([terminalThemeStore, AppTheme.palette]),
      builder: (context, _) {
        final theme = currentTerminalTheme();
        final cell = workspaceBarCellSizeOf(context);
        return Material(
          color: theme.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kTerminalCornerRadius),
            side: terminalPaneBorder(focused: true),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: cell.width,
              vertical: cell.height / 2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      message,
                      style: workspaceBarTextStyle(color: theme.foreground),
                    ),
                  ),
                ),
                if (action != null && onAction != null) ...[
                  SizedBox(width: cell.width),
                  WorkspaceBarControl(
                    label: action!,
                    onPressed: onAction,
                    builder: (context, emphasized) => SizedBox(
                      width: workspaceBarTextSizeOf(
                        context,
                        '[ $action ]',
                      ).width,
                      height: workspaceBarControlHeight(context),
                      child: Center(
                        child: Text(
                          '[ $action ]',
                          style: workspaceBarTextStyle(
                            color: theme.yellow,
                            emphasized: emphasized,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
