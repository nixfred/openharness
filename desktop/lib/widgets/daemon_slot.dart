import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

import '../daemons/daemon_brain.dart';
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
    debugDaemonTerminalTheme ??
    terminalThemeFor(AppTheme.palette.value, terminalThemeStore.value);

/// A terminal theme for review captures and tests. Every scheme the app
/// ships is dark today; this is how the light-theme rules (light-safe
/// colours, the grue's patch) are drawn and checked before one ships.
@visibleForTesting
TerminalTheme? debugDaemonTerminalTheme;

bool isDarkTerminal(TerminalTheme theme) =>
    theme.background.computeLuminance() < .4;

double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance() + .05, lb = b.computeLuminance() + .05;
  return la > lb ? la / lb : lb / la;
}

/// A daemon's one xterm colour, moved toward legible only where the terminal
/// background would swallow it. Colour is a filter over the drawing, never the
/// only signal.
Color readableInk(Color ink, Color background, {double minimum = 3}) {
  if (contrastRatio(ink, background) >= minimum) return ink;
  final toward = background.computeLuminance() > .5
      ? const Color(0xff000000)
      : const Color(0xffffffff);
  for (var step = 1; step <= 20; step++) {
    final candidate = Color.lerp(ink, toward, step / 20)!;
    if (contrastRatio(candidate, background) >= minimum) return candidate;
  }
  return toward;
}

/// A shiny daemon's colour when the roster has none of its own: the same hue,
/// brighter and more saturated.
Color shinyVariant(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation((hsl.saturation + .3).clamp(0, 1))
      .withLightness((hsl.lightness + .12).clamp(0, .85))
      .toColor();
}

/// Pitch black: where the grue is drawn on every theme.
const daemonPitch = Color(0xff000000);

/// What a daemon is drawn on, when it is not the terminal's own background:
/// the grue lives only in the dark, so wherever it is drawn it brings its own.
Color? daemonBackdrop(DaemonDef def) => def.darkOnly ? daemonPitch : null;

/// A daemon's colour on the terminal background (panel, reveal, zoo, card),
/// never in the status line. A dark theme takes its xterm colour (moved toward
/// legible only below 3:1); a light theme takes the roster's light colour, or
/// the xterm colour darkened until it reaches 4.5:1. A shiny daemon takes the
/// roster's shiny colour, or a brighter one.
Color daemonColor(DaemonDef def, TerminalTheme theme, {bool shiny = false}) {
  final base = shiny ? def.shinyColor ?? shinyVariant(def.color) : def.color;
  final backdrop = daemonBackdrop(def);
  if (backdrop != null) return readableInk(base, backdrop);
  if (isDarkTerminal(theme)) return readableInk(base, theme.background);
  return (shiny ? null : def.lightColor) ??
      readableInk(base, theme.background, minimum: 4.5);
}

/// The slot's ink: the status line's own text colour, whatever the daemon.
/// Daemon colours fail contrast on a status bar and on the message line; they
/// appear only on the terminal background. The grue on a light theme is the
/// one exception: it draws on its own black patch, so it takes its colour.
Color daemonSlotInk(DaemonFace face, TerminalTheme theme) {
  final def = face.def;
  if (def != null && daemonSlotPatch(face, theme) != null) {
    return daemonColor(def, theme);
  }
  return theme.foreground;
}

/// A black eight-cell patch behind the grue on a light theme, so it is a
/// creature in the dark rather than an empty slot.
Color? daemonSlotPatch(DaemonFace face, TerminalTheme theme) {
  final def = face.def;
  if (def == null || !face.showsDaemon || isDarkTerminal(theme)) return null;
  return daemonBackdrop(def);
}

/// The tally's ink (`+3`, `+1 egg`) and a reply's: the status line's text,
/// dimmer. Never the alert yellow.
Color daemonDimInk(TerminalTheme theme) =>
    theme.foreground.withValues(alpha: .62);

