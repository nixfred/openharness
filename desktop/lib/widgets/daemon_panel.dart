import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

import '../daemons/daemon_brain.dart';
import '../daemons/daemon_face.dart';
import '../daemons/daemon_lines.dart';
import '../daemons/render.dart';
import '../daemons/roster.dart';
import '../daemons/zoo.dart';
import '../shared/theme/app_theme.dart';
import '../terminal/terminal_text.dart';
import '../terminal/terminal_theme_store.dart';
import 'box_chrome.dart';
import 'daemon_slot.dart';

/// Where each first-egg habit can be practised, when the app has a place.
const daemonHabitCommands = <String, String>{
  'turn': 'agent.new',
  'split': 'pane.split_right',
  'find': 'agent.open',
  'machine': 'machines.list',
  'store': 'app.store',
  'resume': 'harnesses.list',
};

/// The daemon's panel: before the first hatch, the nest and its habits; after,
/// the paired daemon's portrait, lore, family and current line, the zoo, and
/// pair, rename and nap. Escape closes (or leaves rename), arrows and j/k move,
/// Enter acts.
class DaemonPanel extends StatefulWidget {
  const DaemonPanel({
    super.key,
    required this.face,
    required this.onClose,
    required this.onHatch,
    required this.onCommand,
    required this.shortcut,
    this.brief,
  });
  final DaemonFace face;

  /// The pair brain's last brief (`daemon_brief`), when harnessd has a brain.
  final DaemonBrief? brief;
  final VoidCallback onClose;
  final ValueChanged<ZooEgg> onHatch;
  final ValueChanged<String> onCommand;
  final String? Function(String command) shortcut;

  @override
  State<DaemonPanel> createState() => _DaemonPanelState();
}

class _DaemonPanelState extends State<DaemonPanel> {
  final _focus = FocusNode(debugLabel: 'Daemon');
  final _nameFocus = FocusNode(debugLabel: 'Daemon nickname');
  final _name = TextEditingController();
  final _items = <String, FocusNode>{};
  List<String> _order = const [];
  String? _viewing;
  bool _renaming = false;
  String? _nameError;
  late Size _cell;

  DaemonFace get face => widget.face;
  DaemonRoster get roster => face.roster;
  Zoo get zoo => face.zoo.zoo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusFirst();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _nameFocus.dispose();
    _name.dispose();
    for (final node in _items.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _node(String key) =>
      _items.putIfAbsent(key, () => FocusNode(debugLabel: 'Daemon $key'));

  void _focusFirst() {
    if (_order.isEmpty) {
      _focus.requestFocus();
      return;
    }
    // A waiting egg first: that is usually why the panel was opened.
    final preferred = _order.contains('hatch')
        ? 'hatch'
        : _order.firstWhere(
            (k) => k.startsWith('egg:'),
            orElse: () => _order.contains('pair')
                ? 'pair'
                : _order.firstWhere(
                    (k) => k.startsWith('zoo:') || k.startsWith('habit:'),
                    orElse: () => _order.first,
                  ),
          );
    _node(preferred).requestFocus();
  }

  void _move(int direction) {
    if (_order.isEmpty) return;
    final current = _order.indexWhere((k) => _items[k]?.hasFocus == true);
    final next = current < 0
        ? (direction > 0 ? 0 : _order.length - 1)
        : (current + direction) % _order.length;
    _node(_order[next]).requestFocus();
  }

  void _escape() {
    if (_renaming) {
      setState(() => _renaming = false);
      _node('rename').requestFocus();
    } else {
      widget.onClose();
    }
  }

  void _beginRename(ZooDaemon daemon) {
    final name = daemon.nickname ?? daemon.id;
    _name.value = TextEditingValue(
      text: name,
      selection: TextSelection(baseOffset: 0, extentOffset: name.length),
    );
    setState(() {
      _renaming = true;
      _nameError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _renaming) _nameFocus.requestFocus();
    });
  }

