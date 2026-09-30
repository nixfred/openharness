import 'dart:async';
import 'dart:math' as math;

import 'package:harness/shared/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/theme/app_theme.dart';
import '../shared/widgets/app_menu.dart';
import '../state/app_state.dart';
import '../state/harness_sessions.dart';
import '../state/swarm_navigation.dart';
import '../core/models.dart';
import '../usage/ledger/usage_overview.dart' show formatTokens;
import 'desktop_chrome.dart';
import 'engine_identity.dart';
import '../notify/alert_sounds.dart';

/// A compact, live inventory. Action receipts belong to AppNotifier, so
/// dismissing this surface never cancels a pause or launches a second resume.
class HarnessSessionManager extends StatefulWidget {
  const HarnessSessionManager({
    super.key,
    required this.app,
    required this.recent,
    required this.onClose,
    required this.onOpen,
    this.initialFilter = SessionFilter.all,
    this.introduction,
  });
  final AppNotifier app;
  final List<String> recent;
  final VoidCallback onClose;
  final Future<bool> Function(HarnessSession) onOpen;
  final SessionFilter initialFilter;
  final Widget? introduction;

  @override
  State<HarnessSessionManager> createState() => _HarnessSessionManagerState();
}

class _HarnessSessionManagerState extends State<HarnessSessionManager> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'Search harnesses');
  final _scroll = ScrollController();
  final _sortMenu = MenuController();
  final _pending = <String, HarnessSession>{};
  final _errors = <String, String>{};
  late SessionFilter _filter;
  Timer? _clock;
  SessionSort _sort = SessionSort.recent;
  String? _selected;
  int _selectedIndex = 0;
  final _rowKeys = <String, GlobalKey>{};
  String? _opening;

  @override
  void initState() {
    super.initState();
    _filter = widget.initialFilter;
    _clock = Timer.periodic(const Duration(minutes: 1), (_) => _changed());
    widget.app.addListener(_changed);
    // Its own notifier — marking one agent must not rebuild the workspace — so
    // this list asks for its own redraw while it is open.
    widget.app.agentUnread.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.app.removeListener(_changed);
    widget.app.agentUnread.removeListener(_changed);
    _clock?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<HarnessSession> get _sessions {
    final rows = {for (final row in harnessSessions(widget.app)) row.id: row};
    // Keep the row steady while a confirmed pause refreshes the saved roster.
    for (final row in _pending.values) {
      rows.putIfAbsent(row.id, () => row);
    }
    return rows.values.toList();
  }

  Future<void> _toggle(HarnessSession row) async {
    if (_pending.containsKey(row.id) || !row.canControl) return;
    final current = widget.app
        .stateOf(row.machineId)
        ?.agents
        .where((agent) => agent.id == row.agent.id)
        .firstOrNull;
    if (!identical(widget.app.stateOf(row.machineId), row.machine) ||
        current == null ||
        current.sessionId != row.agent.sessionId ||
        current.isStopped != row.agent.isStopped) {
      return;
    }
    setState(() {
      _pending[row.id] = row;
      _errors.remove(row.id);
    });
    String? error;
    try {
      if (row.agent.isStopped) {
        error = (await widget.app.resumeAgent(
          row.machineId,
          row.agent.id,
        )).error;
      } else {
        error = await widget.app.pauseAgent(row.machineId, row.agent.id);
      }
    } catch (_) {
      error =
          'Could not ${row.agent.isStopped ? 'resume' : 'pause'} this harness. Try again.';
    }
    if (!mounted) return;
    setState(() {
      _pending.remove(row.id);
      if (error != null) {
        _errors[row.id] = error.replaceFirst('Stop failed:', 'Pause failed:');
      }
    });
  }

  Future<void> _open(HarnessSession row, {bool answering = false}) async {
    // Going to the harness is what makes its news read. Done here rather than
    // after the open succeeds: the person has decided to look, and a mark that
    // outlived the click would read as the click not having worked.
    widget.app.markAgentSeen(row.machine.machine.machineId, row.agent.id);
    if (answering) {
      final current = widget.app.questionFor(row.machineId, row.agent.id);
      if (current == null || row.question?.sameAs(current) != true) return;
    }
    final awaitingInput =
        row.agent.terminalAvailable && row.agent.launchState == 'starting';
    if (_opening != null ||
        (_pending.containsKey(row.id) && !awaitingInput) ||
        !row.canOpen) {
      return;
    }
    setState(() {
      _opening = row.id;
      _errors.remove(row.id);
    });
    try {
      final opened = await widget.onOpen(row);
      if (mounted && opened) widget.onClose();
    } on SwarmResumeFailure catch (failure) {
      if (mounted) setState(() => _errors[row.id] = failure.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _errors[row.id] = 'Could not open this harness. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final all = _sessions;
    final rows = visibleHarnessSessions(
      all,
      query: _search.text,
      filter: _filter,
      sort: _sort,
      recent: widget.recent,
    );
    final running = all.where((row) => row.running).length;
    final paused = all.where((row) => row.agent.isStopped).length;
    final needsInput = all.where((row) => row.needsInput).length;
    final now = DateTime.now();
    final showingQuestions = _filter == SessionFilter.needsInput;
    final selected =
        rows.where((row) => row.id == _selected).firstOrNull ??
        (rows.isEmpty
            ? null
            : rows[_selected == null
                  ? 0
                  : _selectedIndex.clamp(0, rows.length - 1)]);
    if (_selected != null && selected != null) {
      _selected = selected.id;
      _selectedIndex = rows.indexOf(selected);
    }
    final scale = MediaQuery.textScalerOf(context);
    final rowHeight =
        math.max(
          62.0,
          (scale.scale(AppType.bodySize) * 1.3).ceilToDouble() +
              (scale.scale(AppType.captionSize) * 1.35).ceilToDouble() +
              26,
        ) +
        (showingQuestions
            ? (scale.scale(AppType.captionSize) * 1.35).ceilToDouble() + 6
            : 0);
    double heightFor(HarnessSession row) =>
        rowHeight +
        (row.agent.hasMonitorStats
            ? (scale.scale(AppType.captionSize) * 1.35).ceilToDouble() + 6
            : 0);
    return FocusScope(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        },
        child: Focus(
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent ||
                rows.isEmpty ||
                !_searchFocus.hasFocus) {
              return KeyEventResult.ignored;
            }
            final key = event.logicalKey;
            if ((key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.numpadEnter) &&
                _search.value.composing.isCollapsed) {
              final row = selected!;
              unawaited(_open(row, answering: row.needsInput));
              return KeyEventResult.handled;
            }
            if (key != LogicalKeyboardKey.arrowDown &&
                key != LogicalKeyboardKey.arrowUp) {
              return KeyEventResult.ignored;
            }
            final at = rows.indexOf(selected!);
            final next = _selected == null
                ? (key == LogicalKeyboardKey.arrowDown ? 0 : rows.length - 1)
                : (at + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)).clamp(
                    0,
                    rows.length - 1,
                  );
            setState(() => _selected = rows[next].id);
            void reveal() {
              final context = _rowKeys[rows[next].id]?.currentContext;
              if (!mounted || context == null) return;
              Scrollable.ensureVisible(
                context,
                alignmentPolicy: key == LogicalKeyboardKey.arrowDown
                    ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
                    : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
              );
            }

            if (_rowKeys[rows[next].id]?.currentContext != null) {
              reveal();
            } else if (_scroll.hasClients) {
              // Materialize a distant row, then use its real bounds. Question
              // text, errors, row padding and enlarged type all affect height.
              _scroll.jumpTo(
                (6 +
                        rows
                            .take(next)
                            .fold<double>(
                              0,
                              (height, row) => height + heightFor(row) + 2,
                            ))
                    .clamp(0, _scroll.position.maxScrollExtent),
              );
              WidgetsBinding.instance.addPostFrameCallback((_) => reveal());
            }
            return KeyEventResult.handled;
          },
          child: DesktopDialogSurface(
            key: const ValueKey('session-manager'),
            radius: AppDesktop.menuRadius,
            elevation: AppMenu.elevation,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DesktopDialogHeader(
                  title: 'Harnesses',
                  onClose: widget.onClose,
                ),
                if (widget.introduction != null) widget.introduction!,
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDesktop.panelPadding,
                  ),
                  child: TextField(
                    key: const ValueKey('session-search'),
                    controller: _search,
                    focusNode: _searchFocus,
                    autofocus: true,
                    style: AppType.body(height: 1.25).copyWith(fontSize: 17),
                    onChanged: (_) => setState(() => _selected = null),
                    onSubmitted: (_) {
                      if (selected != null) unawaited(_open(selected));
                    },
                    decoration: InputDecoration(
                      hintText:
                          'Search harnesses, machines, projects, branches',
                      hintStyle: AppType.body(
                        color: AppPalette.textSecondary,
                        height: 1.25,
                      ).copyWith(fontSize: 17),
                      prefixIcon: Icon(
                        AppIcons.search,
                        size: 20,
                        color: AppPalette.textSecondary,
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 36),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(AppIcons.close, size: 16),
                              onPressed: () {
                                _search.clear();
                                setState(() => _selected = null);
                                _searchFocus.requestFocus();
                              },
                            ),
                      isDense: true,
                      filled: true,
                      fillColor: AppDesktop.field,
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          AppDesktop.fieldRadius,
                        ),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          AppDesktop.fieldRadius,
                        ),
                        borderSide: BorderSide(
                          color: AppDesktop.focus,
                          width: AppDesktop.focusWidth,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final filter in SessionFilter.values)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: DesktopPill(
                                    key: ValueKey(
                                      'session-filter:${filter.name}',
                                    ),
                                    compact: true,
                                    selected: _filter == filter,
                                    onPressed: () => setState(() {
                                      _filter = filter;
                                      _selected = null;
                                    }),
                                    label: switch (filter) {
                                      SessionFilter.all => 'All ${all.length}',
                                      SessionFilter.needsInput =>
                                        'Needs input $needsInput',
                                      SessionFilter.running =>
                                        'Running $running',
                                      SessionFilter.paused => 'Paused $paused',
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: AppDesktop.controlGap),
                      MenuAnchor(
                        controller: _sortMenu,
                        onOpen: () => setState(() {}),
                        onClose: () => setState(() {}),
                        menuChildren: [
                          for (final sort in SessionSort.values)
                            AppMenuItem(
                              label: sort.label,
                              selected: _sort == sort,
                              onPressed: () {
                                _sortMenu.close();
                                setState(() {
                                  _sort = sort;
                                  _selected = null;
                                });
                              },
                            ),
                        ],
                        builder: (context, controller, child) => DesktopPill(
                          tooltip: 'Sort harnesses',
                          semanticLabel: 'Sort harnesses',
                          semanticHint: 'Current order: ${_sort.label}',
                          compact: true,
                          onPressed: () => controller.isOpen
                              ? controller.close()
                              : controller.open(),
                          icon: AppIcons.arrowDownWideNarrow,
                          label: _sort == SessionSort.recent
                              ? 'Recent'
                              : _sort.label,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: AppPalette.divider),
                Flexible(
                  child: rows.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 42,
                            horizontal: 24,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                AppIcons.layers,
                                size: 24,
                                color: AppPalette.textFaint,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                showingQuestions && _search.text.trim().isEmpty
                                    ? 'No harnesses need your input'
                                    : all.isEmpty
                                    ? 'Your harnesses live here'
                                    : 'No matching harnesses',
                                style: AppType.label(height: 1.3),
                              ),
                              if (!showingQuestions ||
                                  _search.text.trim().isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  all.isEmpty
                                      ? 'Open a harness to get started.'
                                      : 'Try another search or filter.',
                                  style: AppType.body(
                                    color: AppPalette.textSecondary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        )
                      : Scrollbar(
                          controller: _scroll,
                          child: ListView.builder(
                            controller: _scroll,
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            itemCount: rows.length,
                            itemBuilder: (context, index) {
                              final row = rows[index];
                              final pendingStop =
                                  (widget.app.pendingAgentPause(
                                        row.machineId,
                                        row.agent.id,
                                      ) ??
                                      widget.app.pendingAgentStop(
                                        row.machineId,
                                        row.agent.id,
                                      )) !=
                                  null;
                              final pendingResume = widget.app
                                  .restartAttempt(row.machineId, row.agent.id)
                                  .busy;
                              final busy =
                                  _pending.containsKey(row.id) ||
                                  pendingStop ||
                                  pendingResume ||
                                  _opening == row.id;
                              return _SessionRow(
                                key: _rowKeys.putIfAbsent(
                                  row.id,
                                  () => GlobalKey(),
                                ),
                                row: row,
                                height: heightFor(row),
                                now: now,
                                showQuestion: showingQuestions,
                                unread: widget.app.agentUnread.kindFor(
                                  row.machine.machine.machineId,
                                  row.agent.id,
                                ),
                                selected:
                                    !_sortMenu.isOpen &&
                                    _selected != null &&
                                    selected?.id == row.id,
                                onSelect: () {
                                  if (_selected == row.id) return;
                                  setState(() {
                                    _selected = row.id;
                                    _selectedIndex = index;
                                  });
                                },
                                busy: busy,
                                pendingLabel: _opening == row.id
                                    ? 'Opening…'
                                    : pendingStop
                                    ? 'Pausing…'
                                    : row.agent.isStopped
                                    ? 'Resuming…'
                                    : 'Pausing…',
                                error: _errors[row.id],
                                onOpen: () =>
                                    _open(row, answering: row.needsInput),
                                onAnswer: () => _open(row, answering: true),
                                onToggle: () => _toggle(row),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    super.key,
    required this.row,
    required this.height,
    required this.now,
    required this.showQuestion,
    required this.unread,
    required this.selected,
    required this.busy,
    required this.pendingLabel,
    required this.onOpen,
    required this.onSelect,
    required this.onToggle,
    required this.onAnswer,
    this.error,
  });
  final HarnessSession row;
  final double height;
  final DateTime now;
  final bool selected, busy, showQuestion;
  final String pendingLabel;

  /// News nobody has looked at yet, or null. Drawn beside the name, so the mark
  /// sits with the thing it is about rather than in a column of its own.
  final AlertKind? unread;

  final VoidCallback onOpen, onSelect, onToggle, onAnswer;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final primary = selected ? AppDesktop.onSelection : AppPalette.textPrimary;
    final secondary = selected
        ? AppDesktop.selectionDetail
        : AppPalette.textSecondary;
    final errorInk = Theme.of(context).colorScheme.error;
    Color statusInk(Color color) => selected ? AppDesktop.onSelection : color;
    ButtonStyle actionStyle(Color color) =>
        IconButton.styleFrom(
          foregroundColor: color,
          disabledForegroundColor: secondary.withValues(alpha: .6),
        ).copyWith(
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              width: MediaQuery.highContrastOf(context)
                  ? 2
                  : AppDesktop.focusWidth,
              color:
                  states.contains(WidgetState.focused) &&
                      !states.contains(WidgetState.disabled)
                  ? selected
                        ? AppDesktop.onSelection
                        : AppDesktop.focus
                  : Colors.transparent,
            ),
          ),
        );
    // Login or permission review may be required before a native resume hook.
    final canOpen =
        row.canOpen &&
        (!busy ||
            (row.agent.terminalAvailable &&
                row.agent.launchState == 'starting'));
    // Play/pause carries normal state; only exceptions need another label.
    final attention = switch (row.status) {
      'Ready' || 'Paused' || 'Working' || 'Needs input' => null,
      final status => status,
    };
    // The time the panel sorts by (Recently used), so the ages read in order.
    final lastUsedAt = row.lastUsedAt;
    final age = lastUsedAt == null
        ? null
        : now.difference(lastUsedAt).inMinutes < 1
        ? 'now'
        : harnessActivityAge(lastUsedAt, now);
    final activity = age == null
        ? 'Last use unknown'
        : age == 'now'
        ? 'Last used now'
        : 'Last used $age ago';
    Widget detail(IconData icon, String text, {String? tooltip}) => Tooltip(
      message: tooltip ?? text,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: secondary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.caption(color: secondary, height: 1.35),
            ),
          ),
        ],
      ),
    );
    final details = [
      detail(AppIcons.monitor, row.machine.machine.displayName),
      if (row.project case final project?) ...[
        detail(AppIcons.folder, project.label, tooltip: project.cwd),
        if (project.shownBranch case final branch?)
          detail(AppIcons.gitBranch, branch),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (focused) onSelect();
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? AppDesktop.selection : Colors.transparent,
            borderRadius: BorderRadius.circular(AppDesktop.rowRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: height,
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        key: ValueKey('session-open:${row.id}'),
                        selected: selected,
                        container: true,
                        button: true,
                        enabled: canOpen,
                        label:
                            '${row.agent.isStopped ? 'Resume and open' : 'Open'} ${row.agent.displayName}',
                        value: [
                          row.machine.machine.displayName,
                          row.project?.label,
                          row.project?.shownBranch,
                          row.question?.prompt,
                          activity,
                          if (row.agent.tokensUsed case final count?)
                            '$count tokens used',
                          if (row.agent.outputStats case final stats?) ...[
                            if (stats.hasEdits)
                              '${stats.linesAdded} lines added, ${stats.linesRemoved} lines removed in recorded edits',
                            if (stats.pullRequestsCreated case final count?)
                              '$count pull requests created',
                          ],
                          busy ? pendingLabel : row.status,
                        ].whereType<String>().join(', '),
                        onTap: canOpen ? onOpen : null,
                        excludeSemantics: true,
                        child: InkWell(
                          onTap: canOpen ? onOpen : null,
                          onHover: (hovered) {
                            if (hovered && canOpen) onSelect();
                          },
                          borderRadius: BorderRadius.circular(
                            AppDesktop.rowRadius,
                          ),
                          hoverColor: Colors.transparent,
                          focusColor: Colors.transparent,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                            child: Row(
                              children: [
                                EngineMark(
                                  engine: row.agent.identityEngine,
                                  size: AppDesktop.identitySize,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Tooltip(
                                              message: row.agent.displayName,
                                              child: Text(
                                                row.agent.displayName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: AppType.label(
                                                  color: primary,
                                                  height: 1.3,
                                                ),
                                              ),
                                            ),
                                          ),
                                          if (row.lastUsedAt != null)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                left: 8,
                                              ),
                                              child: Tooltip(
                                                message:
                                                    'Last used ${row.lastUsedAt!.toLocal()}',
                                                child: Text(
                                                  '· $age',
                                                  key: ValueKey(
                                                    'session-age:${row.id}',
                                                  ),
                                                  style: AppType.caption(
                                                    color: secondary,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          if (attention != null && !busy)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                left: 12,
                                              ),
                                              child: Text(
                                                attention,
                                                style: AppType.caption(
                                                  color: secondary,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      LayoutBuilder(
                                        builder: (context, constraints) {
                                          // Cap leading labels without reserving
                                          // columns: the branch gets all space
                                          // left over by short machine/project names.
                                          final leadingWidth = math.max(
                                            0.0,
                                            (constraints.maxWidth -
                                                    12 * (details.length - 1)) /
                                                details.length,
                                          );
                                          return Row(
                                            children: [
                                              for (
                                                var i = 0;
                                                i < details.length;
                                                i++
                                              ) ...[
                                                if (i > 0)
                                                  const SizedBox(width: 12),
                                                if (i == details.length - 1)
                                                  Expanded(child: details[i])
                                                else
                                                  ConstrainedBox(
                                                    constraints: BoxConstraints(
                                                      maxWidth: leadingWidth,
                                                    ),
                                                    child: details[i],
                                                  ),
                                              ],
                                            ],
                                          );
                                        },
                                      ),
                                      if (row.agent.hasMonitorStats) ...[
                                        const SizedBox(height: 6),
                                        _MonitorStats(
                                          agent: row.agent,
                                          id: row.id,
                                          selected: selected,
                                        ),
                                      ],
                                      if (showQuestion)
                                        if (row.question
                                            case final question?) ...[
                                          const SizedBox(height: 6),
                                          Tooltip(
                                            message: question.prompt,
                                            child: Text(
                                              question.prompt.replaceAll(
                                                RegExp(r'\s+'),
                                                ' ',
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppType.caption(
                                                color: statusInk(
                                                  AppPalette.warn,
                                                ),
                                                height: 1.35,
                                              ),
                                            ),
                                          ),
                                        ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (row.needsInput)
                      IconButton(
                        key: ValueKey('session-answer:${row.id}'),
                        tooltip: 'Needs input: ${row.question!.prompt}',
                        onPressed: canOpen ? onAnswer : null,
                        style: actionStyle(statusInk(AppPalette.warn)),
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        padding: const EdgeInsets.all(6),
                        icon: Icon(
                          AppIcons.messageCircleQuestionMark,
                          size: 20,
                          semanticLabel:
                              'Needs input for ${row.agent.displayName}',
                        ),
                      )
                    // The SAME SLOT, never both: a row is either waiting on a
                    // person or it is not, and the amber question already says
                    // the first case. This says the other one — work that is done
                    // and has not been looked at — in the one place the eye is
                    // already checking for a row's state.
                    else if (unread == AlertKind.done ||
                        unread == AlertKind.failed)
                      IconButton(
                        key: ValueKey(
                          'session-unread-${unread!.name}:${row.id}',
                        ),
                        tooltip: [
                          if (canOpen) 'Open harness',
                          unread == AlertKind.failed ? 'Failed' : 'Finished',
                        ].join(' · '),
                        onPressed: canOpen ? onOpen : null,
                        style: actionStyle(
                          statusInk(
                            unread == AlertKind.failed
                                ? errorInk
                                : AppPalette.online,
                          ),
                        ),
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        padding: const EdgeInsets.all(6),
                        icon: Icon(
                          unread == AlertKind.failed
                              ? AppIcons.circleX
                              : AppIcons.circleCheckBig,
                          size: 20,
                          semanticLabel:
                              '${unread == AlertKind.failed ? 'Failed' : 'Finished'}, not yet seen: ${row.agent.displayName}',
                        ),
                      ),
                    Tooltip(
                      // Every harness pauses; what differs is how much comes
                      // back, and the button says which before it is pressed —
                      // a shell loses what was running in it, and an engine with
                      // no way to reopen its conversation returns to a new one.
                      message: busy
                          ? pendingLabel
                          : row.controlUnavailable ?? _toggleLabel(row),
                      child: SizedBox(
                        width: 32,
                        height: 32,
                        child: busy
                            ? Semantics(
                                liveRegion: true,
                                label: '$pendingLabel ${row.agent.displayName}',
                                child: Center(
                                  child: SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                      color: secondary,
                                    ),
                                  ),
                                ),
                              )
                            : IconButton(
                                key: ValueKey('session-toggle:${row.id}'),
                                onPressed: row.canControl ? onToggle : null,
                                icon: Icon(
                                  row.agent.isStopped
                                      ? AppIcons.play
                                      : AppIcons.pause,
                                  size: 20,
                                  semanticLabel:
                                      '${row.agent.isStopped ? 'Resume' : 'Pause'} ${row.agent.displayName}',
                                ),
                                padding: const EdgeInsets.all(6),
                                style: actionStyle(primary),
                              ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppDesktop.identitySize + 24,
                    0,
                    12,
                    12,
                  ),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      error!,
                      style: AppType.body(color: statusInk(errorInk)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MonitorStats extends StatelessWidget {
  const _MonitorStats({
    required this.agent,
    required this.id,
    required this.selected,
  });
  final Agent agent;
  final String id;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final style = AppType.caption(
      color: selected ? AppDesktop.selectionDetail : AppPalette.textSecondary,
      height: 1.35,
    );
    String measured(DateTime? time) =>
        time == null ? '' : '\nUpdated ${time.toLocal()}';
    final stats = agent.outputStats;
    final items = <Widget>[
      if (agent.tokensUsed case final count?)
        Tooltip(
          message:
              '$count tokens · input, output and cached input${measured(agent.tokensUpdatedAt)}',
          child: Text(
            '${formatTokens(count)} tokens',
            key: ValueKey('session-tokens:$id'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      if (stats != null && stats.hasEdits)
        Tooltip(
          message:
              '${stats.linesAdded} lines added · ${stats.linesRemoved} removed\n'
              'Recorded edits by this harness, including repeated edits. Not the current branch diff.'
              '${measured(stats.updatedAt)}',
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '+${formatTokens(stats.linesAdded!)}',
                  style: TextStyle(
                    color: selected
                        ? AppDesktop.onSelection
                        : AppPalette.online,
                  ),
                ),
                const TextSpan(text: ' '),
                TextSpan(
                  text: '−${formatTokens(stats.linesRemoved!)}',
                  style: TextStyle(
                    color: selected
                        ? AppDesktop.onSelection
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ),
            key: ValueKey('session-edits:$id'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      if (stats?.pullRequestsCreated case final count?)
        Tooltip(
          message:
              '$count ${count == 1 ? 'pull request' : 'pull requests'} created by this harness\n'
              'Confirmed creation receipts. Cached; not a live GitHub status.${measured(stats?.updatedAt)}',
          child: Text(
            '$count ${count == 1 ? 'PR' : 'PRs'}',
            key: ValueKey('session-prs:$id'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
    ];
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('·', style: style),
            ),
          Flexible(child: items[i]),
        ],
      ],
    );
  }
}

/// What the Pause/Resume button promises for this row. Three answers, because
/// three things can come back: the same shell, the same conversation, or the
/// harness with a new one (`resumeMode` on the agent frame).
String _toggleLabel(HarnessSession row) {
  if (isTerminalEngine(row.agent.engine)) {
    return row.agent.isStopped
        ? 'Open a fresh shell here'
        : 'Pause terminal — ends this shell and anything running in it';
  }
  if (row.agent.resumesFreshConversation) {
    return row.agent.isStopped
        ? 'Resume as a new conversation'
        : 'Pause harness — it comes back as a new conversation';
  }
  return row.agent.isStopped ? 'Resume harness' : 'Pause harness';
}
