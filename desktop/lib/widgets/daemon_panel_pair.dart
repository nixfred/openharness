part of 'daemon_panel.dart';

/// The autonomy dial's levels as the panel says them (`daemons/BRAIN.md`,
/// "Autonomy dial"), one line each. There are no batches: a key approves one
/// waiting answer.
const daemonAutonomyWords = <String, (String, String)>{
  'watch': ('watch', 'reads and tells you. it answers nothing.'),
  'suggest': (
    'suggest',
    'recommends. every action waits for your key.',
  ),
  'act-on-key': (
    'act on key',
    'your key approves one waiting answer at a time; '
        'it may drive harnesses it started.',
  ),
  'act-within-rules': (
    'act within rules',
    'as act on key, and answers read, test and build prompts '
        'by your pair.jsonc rules on this computer.',
  ),
};

/// The floor, at every level (`daemons/BRAIN.md`, "The floor";
/// `pair/gate.ts`).
const daemonFloorLine =
    'nothing is deleted, restarted, forked or bypassed; a push, force, '
    'rm -rf, sudo, deploy, publish, drop or merge is never approved; a key '
    'is a one-time yes, only on a read, test, build or in-project edit.';

/// Where the rules live (`pair/rules.ts` `pairConfigPath`), as the person
/// reads it.
const daemonRulesPath = '~/.config/harness/pair.jsonc';