  void _rename(ZooDaemon daemon) {
    final text = _name.text.trim();
    final ok = face.zoo.nickname(
      daemon.id,
      text.isEmpty || text == daemon.id ? null : text,
    );
    if (!ok) {
      setState(() => _nameError = '1–24 printable ASCII characters.');
      return;
    }
    setState(() => _renaming = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _node('rename').requestFocus();
    });
  }

  TerminalTheme get _theme => currentTerminalTheme();
  TextStyle _ink([Color? color]) =>
      terminalContentStyle(color: color ?? _theme.foreground)
          .copyWith(fontFeatures: daemonTextFeatures);
  Color get _muted => _theme.foreground.withValues(alpha: .58);

  ButtonStyle get _buttonStyle =>
      TextButton.styleFrom(
        minimumSize: Size.zero,
        fixedSize: Size.fromHeight(_cell.height),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: _theme.foreground,
        shape: const RoundedRectangleBorder(),
        splashFactory: NoSplash.splashFactory,
        alignment: Alignment.centerLeft,
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
              ? _theme.selection.withValues(alpha: .5)
              : Colors.transparent,
        ),
      );

  Widget _action(
    String key,
    String label,
    VoidCallback? onPressed, {
    Color? color,
    String? tooltip,
  }) {
    final button = TextButton(
      key: ValueKey('daemon-$key'),
      focusNode: _node(key),
      onPressed: onPressed,
      style: _buttonStyle,
      child: Text(label, style: _ink(color ?? _theme.cursor)),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        face,
        terminalFontStore,
        terminalThemeStore,
        AppTheme.palette,
      ]),
      builder: (context, _) {
        _cell = terminalCellSizeOf(context);
        final order = <String>[];
        final body = face.def == null && zoo.daemons.isEmpty
            ? _nest(order)
            : _daemon(order);
        _order = order;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _escape,
            if (!_renaming) ...{
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  _move(1),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _move(1),
              const SingleActivator(LogicalKeyboardKey.keyJ): () => _move(1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  _move(-1),
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _move(-1),
              const SingleActivator(LogicalKeyboardKey.keyK): () => _move(-1),
            },
          },
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            child: TextSelectionTheme(
              data: TextSelectionThemeData(
                selectionColor: _theme.selection,
                cursorColor: _theme.cursor,
              ),
              child: Material(
                key: const ValueKey('daemon-panel'),
                color: _theme.background,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kTerminalCornerRadius),
                  side: terminalPaneBorder(focused: true),
                ),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: _cell.width * 2,
                    vertical: _cell.height,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: body,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _title(String title) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          key: const ValueKey('daemon-panel-title'),
          style: _ink(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      SizedBox(width: _cell.width),
      Tooltip(
        message: 'Close',
        child: TextButton(
          key: const ValueKey('daemon-close'),
          onPressed: widget.onClose,
          style: _buttonStyle,
          child: Text('[x]', style: _ink(_theme.cursor)),
        ),
      ),
    ],
  );

  /// On the terminal background the nest warms toward yellow as habits are
  /// done (the status line draws it in its own ink).
  Color get _nestInk {
    if (face.revealing || face.eggReady) return _theme.yellow;
    final progress = (face.zoo.habitsCounted / face.zoo.habitsNeeded).clamp(
      0,
      1,
    );
    return Color.lerp(_theme.foreground, _theme.yellow, .28 + .72 * progress)!;
  }

  // ── before the first hatch: the nest and its habits ─────────────────────────

  List<Widget> _nest(List<String> order) {
    final done = zoo.habits.toSet();
    final egg = face.zoo.readyEgg;
    final need = face.zoo.habitsNeeded;
    final left = need - face.zoo.habitsCounted;
    for (final habit in roster.rules.habits) {
      if (daemonHabitCommands.containsKey(habit.key) &&
          !done.contains(habit.key)) {
        order.add('habit:${habit.key}');
      }
    }
    if (egg != null) order.add('hatch');
    return [
      _title(egg != null ? 'Your egg is ready' : 'Your first egg'),
      SizedBox(height: _cell.height),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _cell.width * 10,
            child: Text(
              face.glyph,
              key: const ValueKey('daemon-panel-nest'),
              semanticsLabel: egg != null ? 'Ready to hatch' : 'An egg',
              style: _ink(_nestInk),
            ),
          ),
          Expanded(
            child: Text(
              egg != null
                  ? 'Ready. Nothing hatches on its own.'
                  : left <= 0
                  ? 'Ready. The egg is on its way.'
                  : '${face.zoo.habitsCounted} of $need habits: '
                        '${face.zoo.firstEggRule}.',
              key: const ValueKey('daemon-panel-progress'),
              style: _ink(),
            ),
          ),
        ],
      ),
      SizedBox(height: _cell.height),
      for (final habit in roster.rules.habits) _habitRow(habit, done),
      SizedBox(height: _cell.height),
      Row(
        children: [
          Expanded(
            child: Text(
              egg != null ? 'enter hatches' : 'j/k move · enter opens',
              style: _ink(_muted),
            ),
          ),
          if (egg != null)
            _action('hatch', '[ hatch ]', () => widget.onHatch(egg)),
        ],
      ),
    ];
  }

  Widget _habitRow(DaemonHabit habit, Set<String> done) {
    final complete = done.contains(habit.key);
    final command = daemonHabitCommands[habit.key];
    // Days show their count where other habits show their shortcut.
    final hint = habit.key == 'days'
        ? '${face.zoo.daysUsed.clamp(0, 3)}/3'
        : command == null
        ? null
        : widget.shortcut(command);
    final row = LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Text(
            complete ? '[x]' : '[ ]',
            style: _ink(complete ? _theme.green : _muted),
          ),
          SizedBox(width: _cell.width),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: habit.label),
                  // The first egg cannot come without it (`firstEgg.require`).
                  if (!complete &&
                      roster.rules.firstEggRequire.contains(habit.key))
                    TextSpan(text: '  needed', style: _ink(_muted)),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _ink(complete ? _muted : null),
            ),
          ),
          if (hint != null &&
              !complete &&
              constraints.maxWidth >= _cell.width * 36) ...[
            SizedBox(width: _cell.width),
            Text(hint, style: _ink(_muted)),
          ],
        ],
      ),
    );
    if (complete || command == null) {
      return SizedBox(
        key: ValueKey('daemon-habit-${habit.key}'),
        height: _cell.height,
        child: row,
      );
    }
    return TextButton(
      key: ValueKey('daemon-habit-${habit.key}'),
      focusNode: _node('habit:${habit.key}'),
      onPressed: () => widget.onCommand(command),
      style: _buttonStyle,
      child: row,
    );
  }

  // ── after: the daemon, the zoo, pair, rename, nap ──────────────────────────

  List<Widget> _daemon(List<String> order) {
    final paired = face.daemon ?? zoo.paired;
    final viewingId = _viewing != null && zoo.owns(_viewing!)
        ? _viewing!
        : paired?.id;
    final viewing =
        zoo.daemons.where((d) => d.id == viewingId).firstOrNull ?? paired;
    final def = roster.byId(viewing?.id);
    if (viewing == null || def == null) return [_title('Daemon')];
    final isPair = viewing.id == zoo.pair || zoo.pair == null;
    final mood = isPair ? face.mood : DaemonMood.idle;
    final colour = daemonColor(def, _theme, shiny: viewing.shiny);
    final backdrop = daemonBackdrop(def);
    final name = viewing.nickname ?? def.id;
    final portrait = renderPortrait(
      roster,
      def,
      viewing.version,
      mood,
      t: isPair ? face.portraitT : 0,
      lid: isPair ? face.lid : null,
      motion: isPair && face.motionEnabled,
    );
    final portraitRows = portraitFor(roster, def, viewing.version).length;
    final card = zooCardLines(
      roster,
      def,
      version: viewing.version,
      shiny: viewing.shiny,
      nickname: viewing.nickname,
      hatchedAt: viewing.hatchedAt,
      egg: viewing.egg,
    );
    // The line: what it is saying, else the line for its mood now. Only a
    // harness waiting on you or a failure is the alert yellow.
    final spoken = isPair ? face.voice : null;
    final line = spoken ?? '$name: ${_lineFor(def, mood, isPair)}';
    final alert = spoken != null
        ? face.voiceAlert
        : mood == DaemonMood.need || mood == DaemonMood.fail;

    for (final d in _shelfOrder) {
      if (zoo.owns(d.id)) order.add('zoo:${d.id}');
    }
    for (final kind in _eggKinds) {
      order.add('egg:$kind');
    }
    if (!isPair) order.add('pair');
    order
      ..add('rename')
      ..add('card');
    if (_showCard) order.add('copy');
    if (isPair) order.add('nap');
    order
      ..add('quiet')
      ..add('motion');

    return [
      _title(
        viewing.nickname == null ? def.id : '${viewing.nickname} (${def.id})',
      ),
      SizedBox(height: _cell.height),
      if (_showCard)
        Container(
          width: double.infinity,
          color: Color.lerp(_theme.background, _theme.foreground, .03),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: DaemonCardText(
              key: const ValueKey('daemon-card-text'),
              lines: card,
              portraitRows: portraitRows,
              style: _ink(),
              colour: colour,
              backdrop: backdrop,
            ),
          ),
        )
      else
        Container(
          width: double.infinity,
          color:
              backdrop ??
              Color.lerp(_theme.background, _theme.foreground, .03),
          padding: EdgeInsets.symmetric(vertical: _cell.height / 2),
          alignment: Alignment.center,
          child: Text(
            portrait.join('\n'),
            key: const ValueKey('daemon-portrait'),
            semanticsLabel:
                '$name ${viewing.version}, ${DaemonFace.moodWords[mood]}',
            style: _ink(colour).copyWith(height: 1.15),
          ),
        ),
      SizedBox(height: _cell.height),
      Text(
        '${cardNumber(roster, def)} ${def.id} ${viewing.version}'
        ' · ${viewing.shiny ? '* shiny ' : ''}${def.rarity}'
        '${isPair ? ' · paired' : ''}',
        key: const ValueKey('daemon-panel-identity'),
        style: _ink(),
      ),
      Text(
        _bondLine(viewing),
        key: const ValueKey('daemon-panel-bond'),
        style: _ink(_muted),
      ),
      Text(
        def.familyYears.isEmpty
            ? def.familyLine
            : '${def.familyLine}\n${def.familyYears}',
        key: const ValueKey('daemon-panel-family'),
        style: _ink(_muted),
      ),
      SizedBox(height: _cell.height),
      Text(def.lore, key: const ValueKey('daemon-panel-lore'), style: _ink()),
      SizedBox(height: _cell.height),
      Semantics(
        liveRegion: true,
        child: Text(
          line,
          key: const ValueKey('daemon-panel-line'),
          style: _ink(alert ? _theme.yellow : _muted),
        ),
      ),
      // Asleep or out of reach is not a failure: said calmly, once.
      if (face.away.isNotEmpty) ...[
        SizedBox(height: _cell.height / 2),
        Text(
          [
            for (final machine in face.away)
              daemonMachineLine(machine.name, machine.status),
          ].join('\n'),
          key: const ValueKey('daemon-panel-away'),
          style: _ink(_muted),
        ),
      ],
      if (widget.brief case final brief?
          when brief.line.isNotEmpty || brief.items.isNotEmpty) ...[
        SizedBox(height: _cell.height),
        Text(
          [
            if (brief.line.isNotEmpty) brief.line,
            for (final item in brief.items)
              '  ${item.machine.isEmpty ? '' : '${item.machine}  '}${item.line}',
          ].join('\n'),
          key: const ValueKey('daemon-panel-brief'),
          style: _ink(_muted),
        ),
      ],
      SizedBox(height: _cell.height),
      ..._shelf(viewing.id),
      SizedBox(height: _cell.height / 2),
      ..._meters(),
      if (_eggKinds.isNotEmpty) ...[
        SizedBox(height: _cell.height / 2),
        Wrap(
          spacing: _cell.width * 2,
          children: [
            for (final kind in _eggKinds) _eggButton(kind),
          ],
        ),
      ],
      SizedBox(height: _cell.height),
      if (_renaming) ...[
        TextField(
          key: const ValueKey('daemon-name-input'),
          controller: _name,
          focusNode: _nameFocus,
          maxLength: 24,
          style: _ink(),
          cursorWidth: _cell.width,
          cursorHeight: _cell.height,
          cursorColor: _theme.cursor,
          decoration: InputDecoration(
            prefixText: 'name > ',
            prefixStyle: _ink(_muted),
            counterText: '',
            errorText: _nameError,
            errorStyle: _ink(_theme.red),
            isDense: true,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
          onSubmitted: (_) => _rename(viewing),
        ),
        Text('enter saves · empty clears · esc cancels', style: _ink(_muted)),
      ] else ...[
        Wrap(
          spacing: _cell.width * 2,
          children: [
            if (!isPair)
              _action('pair', '[ pair ]', () {
                face.zoo.pair(viewing.id);
                setState(() => _viewing = null);
              }, tooltip: 'Put ${def.id} in your status line'),
            _action('rename', '[ rename ]', () => _beginRename(viewing)),
            _action(
              'card',
              _showCard ? '[ portrait ]' : '[ card ]',
              () => setState(() {
                _showCard = !_showCard;
                _copyNote = null;
              }),
              tooltip: 'The card people share, as a code block',
            ),
            if (_showCard)
              _action(
                'copy',
                '[ copy ]',
                () => _copy(card),
                tooltip: 'Copy the card as a fenced code block',
              ),
            if (isPair)
              _action(
                'nap',
                face.napping ? '[ wake ]' : '[ nap ]',
                face.napping ? face.wake : face.nap,
                tooltip: face.napping
                    ? 'Wake ${def.id}'
                    : 'Nap for 15 minutes. A harness needing you wakes it.',
              ),
          ],
        ),
        Wrap(
          spacing: _cell.width * 2,
          children: [
            _action(
              'quiet',
              face.quiet ? '[ quiet: on ]' : '[ quiet: off ]',
              () => face.settings.quiet = !face.quiet,
              tooltip: face.quiet
                  ? 'It says nothing until you turn this off.'
                  : 'Say nothing in the status line until turned off.',
            ),
            _action(
              'motion',
              face.settings.motion ? '[ motion: on ]' : '[ motion: off ]',
              () => face.settings.motion = !face.settings.motion,
              tooltip: face.settings.motion
                  ? 'Work frames step with agent events; blinks answer you.'
                  : 'Nothing moves. The face still changes with the mood.',
            ),
          ],
        ),
        if (_copyNote != null) Text(_copyNote!, style: _ink(_muted)),
      ],
    ];
  }

  bool _showCard = false;
  String? _copyNote;

  Future<void> _copy(List<String> card) async {
    try {
      await Clipboard.setData(ClipboardData(text: cardCodeBlock(card)));
      if (mounted) setState(() => _copyNote = 'Copied as a code block.');
    } catch (_) {
      if (mounted) setState(() => _copyNote = 'Could not copy.');
    }
  }

  /// The line for [mood] now: filled from what the window knows; the
  /// roster's example only while nothing is going on.
  String _lineFor(DaemonDef def, DaemonMood mood, bool isPair) => isPair
      ? face.currentLine(mood)
      : daemonPreviewLine(def, mood, const {});

  /// `bond 2 · 160/300 xp`: levels come from counted turns (README,
  /// "Earning eggs and growing"); the version follows the level.
  String _bondLine(ZooDaemon daemon) {
    final levels = roster.rules.bondLevels;
    final next = daemon.bond + 1 < levels.length
        ? levels[daemon.bond + 1]
        : null;
    return 'bond ${daemon.bond} · ${daemon.xp}${next == null ? '' : '/$next'} xp';
  }

  // ── the zoo: a box back ─────────────────────────────────────────────────────

  /// The drop's numbered slots in order, then its secrets.
  List<DaemonDef> get _shelfOrder {
    final drop = roster.drops.first.id;
    return [
      for (final d in roster.daemons)
        if (d.drop == drop && !d.secret) d,
      for (final d in roster.daemons)
        if (d.drop == drop && d.secret) d,
    ];
  }

  static const _slotCells = 10, _perRow = 4;

  /// Like the back of a blind box: `#01`…`#09` and `#S`, each owned one as
  /// its sprite at its version in its colour (`x2` for a duplicate), each
  /// empty one `[ ? ]`, a secret `[ ! ]`.
  List<Widget> _shelf(String viewing) {
    final order = _shelfOrder;
    final regulars = order.where((d) => !d.secret).toList();
    final have = regulars.where((d) => zoo.owns(d.id)).length;
    final secret = order.any((d) => d.secret && zoo.owns(d.id));
    final drop = roster.drops.first;
    return [
      Text(
        'zoo · drop ${drop.n} ${drop.name}  $have/${regulars.length}'
        '${secret ? '  +secret' : ''}',
        key: const ValueKey('daemon-panel-zoo'),
        style: _ink(_muted),
      ),
      SizedBox(height: _cell.height / 2),
      for (var i = 0; i < order.length; i += _perRow)
        Padding(
          padding: EdgeInsets.only(bottom: _cell.height / 2),
          child: Row(
            children: [
              for (final d in order.skip(i).take(_perRow)) _slot(d, viewing),
            ],
          ),
        ),
    ];
  }

  Widget _slot(DaemonDef d, String viewing) {
    final owned = zoo.daemons.where((z) => z.id == d.id).toList();
    final number = cardNumber(roster, d).split('/').first;
    final faint = _theme.foreground.withValues(alpha: .35);
    Widget cell(List<Widget> rows) => SizedBox(
      width: _cell.width * _slotCells,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      ),
    );
    if (owned.isEmpty) {
      return Tooltip(
        message: d.secret ? 'A secret. Not yet hatched.' : 'Not yet hatched',
        child: cell([
          Text(number, style: _ink(faint)),
          Text(
            d.secret ? '[ ! ]' : '[ ? ]',
            key: ValueKey('daemon-zoo-${d.id}'),
            semanticsLabel: d.secret ? 'A secret' : 'Not yet hatched',
            style: _ink(faint),
          ),
          Text('', style: _ink()),
        ]),
      );
    }
    final first = owned.first;
    // One record per daemon; its duplicates are counted in it.
    final count = owned.fold<int>(0, (n, z) => n + z.count);
    final selected = d.id == viewing;
    final sprite = renderSprite(
      roster,
      d,
      roster.versionIndex(first.version),
      DaemonMood.idle,
      motion: false,
    );
    final backdrop = daemonBackdrop(d);
    return Tooltip(
      message:
          '${first.nickname ?? d.id} ${first.version}'
          '${count > 1 ? ' · x$count' : ''}'
          '${d.id == zoo.pair ? ' · paired' : ''}',
      child: SizedBox(
        width: _cell.width * _slotCells,
        child: TextButton(
          key: ValueKey('daemon-zoo-${d.id}'),
          focusNode: _node('zoo:${d.id}'),
          onPressed: () => setState(() => _viewing = d.id),
          style: _buttonStyle.copyWith(
            fixedSize: WidgetStatePropertyAll(
              Size(_cell.width * (_slotCells - 1), _cell.height * 3),
            ),
            backgroundColor: WidgetStatePropertyAll(
              selected ? _theme.selection.withValues(alpha: .35) : null,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$number ${d.id}', style: _ink(_muted)),
              Text(
                '${first.shiny ? '*' : ''}$sprite',
                semanticsLabel: '${d.id} ${first.version}',
                style: _ink(
                  daemonColor(d, _theme, shiny: first.shiny),
                ).copyWith(backgroundColor: backdrop),
              ),
              Text(
                '${first.version}${count > 1 ? ' x$count' : ''}',
                style: _ink(_muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Toward the next earned egg: counted turns to the next turn egg, and
  /// today's count against the daily cap.
  List<Widget> _meters() {
    final earn = roster.rules.earn;
    final progress = zoo.progress;
    final into = progress.turns % earn.turnEvery;
    final today = progress.days[localDayOf(DateTime.now())] ?? 0;
    String bar(int value, int of) {
      const width = 20;
      final filled = of <= 0 ? 0 : (value * width / of).floor().clamp(0, width);
      return '[${'#' * filled}${'-' * (width - filled)}]';
    }

    String row(String label, int value, int of) =>
        '${label.padRight(10)}${bar(value, of)}  '
        '${'$value/$of'.padLeft(5)}';
    return [
      Text(
        [
          row('next egg', into, earn.turnEvery),
          row('today', today.clamp(0, earn.dailyCap), earn.dailyCap),
          if (today >= earn.dailyCap)
            "today's turns are counted. more tomorrow.",
        ].join('\n'),
        key: const ValueKey('daemon-panel-progress'),
        semanticsLabel:
            '${earn.turnEvery - into} counted turns to the next egg. '
            '$today of ${earn.dailyCap} turns counted today.',
        style: _ink(_muted),
      ),
    ];
  }

  // ── eggs waiting: one look per kind, with a count ───────────────────────────

  List<String> get _eggKinds => [
    for (final egg in zoo.eggs)
      if (!zoo.eggs
          .takeWhile((e) => e != egg)
          .any((e) => e.kind == egg.kind))
        egg.kind,
  ];

  Widget _eggButton(String kind) {
    final eggs = zoo.eggs.where((e) => e.kind == kind).toList();
    return _action(
      'egg:$kind',
      '${face.eggLook(eggs.first)} x${eggs.length}',
      () => widget.onHatch(eggs.first),
      color: _theme.foreground,
      tooltip: 'Open a ${eggName(kind)} (${eggs.length} waiting)',
    );
  }
}
