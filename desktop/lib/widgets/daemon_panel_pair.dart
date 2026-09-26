part of 'daemon_panel.dart';

/// The autonomy dial's levels as the panel says them (`daemons/BRAIN.md`,
/// "Autonomy dial"), one line each.
const daemonAutonomyWords = <String, (String, String)>{
  'watch': ('watch', 'reads and tells you. it answers nothing.'),
  'suggest': ('suggest', 'recommends. every action waits for your key.'),
  'act-on-key': (
    'act on key',
    'one key approves a batch. drives what it started.',
  ),
  'act-within-rules': (
    'act within rules',
    'as act on key, and runs your pair.jsonc rules.',
  ),
};

/// The floor, at every level (`daemons/BRAIN.md`, "The floor").
const daemonFloorLine =
    'never pushes, deletes, force-pushes or bypasses permissions.';

/// Where the rules live (`pair/rules.ts` `pairConfigPath`), as the person
/// reads it.
const daemonRulesPath = '~/.config/harness/pair.jsonc';

/// The pair brain's part of the panel: talk to it, what it asks you, the
/// brief, what it did on its own, its dial and its lessons. Only for the
/// paired daemon, and only what this harnessd can do.
mixin _PairSections on State<DaemonPanel> {
  // The panel's own drawing, shared.
  Size get _cell;
  TerminalTheme get _theme;
  Color get _muted;
  TextStyle _ink([Color? color]);
  FocusNode _node(String key);
  Widget _action(
    String key,
    String label,
    VoidCallback? onPressed, {
    Color? color,
    String? tooltip,
  });
  DaemonFace get face;

  final _talk = TextEditingController();
  final _talkFocus = FocusNode(debugLabel: 'Talk to daemon');
  DaemonLessons? _lessons;
  String? _confirming;

  DaemonBrain? get _brain => widget.brain;

  /// The brain is here and pairs a daemon: talk, asks and lessons work.
  bool get _pairLive => _brain?.paired ?? false;

  void _initPair() {
    final brain = _brain;
    if (brain != null && brain.active) {
      _lessons = DaemonLessons(brain)..addListener(_lessonsChanged);
      unawaited(_lessons!.refresh());
    }
    _talkFocus.addListener(_talkFocusChanged);
  }

  void _disposePair() {
    _lessons?.removeListener(_lessonsChanged);
    _lessons?.dispose();
    _talkFocus.removeListener(_talkFocusChanged);
    _talkFocus.dispose();
    _talk.dispose();
  }

  void _lessonsChanged() {
    if (mounted) setState(() {});
  }

  void _talkFocusChanged() {
    if (mounted) setState(() {});
  }

  bool get _typing => _talkFocus.hasFocus;

  void _send() {
    final text = _talk.text.trim();
    if (text.isEmpty) return;
    if (_brain?.talkTo(text) ?? false) _talk.clear();
  }

  // ── rows ───────────────────────────────────────────────────────────────────

  Widget _header(String title, {Widget? trailing}) => Padding(
    padding: EdgeInsets.only(top: _cell.height),
    child: Row(
      children: [
        Expanded(child: Text(title, style: _ink(_muted))),
        ?trailing,
      ],
    ),
  );

  /// A line the brain wrote, keys first, as a focusable row: its offered keys
  /// are buttons, and y, n, s or g on the row does what the key does.
  Widget _keyRow(
    String key, {
    required String line,
    required List<DaemonAction> actions,
    required void Function(DaemonAction action) onKey,
    bool live = true,
    Color? color,
  }) {
    final split = splitDaemonKeys(line, actions);
    final ink = color ?? _theme.foreground;
    TextStyle style([bool emphasized = false]) => _ink(ink).copyWith(
      fontWeight: emphasized ? FontWeight.w600 : null,
    );
    void press(String k) {
      final action = actions.where((a) => a.key == k).firstOrNull;
      if (action != null && (live || k == 'g')) onKey(action);
    }

    return Focus(
      key: ValueKey('daemon-row-$key'),
      focusNode: _node(key),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final keyboard = HardwareKeyboard.instance;
        if (keyboard.isMetaPressed ||
            keyboard.isControlPressed ||
            keyboard.isAltPressed) {
          return KeyEventResult.ignored;
        }
        final label = event.logicalKey.keyLabel.toLowerCase();
        if (split.keys.contains(label) &&
            actions.any((a) => a.key == label) &&
            (live || label == 'g')) {
          press(label);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter &&
            actions.any((a) => a.key == 'g')) {
          press('g');
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Container(
            color: focused ? _theme.selection.withValues(alpha: .5) : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (split.keys.isNotEmpty)
                  DaemonKeys(
                    keys: split.keys,
                    actions: actions,
                    style: style,
                    live: live,
                    height: _cell.height,
                    idPrefix: 'daemon-key-$key',
                    onAnswer: press,
                  ),
                Expanded(
                  child: Text(
                    split.rest,
                    style: _ink(ink),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── the sections ───────────────────────────────────────────────────────────

  /// What is going on now: the talk box, what it asks, the brief and what
  /// it did on its own. Above the zoo.
  List<Widget> _pairLiveSections(List<String> order, String name) {
    final brain = _brain;
    if (brain == null || !_pairLive) return const [];
    return [
      ..._talkSection(order, brain, name),
      ..._asksSection(order, brain),
      ..._briefSection(order, brain),
      ..._journalSection(brain),
    ];
  }

  /// How far it may go, and what it learned: at the end, with the switches.
  List<Widget> _pairSettingsSections(List<String> order) {
    final brain = _brain;
    return [
      ..._autonomySection(order),
      if (brain != null && _pairLive && _lessons != null)
        ..._lessonsSection(order, _lessons!),
    ];
  }

  List<Widget> _talkSection(
    List<String> order,
    DaemonBrain brain,
    String name,
  ) {
    order.add('talk');
    final status = switch (brain.talkPhase) {
      DaemonTalkPhase.waking => 'waking $name...',
      DaemonTalkPhase.started =>
        "$name's harness is starting. its answer comes here.",
      DaemonTalkPhase.resumed => "$name's harness was paused. resuming.",
      DaemonTalkPhase.sent => 'sent.',
      DaemonTalkPhase.failed => brain.talkError ?? 'that did not go through.',
      DaemonTalkPhase.idle => null,
    };
    final talk = brain.talk;
    final canOpen = widget.onOpenConversation != null;
    if (canOpen) order.add('conversation');
    return [
      _header(
        'talk',
        trailing: widget.talkShortcut == null
            ? null
            : Text(widget.talkShortcut!, style: _ink(_muted)),
      ),
      TextField(
        key: const ValueKey('daemon-talk-input'),
        controller: _talk,
        focusNode: _talkFocus,
        maxLines: 1,
        maxLength: 2000,
        style: _ink(),
        cursorWidth: _cell.width,
        cursorHeight: _cell.height,
        cursorColor: _theme.cursor,
        textInputAction: TextInputAction.send,
        decoration: InputDecoration(
          prefixText: 'talk > ',
          prefixStyle: _ink(_muted),
          hintText: 'ask $name something',
          hintStyle: _ink(_muted.withValues(alpha: .4)),
          counterText: '',
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onSubmitted: (_) {
          _send();
          _talkFocus.requestFocus();
        },
      ),
      for (final entry in talk.skip(max(0, talk.length - 4)))
        Text(
          '${entry.you ? 'you' : name} > ${entry.text}',
          style: _ink(entry.you ? _muted : null),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      if (status != null)
        Text(
          status,
          key: const ValueKey('daemon-talk-status'),
          style: _ink(
            brain.talkPhase == DaemonTalkPhase.failed ? _theme.red : _muted,
          ),
        ),
      if (canOpen)
        _action(
          'conversation',
          '[ open the conversation ]',
          widget.onOpenConversation,
          tooltip: "$name's own harness, with everything it said",
        ),
    ];
  }

  List<Widget> _asksSection(List<String> order, DaemonBrain brain) {
    final state = brain.state!;
    final rows = <Widget>[];
    for (final ask in state.asks) {
      order.add('ask:${ask.id}');
      rows.add(
        _keyRow(
          'ask:${ask.id}',
          line: ask.line,
          actions: ask.actions,
          color: _theme.yellow,
          onKey: (action) => widget.onAnswer?.call(ask.id, action, null),
        ),
      );
    }
    for (final need in state.needs) {
      final about = DaemonAbout(
        need.machineId,
        need.agentId,
        requestId: need.requestId,
      );
      final who = need.machine.isEmpty
          ? need.name
          : '${need.name}@${need.machine}';
      // Its keys work only while its line shows; after that, [g] opens it.
      final live = need.sayId != null && need.line != null;
      const open = (key: 'g', label: 'open', choice: 'open');
      final actions = live ? need.actions : const [open];
      order.add('need:${need.key}');
      rows.add(
        _keyRow(
          'need:${need.key}',
          line: live
              ? need.line!
              : '[g] $who: ${need.question.isEmpty ? 'waits on you' : need.question}',
          actions: actions.any((a) => a.key == 'g')
              ? actions
              : [...actions, open],
          color: _theme.yellow,
          onKey: (action) =>
              widget.onAnswer?.call(need.sayId ?? '', action, about),
        ),
      );
    }
    if (rows.isEmpty) return const [];
    return [_header('asks'), ...rows];
  }

  List<Widget> _briefSection(List<String> order, DaemonBrain brain) {
    final brief = brain.brief;
    if (brief == null || (brief.line.isEmpty && brief.items.isEmpty)) {
      return const [];
    }
    final live = brief.keysLive(brain.now());
    return [
      _header('brief'),
      if (brief.line.isNotEmpty)
        Text(
          brief.line,
          key: const ValueKey('daemon-panel-brief'),
          style: _ink(_muted),
        ),
      for (final (i, item) in brief.items.indexed) ...[
        () {
          final key = 'brief:${item.id.isEmpty ? i : item.id}';
          order.add(key);
          final about = item.about;
          return _keyRow(
            key,
            line: item.line,
            actions: [
              ...item.actions,
              if (about != null && !item.actions.any((a) => a.key == 'g'))
                (key: 'g', label: 'open', choice: 'open'),
            ],
            live: live,
            color: item.kind == 'waiting' || item.kind == 'lesson'
                ? _theme.yellow
                : item.kind == 'failed'
                ? _theme.red
                : _muted,
            onKey: (action) => widget.onAnswer?.call(item.id, action, about),
          );
        }(),
        if (item.kind == 'lesson' && item.text != null)
          Padding(
            padding: EdgeInsets.only(left: _cell.width * 2),
            child: Text(
              item.text!,
              style: _ink(_muted),
              maxLines: 14,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    ];
  }

  List<Widget> _journalSection(DaemonBrain brain) {
    final acted = brain.state!.acted;
    if (acted.isEmpty) return const [];
    final now = brain.now();
    String ago(DateTime? at) {
      if (at == null) return '';
      final d = now.difference(at);
      return d.inHours >= 1
          ? ' · ${d.inHours}h'
          : d.inMinutes >= 1
          ? ' · ${d.inMinutes}m'
          : ' · now';
    }

    return [
      _header('journal'),
      Text(
        [for (final a in acted.take(5)) '${a.line}${ago(a.at)}'].join('\n'),
        key: const ValueKey('daemon-panel-journal'),
        style: _ink(_muted),
      ),
    ];
  }

  List<Widget> _autonomySection(List<String> order) {
    final zoo = face.zoo;
    final level = zoo.zoo.autonomy;
    return [
      _header('autonomy'),
      for (final (id, (label, words)) in daemonAutonomyWords.entries.map(
        (e) => (e.key, e.value),
      )) ...[
        () {
          order.add('autonomy:$id');
          return _action(
            'autonomy:$id',
            '${level == id ? '(*)' : '( )'} $label',
            () => zoo.autonomy(id),
            color: level == id ? _theme.cursor : _theme.foreground,
            tooltip: words,
          );
        }(),
        Padding(
          padding: EdgeInsets.only(left: _cell.width * 4),
          child: Text(words, style: _ink(_muted)),
        ),
      ],
      Text(
        'at every level it $daemonFloorLine',
        key: const ValueKey('daemon-panel-floor'),
        style: _ink(),
      ),
      if (widget.onOpenRules != null) ...[
        () {
          order.add('rules');
          return _action(
            'rules',
            '[ rules: $daemonRulesPath ]',
            widget.onOpenRules,
            tooltip: 'What act within rules may answer, per harness',
          );
        }(),
      ],
    ];
  }

  List<Widget> _lessonsSection(List<String> order, DaemonLessons lessons) {
    final rows = <Widget>[];
    for (final lesson in lessons.lessons) {
      final confirming = _confirming == lesson.id;
      rows.add(
        Text(
          '${lesson.pending ? 'pending' : 'learned'} ${lesson.title}',
          key: ValueKey('daemon-lesson-${lesson.id}'),
          style: _ink(lesson.pending ? _theme.yellow : null),
        ),
      );
      if (lesson.description.isNotEmpty) {
        rows.add(
          Padding(
            padding: EdgeInsets.only(left: _cell.width * 2),
            child: Text(
              lesson.description,
              style: _ink(_muted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
      if (lessons.shownId == lesson.id && lessons.shownText != null) {
        rows.add(
          Container(
            key: ValueKey('daemon-lesson-text-${lesson.id}'),
            margin: EdgeInsets.only(left: _cell.width * 2),
            color: Color.lerp(_theme.background, _theme.foreground, .04),
            child: Text(
              lessons.shownText!,
              style: _ink(_muted),
              maxLines: 30,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
      final id = lesson.id;
      final buttons = <Widget>[
        () {
          order.add('lesson-show:$id');
          return _action(
            'lesson-show:$id',
            lessons.shownId == id ? '[ hide ]' : '[ show ]',
            lessons.busy ? null : () => unawaited(lessons.show(id)),
          );
        }(),
      ];
      if (lesson.pending && confirming) {
        order
          ..add('lesson-yes:$id')
          ..add('lesson-no:$id');
        buttons.addAll([
          _action('lesson-yes:$id', '[ yes, teach it ]', () {
            setState(() => _confirming = null);
            unawaited(lessons.approve(id));
          }, color: _theme.green),
          _action(
            'lesson-no:$id',
            '[ not yet ]',
            () => setState(() => _confirming = null),
          ),
        ]);
      } else if (lesson.pending) {
        order
          ..add('lesson-approve:$id')
          ..add('lesson-skip:$id');
        buttons.addAll([
          _action(
            'lesson-approve:$id',
            '[ approve ]',
            lessons.busy
                ? null
                : () {
                    // The person reads it before saying yes.
                    if (lessons.shownId != id) unawaited(lessons.show(id));
                    setState(() => _confirming = id);
                  },
            tooltip: 'Read it, then teach it to every agent',
          ),
          _action(
            'lesson-skip:$id',
            '[ skip ]',
            lessons.busy ? null : () => unawaited(lessons.skip(id)),
            tooltip: 'Never proposed again',
          ),
        ]);
      } else {
        order.add('lesson-revert:$id');
        buttons.add(
          _action(
            'lesson-revert:$id',
            '[ revert ]',
            lessons.busy ? null : () => unawaited(lessons.revert(id)),
            tooltip: 'One git revert: every agent forgets it',
          ),
        );
      }
      if (confirming) {
        rows.add(
          Text(
            'teach ${lesson.title} to every agent?',
            style: _ink(_theme.yellow),
          ),
        );
      }
      rows.add(
        Padding(
          padding: EdgeInsets.only(left: _cell.width * 2),
          child: Wrap(spacing: _cell.width * 2, children: buttons),
        ),
      );
    }
    return [
      _header('lessons'),
      if (lessons.loaded && lessons.lessons.isEmpty)
        Text(
          'nothing learned yet. it proposes what it notices.',
          style: _ink(_muted),
        ),
      ...rows,
      if (lessons.message != null)
        Text(
          lessons.message!,
          key: const ValueKey('daemon-lessons-message'),
          style: _ink(_muted),
        ),
      if (lessons.note != null) Text(lessons.note!, style: _ink(_muted)),
    ];
  }
}
