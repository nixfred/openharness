import 'package:flutter/material.dart';

import '../../shared/theme/app_icons.dart';
import '../../shared/widgets/app_icon_button.dart';
import '../../state/workspace_chrome.dart';
import '../../widgets/desktop_chrome.dart';
import 'web_picker_scopes.dart';

/// The row over the picker's input: Back out of a scope, the scopes the
/// prefix keys reach, and close — each a click instead of a key. Scopes are
/// the design system's compact scope pills (design/desktop-design-system.md).
class WebPickerBar extends StatelessWidget {
  const WebPickerBar({super.key, required this.picker});

  final WorkspacePicker picker;

  /// Lines the first pill up with the search field's text, past its icon.
  static const _fieldTextInset = 57.0;

  @override
  Widget build(BuildContext context) {
    final search = picker.search;
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) => Padding(
        key: const ValueKey('web-picker-bar'),
        padding: const EdgeInsets.fromLTRB(
          _fieldTextInset,
          DesktopChrome.controlGap + 4,
          DesktopChrome.controlGap,
          0,
        ),
        child: Row(
          children: [
            if (search.canGoBack) ...[
              DesktopPill(
                key: const ValueKey('web-picker-back'),
                label: 'Back',
                leading: const Icon(AppIcons.chevronLeft, size: 14),
                quiet: true,
                compact: true,
                onPressed: () {
                  if (search.back()) picker.focus();
                },
              ),
              const SizedBox(width: DesktopChrome.controlGap),
            ],
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final scope in webPickerScopes(search))
                    DesktopPill(
                      key: ValueKey('web-picker-scope:${scope.prefix}'),
                      label: scope.label,
                      compact: true,
                      selected:
                          !search.isHelpMode &&
                          search.scopePrefix == scope.prefix,
                      onPressed: () {
                        search.setQuery(webPickerQuery(scope));
                        picker.focus();
                      },
                    ),
                ],
              ),
            ),
            AppIconButton(
              key: const ValueKey('web-picker-close'),
              icon: AppIcons.close,
              tooltip: 'Close',
              size: 16,
              onPressed: picker.close,
            ),
          ],
        ),
      ),
    );
  }
}
