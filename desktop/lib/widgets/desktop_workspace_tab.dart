import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../shared/theme/app_icons.dart';
import '../shared/theme/app_theme.dart' as grid;
import 'box_chrome.dart';
import 'desktop_chrome.dart';

/// The Flutter counterpart of the AppKit tab: a centered name/status group
/// and, at its trailing edge, the close action.
///
/// At rest the name and status have the whole tab; hovering reveals ×.
/// Holding Command replaces the status with the tab's shortcut, as before.
/// Agent Messages has nothing on a tab: traffic between its agents shows nothing,
/// since messages arrive when they arrive, and its on/off is Settings ▸
/// Experimental's. The 💬 that sat beside × was easy to hit by mistake and turned
/// the tab off, failing a message that was waiting (owner, 2026-10-12).
class DesktopWorkspaceTab extends StatefulWidget {
  const DesktopWorkspaceTab({
    super.key,
    required this.id,
    required this.label,
    required this.selected,
    required this.showShortcuts,
    required this.onSelect,
    required this.onClose,
    this.tooltip,
    this.activity,
    this.activityLabel,
    this.highlighted = false,
    this.onRename,
    this.shortcutHint,
  });

  final String id, label;
  final bool selected, highlighted;
  final ValueListenable<bool> showShortcuts;
  final VoidCallback? onSelect, onClose;
  final VoidCallback? onRename;
  final String? shortcutHint, tooltip, activityLabel;

  /// The status cell: an [ActivityMark].
  final Widget? activity;

  static double _measure(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  // × inside the tab's curved body, shown only on hover; at rest the name and
  // status have the whole tab. A 20pt target: 16pt was easy to click by
  // mistake (owner, 2026-10-12).
  static const closeWidth = 20.0;
  static const _restingInset = grid.AppDesktop.tabShoulder + 6;
  static const _revealedInset = closeWidth + grid.AppDesktop.tabCloseInset;
  static const _statusWidth = 16.0, _indicatorGap = 6.0;

  static TextStyle _hintStyle({Color? color}) =>
      DesktopChrome.metadata(color: color).copyWith(
        fontFamilyFallback: [...grid.AppType.sansFallback, 'Apple Symbols'],
      );

  static double indicatorWidth(
    BuildContext context,
    String? hint, {
    required bool hasActivity,
  }) => math
      .max(
        hasActivity ? _statusWidth : 0.0,
        hint == null || hint.isEmpty
            ? 0.0
            : _measure(context, hint, _hintStyle()),
      )
      .clamp(0.0, 72.0);

  static double labelWidth(BuildContext context, String label) =>
      _measure(context, label, DesktopChrome.control());

  /// The width that shows [label] whole while hovered, when × takes its room
  /// — where a tooltip appears.
  static double naturalWidth(
    BuildContext context,
    String label, {
    bool hasActivity = false,
    String? shortcutHint,
  }) =>
      labelWidth(context, label) +
      _restingInset +
      _revealedInset +
      ((hasActivity || (shortcutHint?.isNotEmpty ?? false))
          ? indicatorWidth(context, shortcutHint, hasActivity: hasActivity) +
                _indicatorGap
          : 0);

  /// The name's left edge and width: centered with its status, and when
  /// revealed moved left only as far as × needs, then shortened. A name with
  /// room never moves.
  static (double, double) titleLayout({
    required double tabWidth,
    required double labelWidth,
    required bool hasActivity,
    required bool revealed,
    double indicatorWidth = _statusWidth,
  }) {
    final status = hasActivity ? indicatorWidth + _indicatorGap : 0.0;
    final right = revealed ? _revealedInset : _restingInset;
    final width = math.min(
      labelWidth,
      math.max(0.0, tabWidth - _restingInset - right - status),
    );
    final group = width + status;
    final left = math.max(
      _restingInset,
      math.min((tabWidth - group) / 2, tabWidth - right - group),
    );
    return (left, width);
  }

  /// Tabs share the available width, then scroll at their readable minimum.
  static double widthForStrip(double availableWidth, int tabCount) {
    if (tabCount == 0) return 0;
    return math.min(
      availableWidth,
      (availableWidth / tabCount)
          .clamp(grid.AppDesktop.tabMinWidth, grid.AppDesktop.tabMaxWidth)
          .floorToDouble(),
    );
  }

  @override
  State<DesktopWorkspaceTab> createState() => _DesktopWorkspaceTabState();
}

class _DesktopWorkspaceTabState extends State<DesktopWorkspaceTab> {
  bool _hovered = false, _focused = false;