/// The pair brain's part of the panel: what it asks you (with the harness and
/// exactly what a key does), the brief, what it did on its own, the talk, its
/// dial and consent, and its lessons. Only what this harnessd can do.
///
/// A row with keys is acknowledged to harnessd (`daemon_shown`) only once it,
/// and its detail, are wholly inside the panel's view; its keys are faint
/// until the brain says it has armed (a moment later).
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
  Zoo get zoo;
  GlobalKey get _viewport;

  /// Focus back in the panel after what had it went away.
  void _refocus();

  final _talk = TextEditingController();
  final _talkFocus = FocusNode(debugLabel: 'Talk to daemon');
  DaemonLessons? _lessons;
  Timer? _talkTicker;

  /// The consent block, when the person opened it from settings (or the
  /// second step after a yes).
  DaemonConsentStep? _consentStep;

  /// Rows with keys drawn this build, and each one's key (to find where it
  /// is on screen).
  final _liveShown = <String>{};
  final _shownRows = <String, GlobalKey>{};
  bool _shownScheduled = false;

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
    _talkTicker?.cancel();
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

  // ── shown: only what is on screen ──────────────────────────────────────────

  void _beginShown() => _liveShown.clear();

  void _endShown() {
    _shownRows.removeWhere((id, _) => !_liveShown.contains(id));
    _scheduleShown();
  }

  void _scheduleShown() {
    if (_shownScheduled) return;
    _shownScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _shownScheduled = false;
      if (mounted) _checkShown();
    });
  }

  /// Each keyed row wholly inside the panel's view, not yet acknowledged, is
  /// now: `daemon_shown`, and its keys arm a moment later.
  void _checkShown() {
    final brain = _brain;
    if (brain == null) return;
    final view = _viewport.currentContext?.findRenderObject();
    if (view is! RenderBox || !view.attached || !view.hasSize) return;
    final visible = view.localToGlobal(Offset.zero) & view.size;
    for (final id in _liveShown) {
      if (brain.wasShown(id)) continue;
      final box = _shownRows[id]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.top >= visible.top - 1 && rect.bottom <= visible.bottom + 1) {
        brain.shown(id);
      }
    }
  }

  /// Whether a key on [id] counts yet (no brain: nothing to wait for).
  bool _armed(String id) => _brain?.armed(id) ?? true;

  // ── rows ───────────────────────────────────────────────────────────────────

  Widget _header(String title, {Widget? trailing, Key? key}) => Padding(
    key: key,
    padding: EdgeInsets.only(top: _cell.height),
    child: Row(
      children: [
        Expanded(child: Text(title, style: _ink(_muted))),
        ?trailing,
      ],
    ),
  );

  /// A line the brain wrote, keys first, as a focusable row: its offered keys
  /// are buttons, and y, n, s or g on the row does what the key does. Under
  /// it, the harness it names and, in full, what a key would do ([detail]);
  /// [listing] (what a pair.jsonc turns on) before that. A row with [shownId]
  /// arms only once all of it has been on screen a moment.
  Widget _keyRow(
    String key, {
    required String line,
    required List<DaemonAction> actions,
    required void Function(DaemonAction action) onKey,
    bool live = true,
    Color? color,
    String? shownId,
    String? detail,
    String? harness,
    bool fromPair = false,
    String? name,
    List<String> listing = const [],
  }) {
    final split = splitDaemonKeys(line, actions);
    final ink = color ?? _theme.foreground;
    final armed = shownId == null || _armed(shownId);
    TextStyle style([bool emphasized = false]) => _ink(ink).copyWith(
      fontWeight: emphasized ? FontWeight.w600 : null,
    );
    void press(String k) {
      final action = actions.where((a) => a.key == k).firstOrNull;
      if (action == null) return;
      if (k == 'g' || (live && armed)) onKey(action);
    }

    final row = Focus(
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
            (label == 'g' || (live && armed))) {
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
                    armed: armed,
                    height: _cell.height,
                    idPrefix: 'daemon-key-$key',
                    onAnswer: press,
                  ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (fromPair && name != null)
                          TextSpan(
                            text: daemonPairNick(name),
                            style: style(true),
                          ),
                        TextSpan(text: split.rest),
                      ],
                    ),
                    // Whole: harnessd bounds a line (140 characters).
                    style: _ink(ink),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    final extra = [
      if (harness != null)
        Padding(
          padding: EdgeInsets.only(left: _cell.width * 2),
          child: Text(
            harness,
            key: ValueKey('daemon-harness-$key'),
            style: _ink(_muted),
          ),
        ),
      for (final item in listing)
        Padding(
          padding: EdgeInsets.only(left: _cell.width * 2),
          child: Text('- $item', style: _ink()),
        ),
      if (detail != null && detail.isNotEmpty)
        Padding(
          padding: EdgeInsets.only(left: _cell.width * 2),
          child: DaemonDetailBox(
            key: ValueKey('daemon-detail-$key'),
            text: detail,
            style: _ink(_muted),
            rowHeight: _cell.height,
            maxRows: 10,
            background: Color.lerp(_theme.background, _theme.foreground, .05),
          ),
        ),
    ];
    final whole = extra.isEmpty
        ? row
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [row, ...extra],
          );
    if (shownId == null || _brain == null) return whole;
    _liveShown.add(shownId);
    return KeyedSubtree(
      key: _shownRows.putIfAbsent(
        shownId,
        () => GlobalKey(debugLabel: 'daemon shown $shownId'),
      ),
      child: whole,
    );
  }

  /// A setting that waits for the person's yes: exactly what changes, then
  /// y (confirm) or n (keep it as it is), sent as `daemon_confirm`.
  Widget _confirmRow(List<String> order, DaemonConfirm confirm) {
    final key = 'confirm:${confirm.id}';
    order.add(key);
    return Padding(
      padding: EdgeInsets.only(top: _cell.height / 2),
      child: _keyRow(
        key,
        line: confirm.line,
        actions: confirm.actions,
        color: _theme.yellow,
        shownId: confirm.id,
        detail: confirm.detail,
        listing: confirm.kind == 'rules'
            ? pairConfigTurnsOn(confirm.detail)
            : const [],
        onKey: (action) => widget.onAnswer?.call(confirm.id, action, null),
      ),
    );
  }

  // ── now ────────────────────────────────────────────────────────────────────

  /// What waits for your key, the brief, what it did, and the talk.
  List<Widget> _pairNowSections(List<String> order, String name) {
    final brain = _brain;
    if (brain == null || !brain.active) return const [];
    return [
      ..._asksSection(order, brain, name),
      if (_pairLive) ...[
        ..._briefSection(order, brain),
        ..._didSection(order, brain, name),
        ..._talkSection(order, brain, name),
      ],
    ];
  }

  List<Widget> _asksSection(
    List<String> order,
    DaemonBrain brain,
    String name,
  ) {
    final state = brain.state!;
    final rows = <Widget>[];
    for (final confirm in state.confirms) {
      rows.add(_confirmRow(order, confirm));
    }
    for (final ask in _pairLive ? state.asks : const <DaemonAsk>[]) {
      order.add('ask:${ask.id}');
      rows.add(
        _keyRow(
          'ask:${ask.id}',
          line: ask.line,
          actions: ask.actions,
          color: _theme.yellow,
          shownId: ask.id,
          detail: ask.detail,
          harness: ask.harness?.label,
          fromPair: ask.fromPair,
          name: name,
          onKey: (action) => widget.onAnswer?.call(ask.id, action, null),
        ),
      );
    }
    for (final need in _pairLive ? state.needs : const <DaemonNeed>[]) {
      final about = DaemonAbout(
        need.machineId,
        need.agentId,
        requestId: need.requestId,
      );
      // Its keys work only while its line shows; after that, [g] opens it.
      final live = need.sayId != null && need.line != null;
      const open = (key: 'g', label: 'open', choice: 'open');
      final actions = live ? need.actions : const [open];
      final keyed = live && need.actions.any((a) => a.key != 'g');
      order.add('need:${need.key}');
      rows.add(
        _keyRow(
          'need:${need.key}',
          line: live
              ? need.line!
              : '[g] ${need.who}: ${need.question.isEmpty ? 'waits on you' : need.question}',
          actions: actions.any((a) => a.key == 'g')
              ? actions
              : [...actions, open],
          color: _theme.yellow,
          shownId: keyed ? need.sayId : null,
          detail: keyed ? need.detail : null,
          harness: keyed ? need.who : null,
          onKey: (action) =>
              widget.onAnswer?.call(need.sayId ?? '', action, about),
        ),
      );
    }
    if (rows.isEmpty) return const [];
    return [_header('waits for you'), ...rows];
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
      for (final (i, item) in brief.items.indexed)
        () {
          final key = 'brief:${item.id.isEmpty ? i : item.id}';
          order.add(key);
          final about = item.about;
          final keyed =
              live &&
              item.id.isNotEmpty &&
              item.actions.any((a) => a.key != 'g');
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
            shownId: keyed ? item.id : null,
            detail: keyed || item.kind == 'lesson' ? item.shows : null,
            onKey: (action) => widget.onAnswer?.call(item.id, action, about),
          );
        }(),
    ];
  }

  /// "What `name` did": the journal of what a rule or the pair did on its
  /// own, and the lessons it taught, newest first. A lesson reverts with one
  /// `harness pair lessons revert`; an answer typed into a harness cannot be
  /// taken back, and it says so.
  List<Widget> _didSection(
    List<String> order,
    DaemonBrain brain,
    String name,
  ) {
    final acted = brain.state!.acted;
    final lessons = _lessons;
    final taught = [
      for (final l in lessons?.lessons ?? const <DaemonLesson>[])
        if (l.approvedNow) l,
    ];
    if (acted.isEmpty && taught.isEmpty) return const [];
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

    String who(String by) => switch (by) {
      'rule' => 'a rule',
      'pair' => name,
      'remote' => 'another machine',
      _ => by,
    };
    return [
      _header('what $name did', key: const ValueKey('daemon-panel-did')),
      for (final a in acted.take(5))
        Text(
          '${who(a.by)}: ${a.name} '
          '${a.text.isNotEmpty ? a.text : a.action.isNotEmpty ? a.action : 'acted'}'
          '${ago(a.at)}',
          key: ValueKey('daemon-did-${a.machineId}-${a.agentId}-${a.at?.millisecondsSinceEpoch}'),
          style: _ink(_muted),
        ),
      if (acted.isNotEmpty)
        Padding(
          padding: EdgeInsets.only(left: _cell.width * 2),
          child: Text(
            'an answer typed into a harness cannot be taken back.',
            key: const ValueKey('daemon-did-no-revert'),
            style: _ink(_muted.withValues(alpha: .45)),
          ),
        ),
      for (final lesson in taught.take(5))
        () {
          order.add('did-revert:${lesson.id}');
          return Row(
            children: [
              Expanded(
                child: Text(
                  '${lesson.kind == 'note' ? 'noted${lesson.project == null ? '' : ' for ${lesson.project}'}' : 'taught ${lesson.title}'}'
                  '${lesson.approved == null ? '' : ' · ${lesson.approved}'}',
                  style: _ink(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _action(
                'did-revert:${lesson.id}',
                '[ revert ]',
                lessons!.busy
                    ? null
                    : () => unawaited(lessons.revert(lesson.id)),
                tooltip: 'harness pair lessons revert: every agent forgets it',
              ),
            ],
          );
        }(),
    ];
  }

  List<Widget> _talkSection(
    List<String> order,
    DaemonBrain brain,
    String name,
  ) {
    order.add('talk');
    final wait = brain.talkWait;
    if (wait != null) {
      _talkTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (brain.talkWait == null) {
          _talkTicker?.cancel();
          _talkTicker = null;
        }
        setState(() {});
      });
    }
    final status = wait != null
        ? 'six talks a minute, sixty an hour. again in '
              '${(wait.inMilliseconds / 1000).ceil()}s.'
        : switch (brain.talkPhase) {
            DaemonTalkPhase.waking => 'waking $name...',
            DaemonTalkPhase.started =>
              "$name's harness is starting. its answer comes here.",
            DaemonTalkPhase.resumed => "$name's harness was paused. resuming.",
            DaemonTalkPhase.sent => 'sent.',
            DaemonTalkPhase.failed =>
              brain.talkError ?? 'that did not go through.',
            DaemonTalkPhase.idle => null,
          };
    final talk = brain.talk;
    final canOpen = widget.onOpenConversation != null;
    if (canOpen) order.add('conversation');
    return [
      _header(
        'talk to $name',
        trailing: widget.talkShortcut == null
            ? null
            : Text(widget.talkShortcut!, style: _ink(_muted)),
      ),
      for (final entry in talk.skip(max(0, talk.length - 4)))
        Text(
          entry.you ? 'you > ${entry.text}' : '<$name> ${entry.text}',
          style: _ink(entry.you ? _muted : null),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      if (status != null)
        Text(
          status,
          key: const ValueKey('daemon-talk-status'),
          style: _ink(
            brain.talkPhase == DaemonTalkPhase.failed && wait == null
                ? _theme.red
                : _muted,
          ),
        ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('> ', style: _ink(_muted)),
          Expanded(
            child: TextField(
              key: const ValueKey('daemon-talk-input'),
              controller: _talk,
              focusNode: _talkFocus,
              enabled: wait == null,
              maxLines: 1,
              maxLength: 2000,
              style: _ink(),
              cursorWidth: _cell.width,
              cursorHeight: _cell.height,
              cursorColor: _theme.cursor,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: wait == null
                    ? 'ask $name something'
                    : 'wait ${(wait.inMilliseconds / 1000).ceil()}s',
                hintStyle: _ink(_muted.withValues(alpha: .4)),
                counterText: '',
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (_) {
                _send();
                _talkFocus.requestFocus();
              },
            ),
          ),
        ],
      ),
      // Every talk is a turn of the person's own engine: said, as harnessd
      // says it with each answer.
      Text(
        brain.talkCost ??
            'each talk is a turn of $name\'s harness on your engine: '
                'it spends your model usage.',
        key: const ValueKey('daemon-talk-cost'),
        style: _ink(_muted.withValues(alpha: .45)),
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

  // ── lessons ────────────────────────────────────────────────────────────────

  List<Widget> _lessonsTab(List<String> order, String name) {
    final brain = _brain;
    final lessons = _lessons;
    if (brain == null || lessons == null || !_pairLive) {
      return [
        Text(
          brain == null || !brain.active
              ? 'lessons need a harnessd with a pair brain on this computer.'
              : '$name learns once it watches, and proposes what it notices.',
          key: const ValueKey('daemon-lessons-empty'),
          style: _ink(_muted),
        ),
      ];
    }
    // The one lesson being proposed now: its whole text, then its keys.
    final live = brain.state!.asks.where((a) => a.isLesson).toList();
    final liveIds = {for (final a in live) ?a.lessonId};
    final rows = <Widget>[];
    for (final ask in live) {
      order.add('lesson-ask:${ask.id}');
      rows.add(
        _keyRow(
          'lesson-ask:${ask.id}',
          line: ask.line,
          actions: ask.actions.where((a) => a.key != 's').toList(),
          color: _theme.yellow,
          shownId: ask.id,
          detail: ask.detail,
          onKey: (action) => widget.onAnswer?.call(ask.id, action, null),
        ),
      );
    }
    for (final lesson in lessons.lessons) {
      if (liveIds.contains(lesson.id)) continue;
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: _cell.height / 2),
          child: Text(
            '${lesson.pending ? 'pending' : 'learned'} ${lesson.title}'
            '${lesson.approved == null ? '' : ' · ${lesson.approved}'}',
            key: ValueKey('daemon-lesson-${lesson.id}'),
            style: _ink(lesson.pending ? _theme.yellow : null),
          ),
        ),
      );
      if (lesson.description.isNotEmpty) {
        rows.add(
          Padding(
            padding: EdgeInsets.only(left: _cell.width * 2),
            child: Text(lesson.description, style: _ink(_muted)),
          ),
        );
      }
      if (lessons.shownId == lesson.id && lessons.shownText != null) {
        rows.add(
          Padding(
            padding: EdgeInsets.only(left: _cell.width * 2),
            child: DaemonDetailBox(
              key: ValueKey('daemon-lesson-text-${lesson.id}'),
              text: lessons.shownText!,
              style: _ink(_muted),
              rowHeight: _cell.height,
              maxRows: 14,
              background: Color.lerp(_theme.background, _theme.foreground, .04),
            ),
          ),
        );
      }
      final id = lesson.id;
      order.add('lesson-show:$id');
      final buttons = <Widget>[
        _action(
          'lesson-show:$id',
          lessons.shownId == id ? '[ hide ]' : '[ show ]',
          lessons.busy ? null : () => unawaited(lessons.show(id)),
        ),
      ];
      if (lesson.pending) {
        order.add('lesson-skip:$id');
        buttons.add(
          _action(
            'lesson-skip:$id',
            '[ skip ]',
            lessons.busy ? null : () => unawaited(lessons.skip(id)),
            tooltip: 'Never proposed again',
          ),
        );
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
      rows.add(
        Padding(
          padding: EdgeInsets.only(left: _cell.width * 2),
          child: Wrap(spacing: _cell.width * 2, children: buttons),
        ),
      );
      // Teaching is the person's alone: the lesson's own line, or a
      // terminal. The window never approves on its own say-so.
      if (lesson.pending) {
        rows.add(
          Padding(
            padding: EdgeInsets.only(left: _cell.width * 2),
            child: Text(
              'to teach it: its [y] when $name proposes it, or '
              '`${DaemonLessons.approveCommand(id)}` in a terminal.',
              key: ValueKey('daemon-lesson-how-$id'),
              style: _ink(_muted.withValues(alpha: .45)),
            ),
          ),
        );
      }
    }
    return [
      if (lessons.loaded && lessons.lessons.isEmpty && live.isEmpty)
        Text(
          'nothing learned yet. it proposes what it notices.',
          style: _ink(_muted),
        ),
      ...rows,
      if (lessons.message != null)
        Padding(
          padding: EdgeInsets.only(top: _cell.height / 2),
          child: Text(
            lessons.message!,
            key: const ValueKey('daemon-lessons-message'),
            style: _ink(_muted),
          ),
        ),
      if (lessons.note != null) Text(lessons.note!, style: _ink(_muted)),
    ];
  }

  // ── settings: the dial, the rules, consent ─────────────────────────────────

  List<Widget> _autonomySection(List<String> order, String name) {
    final zooController = face.zoo;
    final brain = _brain;
    // What it acts at now (harnessd's word), and what the dial asks for.
    final acting = brain?.autonomy ?? zoo.autonomy;
    final asked = brain?.state?.autonomyRequested;
    final confirms = brain?.state?.confirms ?? const <DaemonConfirm>[];
    final watching = zoo.watching;
    return [
      _header('autonomy'),
      if (!watching)
        Text(
          '$name does not watch yet: the dial waits for that yes first.',
          key: const ValueKey('daemon-panel-dial-waits'),
          style: _ink(_muted),
        ),
      for (final (id, (label, words)) in daemonAutonomyWords.entries.map(
        (e) => (e.key, e.value),
      )) ...[
        () {
          order.add('autonomy:$id');
          final mark = acting == id
              ? '(*)'
              : asked == id
              ? '(~)'
              : '( )';
          return _action(
            'autonomy:$id',
            '$mark $label${asked == id && acting != id ? '  waits for your yes' : ''}',
            watching ? () => zooController.autonomy(id) : null,
            color: acting == id
                ? _theme.cursor
                : asked == id
                ? _theme.yellow
                : _theme.foreground,
            tooltip: words,
          );
        }(),
        Padding(
          padding: EdgeInsets.only(left: _cell.width * 4),
          child: Text(words, style: _ink(_muted)),
        ),
        for (final confirm in confirms)
          if (confirm.kind == 'autonomy' && confirm.level == id)
            _confirmRow(order, confirm),
      ],
      // A raise the brain is asking about for a level not listed above.
      for (final confirm in confirms)
        if (confirm.kind == 'autonomy' &&
            !daemonAutonomyWords.containsKey(confirm.level))
          _confirmRow(order, confirm),
      Padding(
        padding: EdgeInsets.only(top: _cell.height / 2),
        child: Text(
          'the floor, at every level: $daemonFloorLine',
          key: const ValueKey('daemon-panel-floor'),
          style: _ink(),
        ),
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
      for (final confirm in confirms)
        if (confirm.kind == 'rules') _confirmRow(order, confirm),
    ];
  }

  /// Whether the daemon may watch at all (`zoo.consent`). In settings: what
  /// was answered, and a way to change it. [inline] (the now tab, before any
  /// answer or after a no): the short screen itself.
  List<Widget> _consentSection(
    List<String> order,
    String name, {
    bool inline = false,
  }) {
    final consent = zoo.consent;
    final step = _consentStep;
    final controller = face.zoo;
    Widget screen(DaemonConsentStep step) => Padding(
      padding: EdgeInsets.only(top: _cell.height / 2),
      child: DaemonConsent(
        name: name,
        step: step,
        // Opened by a key or a click: its yes takes the keyboard.
        autofocus: _consentStep != null,
        onWatch: () {
          controller.consent(watching: true);
          setState(() => _consentStep = DaemonConsentStep.suggest);
          _refocus();
        },
        onNotNow: () {
          controller.consent(watching: false);
          setState(() => _consentStep = null);
          _refocus();
        },
        onSuggest: () {
          controller.autonomy('suggest');
          setState(() => _consentStep = null);
          _refocus();
        },
        onKeepWatch: () {
          setState(() => _consentStep = null);
          _refocus();
        },
      ),
    );
    if (step == DaemonConsentStep.suggest) {
      return [_header('consent'), screen(DaemonConsentStep.suggest)];
    }
    if (inline) {
      // Before any answer: the screen itself. After a no: one line and a
      // way back.
      if (consent == null || step == DaemonConsentStep.watch) {
        return [_header('consent'), screen(DaemonConsentStep.watch)];
      }
      order.add('consent');
      return [
        _header('consent'),
        Text(
          '$name does not watch: nothing is sensed, journaled or learned.',
          key: const ValueKey('daemon-panel-consent'),
          style: _ink(_muted),
        ),
        _action(
          'consent',
          '[ review what $name sees ]',
          () => setState(() => _consentStep = DaemonConsentStep.watch),
        ),
      ];
    }
    if (step == DaemonConsentStep.watch) {
      return [_header('consent'), screen(DaemonConsentStep.watch)];
    }
    order.add('consent');
    final since = consent?.at == null || consent!.at.length < 10
        ? ''
        : ' since ${consent.at.substring(0, 10)}';
    return [
      _header('consent'),
      Text(
        consent?.watching == true
            ? '$name watches your harnesses$since.'
            : consent == null
            ? '$name has not been asked yet: it watches nothing.'
            : '$name does not watch$since.',
        key: const ValueKey('daemon-panel-consent'),
        style: _ink(_muted),
      ),
      _action(
        'consent',
        consent?.watching == true
            ? '[ stop watching ]'
            : '[ review what $name sees ]',
        consent?.watching == true
            ? () => controller.consent(watching: false)
            : () => setState(() => _consentStep = DaemonConsentStep.watch),
        tooltip: consent?.watching == true
            ? 'Every harnessd stops sensing; the dial goes back to watch.'
            : null,
      ),
    ];
  }
}
