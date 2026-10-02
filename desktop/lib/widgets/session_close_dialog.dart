import 'package:flutter/material.dart';

import '../core/models.dart';
import '../shortcuts/app_keymap.dart';
import '../shared/theme/app_theme.dart' as grid;
import 'desktop_chrome.dart';
import 'desktop_prompt_surface.dart';
import 'terminal_prompt.dart';

/// Only unfinished or uncertain work needs a decision. Cancel is the default.
Future<String?> showSessionCloseDialog(
  BuildContext context,
  Agent agent,
  String activity, {
  AppKeymap? keymap,
  String? error,
}) => showTerminalPrompt<String>(
  context,
  keymap: keymap,
  builder: (_) =>
      _SessionClosePrompt(agent: agent, activity: activity, error: error),
);

class _SessionClosePrompt extends StatefulWidget {
  const _SessionClosePrompt({
    required this.agent,
    required this.activity,
    this.error,
  });
  final Agent agent;
  final String activity;
  final String? error;
  @override
  State<_SessionClosePrompt> createState() => _SessionClosePromptState();
}

class _SessionClosePromptState extends State<_SessionClosePrompt> {
  final _cancel = FocusNode(debugLabel: 'Cancel session close');
  final _keys = FocusNode(debugLabel: 'Session close');
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cancel.requestFocus();
    });
  }

  @override
  void dispose() {
    _cancel.dispose();
    _keys.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _choose([String? choice]) => Navigator.pop(context, choice);

  @override
  Widget build(BuildContext context) {
    grid.AppTheme.watch(context);
    final description = switch (widget.activity) {
      'working' => 'Still working. Close anyway?',
      'needs_input' => 'Waiting for input. Close anyway?',
      'draft' => 'Unsent text. Close anyway?',
      _ => 'May still be working. Close anyway?',
    };
    return TerminalPromptKeys(
      focusNode: _keys,
      cancel: _choose,
      child: Semantics(
        namesRoute: true,
        label: widget.agent.displayName,
        child: DesktopPromptSurface(
          body: DesktopPromptScrollBody(
            controller: _scroll,
            child: Text(
              widget.error ?? description,
              style: DesktopChrome.text(size: 13),
            ),
          ),
          actions: [
            TextButton(
              focusNode: _cancel,
              onPressed: _choose,
              child: Text(widget.error == null ? 'Cancel' : 'OK'),
            ),
            if (widget.error == null) ...[
              FilledButton(
                key: const Key('session-close-now'),
                style: grid.dangerButtonStyle(),
                onPressed: () => _choose('now'),
                child: const Text('Close'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