  /// The tab's trailing control: shown, it takes the pointer, focus and
  /// semantics; hidden, it keeps its place and none of them.
  Widget _accessory({
    required bool visible,
    required double width,
    required Widget child,
  }) => SizedBox(
    width: width,
    child: Center(
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: Opacity(opacity: visible ? 1 : 0, child: child),
          ),
        ),
      ),
    ),
  );

  /// A quiet glyph that takes full ink on hover, focus and press.
  ButtonStyle _accessoryStyle(Color foreground, double resting) =>
      IconButton.styleFrom(
        backgroundColor: Colors.transparent,
        overlayColor: Colors.transparent,
        side: BorderSide.none,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ).copyWith(
        animationDuration: Duration.zero,
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => foreground.withValues(
            alpha:
                states.any(
                  (state) =>
                      state == WidgetState.hovered ||
                      state == WidgetState.focused ||
                      state == WidgetState.pressed,
                )
                ? 1
                : resting,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    grid.AppTheme.watch(context);
    final enabled = widget.onSelect != null;
    final quietOpacity = MediaQuery.highContrastOf(context) ? .7 : .45;
    final focusVisible = _focused || widget.highlighted;
    // Workspace palettes can stay dark beside light app surfaces. Match the
    // native tab bar's ink to its own surface, independent of terminal colors.
    final foreground = grid.AppTheme.surfacePalette.foreground;
    final muted = foreground.withValues(alpha: .65);
    final fill = widget.selected
        ? grid.AppPalette.swarmWelcome
        : _hovered
        ? foreground.withValues(alpha: .06)
        : Colors.transparent;
    final ink = enabled
        ? widget.selected || _hovered || focusVisible
              ? foreground
              : muted
        : foreground.withValues(alpha: .38);
    Widget tab = Padding(
      padding: const EdgeInsets.only(top: grid.AppDesktop.tabTopInset),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: fill,
          shape: DesktopTabBorder(
            side: focusVisible
                ? BorderSide(color: DesktopChrome.focusRing)
                : BorderSide.none,
          ),
        ),
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          selected: widget.selected,
          child: LayoutBuilder(
            builder: (context, constraints) => ValueListenableBuilder(
              valueListenable: widget.showShortcuts,
              builder: (context, showHints, _) {
                final revealed = enabled && _hovered;
                final showHint =
                    enabled &&
                    showHints &&
                    (widget.shortcutHint?.isNotEmpty ?? false);
                final hasActivity = widget.activity != null || showHint;
                final indicator = DesktopWorkspaceTab.indicatorWidth(
                  context,
                  showHint ? widget.shortcutHint : null,
                  hasActivity: widget.activity != null,
                );
                final (groupLeft, labelWidth) = DesktopWorkspaceTab.titleLayout(
                  tabWidth: constraints.maxWidth,
                  labelWidth: DesktopWorkspaceTab.labelWidth(
                    context,
                    widget.label,
                  ),
                  hasActivity: hasActivity,
                  revealed: revealed,
                  indicatorWidth: indicator,
                );
                return Stack(
                  children: [
                    Positioned.fill(
                      child: Semantics(
                        button: true,
                        enabled: enabled,
                        label: [widget.label, ?widget.activityLabel].join(', '),
                        onTap: widget.onSelect,
                        customSemanticsActions: {
                          if (widget.onClose != null)
                            const CustomSemanticsAction(label: 'Close tab'):
                                widget.onClose!,
                        },
                        child: FocusableActionDetector(
                          enabled: enabled,
                          onShowFocusHighlight: (value) =>
                              setState(() => _focused = value),
                          actions: {
                            ActivateIntent: CallbackAction<ActivateIntent>(
                              onInvoke: (_) {
                                widget.onSelect?.call();
                                return null;
                              },
                            ),
                          },
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onSelect,
                            onDoubleTap: widget.onRename,
                            child: ExcludeSemantics(
                              child: Stack(
                                children: [
                                  Positioned(
                                    left: groupLeft,
                                    width: labelWidth,
                                    top: 0,
                                    bottom: 0,
                                    child: Center(
                                      child: Text(
                                        widget.label,
                                        key: ValueKey('tab-label:${widget.id}'),
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: DesktopChrome.control(
                                          color: ink,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (hasActivity)
                                    Positioned(
                                      left:
                                          groupLeft +
                                          labelWidth +
                                          DesktopWorkspaceTab._indicatorGap,
                                      width: indicator,
                                      top: 0,
                                      bottom: 0,
                                      child: Center(
                                        child: showHint
                                            ? Text(
                                                widget.shortcutHint!,
                                                key: ValueKey(
                                                  'tab-shortcut:${widget.id}',
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style:
                                                    DesktopWorkspaceTab._hintStyle(
                                                      color: ink,
                                                    ),
                                              )
                                            : widget.activity,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: grid.AppDesktop.tabCloseInset,
                      top: 0,
                      bottom: 0,
                      child: _accessory(
                        visible: revealed,
                        width: DesktopWorkspaceTab.closeWidth,
                        child: IconButton(
                          key: ValueKey('tab-close:${widget.id}'),
                          tooltip: 'Close tab',
                          onPressed: widget.onClose,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: DesktopWorkspaceTab.closeWidth,
                            height: 32,
                          ),
                          style: _accessoryStyle(foreground, quietOpacity),
                          icon: const Icon(
                            AppIcons.close,
                            size: AppIcons.closeSize,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip case final tooltip? when tooltip.isNotEmpty) {
      tab = Tooltip(message: tooltip, excludeFromSemantics: true, child: tab);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: widget.onSelect,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: tab,
      ),
    );
  }
}