/// The status line's daemon: its tally (`+3 +1 egg`), then ten cells (eight
/// and a one-cell gutter each side) in the workspace bar's font. Only this
/// widget repaints when the face changes.
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
        final tally = face.tally;
        final patch = daemonSlotPatch(face, theme);
        return MouseRegion(
          onEnter: (_) {
            face.look();
            face.seen();
          },
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
                height: workspaceBarControlHeight(context),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tally.isNotEmpty) ...[
                      SizedBox(width: cell.width),
                      Text(
                        tally,
                        key: const ValueKey('daemon-slot-tally'),
                        maxLines: 1,
                        softWrap: false,
                        style: workspaceBarTextStyle(
                          color: daemonDimInk(theme),
                          emphasized: emphasized,
                        ).copyWith(fontFeatures: daemonTextFeatures),
                      ),
                    ],
                    SizedBox(
                      width: cell.width * (face.roster.rules.statusCells + 2),
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          if (patch != null)
                            Positioned(
                              left: cell.width,
                              width: cell.width * face.roster.rules.statusCells,
                              height: cell.height,
                              child: ColoredBox(
                                key: const ValueKey('daemon-slot-patch'),
                                color: patch,
                              ),
                            ),
                          Text(
                            face.cell,
                            key: const ValueKey('daemon-slot-glyph'),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                            style: workspaceBarTextStyle(
                              color: daemonSlotInk(face, theme),
                              emphasized: emphasized,
                            ).copyWith(fontFeatures: daemonTextFeatures),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The daemon's one line where the status line's context sits: tmux's
/// message line. An alert (a harness needs you, a failure, the pair asking
/// for your key) is in the message yellow; a reply (a boop, its first words,
/// the pair answering you) in the status line's own ink, dimmer. [fallback]
/// shows whenever it is silent. A line from the pair brain is drawn exactly
/// as sent, keys first (`[y/n/g] api@office: npm test`): each offered key in
/// that bracket is clickable (also ⌘⌥ plus the key, handled by the
/// workspace), and only while the line shows.
class DaemonVoiceLine extends StatelessWidget {
  const DaemonVoiceLine({
    super.key,
    required this.face,
    required this.fallback,
    this.onAnswer,
  });
  final DaemonFace face;
  final Widget fallback;
  final ValueChanged<String>? onAnswer;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: face.voiceLine,
    builder: (context, voice, _) {
      if (voice == null) return fallback;
      final theme = currentTerminalTheme();
      final ink = face.voiceAlert ? theme.yellow : daemonDimInk(theme);
      TextStyle style([bool emphasized = false]) => workspaceBarTextStyle(
        color: ink,
        emphasized: emphasized,
      ).copyWith(fontFeatures: daemonTextFeatures);
      final actions = face.voiceActions;
      final split = actions.isEmpty
          ? (keys: const <String>[], rest: voice)
          : splitDaemonKeys(voice, actions);
      final rest = Text(
        split.rest,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.right,
        style: style(),
      );
      return Semantics(
        key: const ValueKey('daemon-voice'),
        liveRegion: true,
        label: voice,
        child: split.keys.isEmpty
            ? ExcludeSemantics(child: rest)
            : Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DaemonKeys(
                    keys: split.keys,
                    actions: actions,
                    style: style,
                    onAnswer: onAnswer,
                    chord: true,
                  ),
                  Flexible(child: ExcludeSemantics(child: rest)),
                ],
              ),
      );
    },
  );
}

/// A line's keys, first, as the brain writes them: `[y/n/g] `. Each key that
/// is offered is its own small button ([onAnswer] with the key); a key that
/// is not (a brief's `[y]` after its minute) is drawn and does nothing.
class DaemonKeys extends StatelessWidget {
  const DaemonKeys({
    super.key,
    required this.keys,
    required this.actions,
    required this.style,
    this.onAnswer,
    this.live = true,
    this.chord = false,
    this.idPrefix = 'daemon-answer',
    this.height,
  });
  final List<String> keys;
  final List<DaemonAction> actions;
  final TextStyle Function([bool emphasized]) style;
  final ValueChanged<String>? onAnswer;

  /// Whether y and n still work (g always opens).
  final bool live;

  /// The tooltip names the ⌘⌥ chord (only the status line's line has one).
  final bool chord;
  final String idPrefix;

  /// The row's height: the status line's by default.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final height = this.height ?? workspaceBarControlHeight(context);
    Widget text(String value) => SizedBox(
      height: height,
      child: Center(
        widthFactor: 1,
        child: Text(value, style: style()),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        text('['),
        for (final (i, key) in keys.indexed) ...[
          if (i > 0) text('/'),
          if (actions.where((a) => a.key == key).firstOrNull
              case final action?
              when onAnswer != null && (live || key == 'g'))
            WorkspaceBarControl(
              key: ValueKey('$idPrefix-$key'),
              label: action.label,
              tooltip: chord
                  ? '${action.label} ⌘⌥${key.toUpperCase()}'
                  : action.label,
              onPressed: () => onAnswer!(key),
              builder: (context, emphasized) => SizedBox(
                height: height,
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    key,
                    style: style(emphasized).copyWith(
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            )
          else
            text(key),
        ],
        text('] '),
      ],
    );
  }
}

/// A card (card.mjs's lines) as selectable text: the portrait rows in the
/// daemon's colour, on its backdrop when it brings one (the grue's black).
class DaemonCardText extends StatelessWidget {
  const DaemonCardText({
    super.key,
    required this.lines,
    required this.portraitRows,
    required this.style,
    required this.colour,
    this.backdrop,
  });
  final List<String> lines;
  final int portraitRows;
  final TextStyle style;
  final Color colour;
  final Color? backdrop;

