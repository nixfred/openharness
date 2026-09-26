import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

import '../daemons/daemon_face.dart';
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
  });
  final DaemonFace face;
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
    final preferred = _order.contains('hatch')
        ? 'hatch'
        : _order.contains('pair')
        ? 'pair'
        : _order.firstWhere(
            (k) => k.startsWith('zoo:') || k.startsWith('habit:'),
            orElse: () => _order.first,
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

  // ── before the first hatch: the nest and its habits ─────────────────────────

  List<Widget> _nest(List<String> order) {
    final done = zoo.habits.toSet();
    final egg = face.zoo.readyEgg;
    final need = face.zoo.habitsNeeded;
    final left = need - done.length;
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
              style: _ink(daemonSlotInk(face, _theme)),
            ),
          ),
          Expanded(
            child: Text(
              egg != null
                  ? 'Ready. Nothing hatches on its own.'
                  : left <= 0
                  ? 'Ready. The egg is on its way.'
                  : '${done.length} of $need habits, any order.',
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
    final hint = command == null ? null : widget.shortcut(command);
    final days = habit.key == 'days' && !complete
        ? ' (${face.zoo.daysUsed.clamp(0, 3)}/3)'
        : '';
    final row = LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Text(
            complete ? '[x]' : '[ ]',
            style: _ink(complete ? _theme.green : _muted),
          ),
          SizedBox(width: _cell.width),
          Expanded(
            child: Text(
              '${habit.label}$days',
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
    final name = viewing.nickname ?? def.id;
    final portrait = renderPortrait(
      roster,
      def,
      viewing.version,
      mood,
      t: isPair ? face.t : 0,
      lid: isPair ? face.lid : null,
      motion: isPair && face.motionEnabled,
    );
    final line = isPair && face.voice != null
        ? face.voice!
        : '$name: ${def.line(mood)}';

    for (final d in roster.daemons) {
      if (zoo.owns(d.id)) order.add('zoo:${d.id}');
    }
    for (final egg in zoo.eggs) {
      order.add('egg:${egg.id}');
    }
    if (!isPair) order.add('pair');
    order.add('rename');
    if (isPair) order.add('nap');

    return [
      _title(
        viewing.nickname == null ? def.id : '${viewing.nickname} (${def.id})',
      ),
      SizedBox(height: _cell.height),
      Container(
        width: double.infinity,
        color: def.darkOnly
            ? const Color(0xff000000)
            : Color.lerp(_theme.background, _theme.foreground, .03),
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
        '#${def.n.toString().padLeft(2, '0')} ${def.id} ${viewing.version}'
        ' · ${viewing.shiny ? 'shiny ' : ''}${def.rarity}'
        '${isPair ? ' · paired' : ''}',
        key: const ValueKey('daemon-panel-identity'),
        style: _ink(),
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
          style: _ink(_theme.yellow),
        ),
      ),
      SizedBox(height: _cell.height),
      Text(
        'zoo ${zoo.daemons.map((d) => d.id).toSet().length}/${roster.daemons.length}',
        style: _ink(_muted),
      ),
      Wrap(
        spacing: _cell.width,
        children: [
          for (final d in roster.daemons) _zooEntry(d, viewing.id),
          for (final egg in zoo.eggs)
            _action(
              'egg:${egg.id}',
              roster.rules.eggs[egg.kind]?.look ?? r'\_O_/',
              () => widget.onHatch(egg),
              color: _theme.yellow,
              tooltip: 'Hatch this ${eggName(egg.kind)}',
            ),
        ],
      ),
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
      ] else
        Wrap(
          spacing: _cell.width * 2,
          children: [
            if (!isPair)
              _action('pair', '[ pair ]', () {
                face.zoo.pair(viewing.id);
                setState(() => _viewing = null);
              }, tooltip: 'Put ${def.id} in your status line'),
            _action('rename', '[ rename ]', () => _beginRename(viewing)),
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
    ];
  }

  Widget _zooEntry(DaemonDef d, String viewing) {
    final owned = zoo.daemons.where((z) => z.id == d.id).lastOrNull;
    if (owned == null) {
      return Tooltip(
        message: d.secret ? 'A secret. Not yet hatched.' : 'Not yet hatched',
        child: SizedBox(
          height: _cell.height,
          child: Text(
            d.secret ? '[!]' : '[?]',
            key: ValueKey('daemon-zoo-${d.id}'),
            semanticsLabel: d.secret ? 'A secret' : 'Not yet hatched',
            style: _ink(_theme.foreground.withValues(alpha: .35)),
          ),
        ),
      );
    }
    final selected = d.id == viewing;
    return Tooltip(
      message:
          '${owned.nickname ?? d.id} ${owned.version}'
          '${d.id == zoo.pair ? ' · paired' : ''}',
      child: TextButton(
        key: ValueKey('daemon-zoo-${d.id}'),
        focusNode: _node('zoo:${d.id}'),
        onPressed: () => setState(() => _viewing = d.id),
        style: _buttonStyle.copyWith(
          backgroundColor: WidgetStatePropertyAll(
            selected ? _theme.selection.withValues(alpha: .35) : null,
          ),
        ),
        child: Text(
          renderSprite(
            roster,
            d,
            roster.versionIndex(owned.version),
            DaemonMood.idle,
          ),
          style: _ink(daemonColor(d, _theme, shiny: owned.shiny)),
        ),
      ),
    );
  }
}
