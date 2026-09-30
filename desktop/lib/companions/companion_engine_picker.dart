import 'package:harness/shared/theme/app_icons.dart';
import 'package:flutter/material.dart';

import '../shared/widgets/app_menu.dart';
import '../theme/app_theme.dart';
import '../widgets/engine_identity.dart';
import '../widgets/transient_menus.dart';

/// The collection's agent. Models and permissions remain in its real terminal.
class CompanionEnginePicker extends StatefulWidget {
  const CompanionEnginePicker({
    super.key,
    required this.engine,
    required this.onSelected,
    this.busy = false,
  });

  final String? engine;
  final ValueChanged<String>? onSelected;
  final bool busy;

  static String label(String engine) =>
      engine == 'claude' ? 'Claude Code' : 'Codex';

  @override
  State<CompanionEnginePicker> createState() => _CompanionEnginePickerState();
}

class _CompanionEnginePickerState extends State<CompanionEnginePicker> {
  final _menu = MenuController();
  final _trigger = FocusNode();
  final _choices = {'codex': FocusNode(), 'claude': FocusNode()};
  VoidCallback? _unregister;

  @override
  void dispose() {
    _unregister?.call();
    _trigger.dispose();
    for (final focus in _choices.values) {
      focus.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'Powered by',
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: AppColors.textSoft),
      ),
      const SizedBox(width: 4),
      MenuAnchor(
        controller: _menu,
        childFocusNode: _trigger,
        onOpen: () {
          _unregister = registerTransientMenu(_menu.close);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _menu.isOpen) {
              (_choices[widget.engine] ?? _choices['codex'])!.requestFocus();
            }
          });
        },
        onClose: () {
          _unregister?.call();
          _unregister = null;
        },
        menuChildren: [
          for (final choice in ['codex', 'claude'])
            AppMenuItem(
              label: CompanionEnginePicker.label(choice),
              leading: EngineMark(engine: choice),
              selected: widget.engine == choice,
              focusNode: _choices[choice],
              onPressed: () {
                _menu.close();
                widget.onSelected?.call(choice);
              },
            ),
        ],
        builder: (context, controller, child) => TextButton(
          key: const ValueKey('companion-engine-picker'),
          focusNode: _trigger,
          onPressed: widget.busy || widget.onSelected == null
              ? null
              : () =>
                    controller.isOpen ? controller.close() : controller.open(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.engine != null) ...[
                EngineMark(engine: widget.engine, size: 16),
                const SizedBox(width: 7),
              ],
              Text(
                widget.busy
                    ? 'Opening…'
                    : widget.engine == null
                    ? 'Choose agent'
                    : CompanionEnginePicker.label(widget.engine!),
              ),
              const SizedBox(width: 4),
              const Icon(AppIcons.chevronDown, size: 16),
            ],
          ),
        ),
      ),
    ],
  );
}