  @override
  Widget build(BuildContext context) {
    // card.mjs: the border, the head and a blank row, then the portrait. Only
    // the inside of those rows takes the daemon's colour; the frame stays ink.
    final art = style.copyWith(color: colour, backgroundColor: backdrop);
    return SelectableText.rich(
      TextSpan(
        children: [
          for (final (i, line) in lines.indexed) ...[
            if (i >= 3 && i < 3 + portraitRows && line.length > 4) ...[
              TextSpan(text: line.substring(0, 2), style: style),
              TextSpan(text: line.substring(2, line.length - 2), style: art),
              TextSpan(text: line.substring(line.length - 2), style: style),
            ] else
              TextSpan(text: line, style: style),
            if (i < lines.length - 1) TextSpan(text: '\n', style: style),
          ],
        ],
      ),
      style: style,
    );
  }
}

/// The brief on return (`daemon_brief`), under the status line: the daemon's
/// back line, then at most five items, each exactly as sent. A waiting item's
/// keys come first and work while its keys are [live] (a minute); `[g]`
/// opens the harness at any time. A `lesson` item (a lesson's `[s]`) shows
/// the lesson's text under it.
class DaemonBriefNotice extends StatelessWidget {
  const DaemonBriefNotice({
    super.key,
    required this.name,
    required this.brief,
    this.live = true,
    this.onAnswer,
  });
  final String name;
  final DaemonBrief brief;
  final bool live;
  final void Function(String id, DaemonAction action, DaemonAbout? about)?
  onAnswer;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ListenableBuilder(
      listenable: Listenable.merge([terminalThemeStore, AppTheme.palette]),
      builder: (context, _) {
        final theme = currentTerminalTheme();
        final cell = workspaceBarCellSizeOf(context);
        TextStyle ink(Color color) => workspaceBarTextStyle(
          color: color,
        ).copyWith(fontFeatures: daemonTextFeatures);
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (brief.line.isNotEmpty)
                  Text(
                    '$name: ${brief.line}',
                    style: ink(theme.foreground),
                  ),
                for (final (i, item) in brief.items.indexed) ...[
                  () {
                    final about = item.about;
                    final actions = [
                      ...item.actions,
                      if (about != null && !item.actions.any((a) => a.key == 'g'))
                        (key: 'g', label: 'open', choice: 'open'),
                    ];
                    final split = splitDaemonKeys(item.line, actions);
                    final color = switch (item.kind) {
                      'waiting' || 'lesson' => theme.yellow,
                      'failed' => theme.red,
                      _ => daemonDimInk(theme),
                    };
                    TextStyle style([bool emphasized = false]) =>
                        workspaceBarTextStyle(
                          color: color,
                          emphasized: emphasized,
                        ).copyWith(fontFeatures: daemonTextFeatures);
                    return Row(
                      key: ValueKey('daemon-brief-item-$i'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(width: cell.width * 2),
                        if (split.keys.isNotEmpty)
                          DaemonKeys(
                            keys: split.keys,
                            actions: actions,
                            style: style,
                            live: live,
                            idPrefix: 'daemon-brief-key-$i',
                            onAnswer: onAnswer == null
                                ? null
                                : (key) {
                                    final action = actions
                                        .where((a) => a.key == key)
                                        .firstOrNull;
                                    if (action != null) {
                                      onAnswer!(item.id, action, about);
                                    }
                                  },
                          ),
                        Flexible(
                          child: Text(
                            split.rest,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style(),
                          ),
                        ),
                      ],
                    );
                  }(),
                  if (item.kind == 'lesson' && item.text != null)
                    Padding(
                      padding: EdgeInsets.only(left: cell.width * 4),
                      child: Text(
                        item.text!,
                        maxLines: 12,
                        overflow: TextOverflow.ellipsis,
                        style: ink(daemonDimInk(theme)),
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
