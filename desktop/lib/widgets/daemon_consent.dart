import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

import '../terminal/terminal_text.dart';
import 'daemon_slot.dart';

/// Where the first-day consent is.
enum DaemonConsentStep {
  /// What it reads, writes and where it runs: "Let tim watch" or "Not now".
  watch,

  /// A second, separate step, only after a yes: "Let tim suggest answers?"
  suggest,
}

/// What the daemon sees, as the first-day screen says it (`daemons/README.md`,
/// "What your daemon sees"), one short row each.
List<(String, String)> daemonConsentRows(String name) => [
  (
    'reads',
    "when your agents' turns start and end, the question one waits on "
        '(the whole dialog), and each turn\'s short recap. never your '
        'keystrokes, your terminals or your files.',
  ),
  (
    'writes',
    'nothing to your projects until you allow it: a journal on each '
        'computer, with keys, tokens and passwords taken out. a lesson only '
        'with your yes.',
  ),
  (
    'runs',
    'in harnessd, on each of your computers. the journal stays there; the '
        'Harness backend never reads it. a model sees it only if you turn one '
        'on, or talk to $name.',
  ),
  ('does', 'at watch, where it starts, nothing but tell you.'),
];

/// The first-day consent (`zoo.consent`): after the first hatch, and in the
/// panel until it is answered. "Let `name` watch" sends `watching: true` and
/// the dial stays at `watch`; "Not now" sends `watching: false`, and nothing
/// is watched. Only after a yes, and as its own step, it offers `suggest`.
class DaemonConsent extends StatefulWidget {
  const DaemonConsent({
    super.key,
    required this.name,
    required this.step,
    required this.onWatch,
    required this.onNotNow,
    required this.onSuggest,
    required this.onKeepWatch,
    this.autofocus = true,
    this.ink,
  });
  final String name;
  final DaemonConsentStep step;
  final VoidCallback onWatch, onNotNow, onSuggest, onKeepWatch;
  final bool autofocus;

  /// The ink it is drawn in (the reveal's stage may be black).
  final Color? ink;

  @override
  State<DaemonConsent> createState() => _DaemonConsentState();
}

class _DaemonConsentState extends State<DaemonConsent> {
  final _yes = FocusNode(debugLabel: 'Daemon consent yes');

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _yes.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(DaemonConsent old) {
    super.didUpdateWidget(old);
    if (old.step != widget.step && widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _yes.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _yes.dispose();
    super.dispose();
  }

  Widget _button(
    String key,
    String label,
    VoidCallback onPressed,
    TerminalTheme theme,
    TextStyle ink,
    Size cell, {
    FocusNode? focusNode,
    Color? color,
  }) => TextButton(
    key: ValueKey(key),
    focusNode: focusNode,
    onPressed: onPressed,
    style:
        TextButton.styleFrom(
          minimumSize: Size.zero,
          fixedSize: Size.fromHeight(cell.height),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: ink.color,
          shape: const RoundedRectangleBorder(),
          splashFactory: NoSplash.splashFactory,
        ).copyWith(
          overlayColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.any(
                  {
                    WidgetState.hovered,
                    WidgetState.focused,
                    WidgetState.pressed,
                  }.contains,
                )
                ? theme.selection.withValues(alpha: .5)
                : Colors.transparent,
          ),
        ),
    child: Text(label, style: ink.copyWith(color: color ?? theme.cursor)),
  );

  @override
  Widget build(BuildContext context) {
    final theme = currentTerminalTheme();
    final cell = terminalCellSizeOf(context);
    final fg = widget.ink ?? theme.foreground;
    final ink = terminalContentStyle(
      color: fg,
    ).copyWith(fontFeatures: daemonTextFeatures);
    final muted = ink.copyWith(color: fg.withValues(alpha: .62));
    final name = widget.name;
    if (widget.step == DaemonConsentStep.suggest) {
      return Column(
        key: const ValueKey('daemon-consent-suggest'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Let $name suggest answers?', style: ink),
          SizedBox(height: cell.height / 2),
          Text(
            'at suggest, $name proposes answers to prompts it can read with '
            'certainty (reads, tests, builds, in-project edits), and every '
            'one waits for your key. it never approves a push, rm -rf, sudo, '
            'deploy, publish, drop or merge.',
            style: muted,
          ),
          SizedBox(height: cell.height / 2),
          Text(
            'change it any time: its panel, 4:settings.',
            style: muted,
          ),
          SizedBox(height: cell.height),
          Wrap(
            spacing: cell.width * 2,
            children: [
              _button(
                'daemon-consent-suggest-yes',
                '[ Let $name suggest ]',
                widget.onSuggest,
                theme,
                ink,
                cell,
                focusNode: _yes,
                color: theme.green,
              ),
              _button(
                'daemon-consent-keep-watch',
                '[ Keep it at watch ]',
                widget.onKeepWatch,
                theme,
                ink,
                cell,
              ),
            ],
          ),
        ],
      );
    }
    final label = cell.width * 8;
    return Column(
      key: const ValueKey('daemon-consent'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('What $name sees', style: ink),
        SizedBox(height: cell.height / 2),
        for (final (what, words) in daemonConsentRows(name))
          Padding(
            padding: EdgeInsets.only(bottom: cell.height / 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: label, child: Text(what, style: ink)),
                Expanded(child: Text(words, style: muted)),
              ],
            ),
          ),
        SizedBox(height: cell.height / 2),
        Text(
          'nothing is watched until you say yes.',
          style: muted,
        ),
        SizedBox(height: cell.height),
        Wrap(
          spacing: cell.width * 2,
          children: [
            _button(
              'daemon-consent-watch',
              '[ Let $name watch ]',
              widget.onWatch,
              theme,
              ink,
              cell,
              focusNode: _yes,
              color: theme.green,
            ),
            _button(
              'daemon-consent-not-now',
              '[ Not now ]',
              widget.onNotNow,
              theme,
              ink,
              cell,
            ),
          ],
        ),
      ],
    );
  }
}
