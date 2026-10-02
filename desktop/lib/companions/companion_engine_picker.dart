import 'package:flutter/material.dart';

import '../widgets/harness_agent_picker.dart';

/// The collection uses the same agent control as ordinary harness panes.
class CompanionEnginePicker extends HarnessAgentPicker {
  const CompanionEnginePicker({
    super.key,
    required super.engine,
    required super.onSelected,
    super.busy,
  }) : super(triggerKey: const ValueKey('companion-engine-picker'));
}
