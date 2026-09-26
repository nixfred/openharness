/// The paired daemon's face in the status line: its mood, its blinks, the
/// frames it steps through while agents work, the small tally beside it and
/// the one line it says.
///
/// The rules are the README's (`daemons/README.md`, Moods, Motion and blinks,
/// Voice). Moods come from work, never from the clock: there is no idle timer.
///
/// - **Motion** is driven by work, not by time: while agents work, the work
///   frame steps once per real agent event ([pulse]), at most twice a second,
///   so a baton that stops means an agent that stopped. The only timers end a
///   held reaction, run a blink or the return wave, end a nap and clear a line.
///   Reduce Motion, a background window and the Motion setting stop them all;
///   the face still changes.
/// - **Interruptions**: only a harness waiting on you and a failure take over
///   the status line, in the message yellow, at most one line nobody asked for
///   every two minutes, never about the pane in front of you, and only after
///   Enter, a pane switch or 8 s without a key. Finished turns become `+3`
///   beside the daemon, cleared when you look. Replies (a boop, its first
///   words, why an answer failed) are dim. Quiet silences everything.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'daemon_brain.dart';
import 'daemon_lines.dart';
import 'daemon_settings.dart';
import 'render.dart';
import 'roster.dart';
import 'zoo.dart';
import 'zoo_controller.dart';

/// A harness a line may be about: `machineId/agentId`, with what the window
/// knows of it to fill a line's slots.
@immutable
class DaemonSubject {
  const DaemonSubject(this.key, {this.who, this.q, this.recap, this.since});

  /// `machineId/agentId`.
  final String key;

  /// `engine@machine`.
  final String? who;

  /// Its question, its turn's recap, and since when it has waited.
  final String? q, recap;
  final DateTime? since;
}

/// A turn that ended in a harness this window can see, newest last.
@immutable
class DaemonTurnEnd {
  const DaemonTurnEnd(this.subject, {this.failed = false});
  final DaemonSubject subject;
  final bool failed;
}

/// What the workspace is doing, as the daemon watches it.
@immutable
class DaemonWatch {
  const DaemonWatch({
    this.working = false,
    this.workingCount = 0,
    this.needIds = const {},
    this.needs = const {},
    this.failing = false,
    this.failed = const [],
    this.turns = const {},
    this.fails = const {},
    this.ended = const {},
    this.idleCount = 0,
    this.focus,
    this.away = const [],
  });

  /// Any agent is working, and how many.
  final bool working;
  final int workingCount;

  /// Harnesses waiting on you, by a stable id per question
  /// (`machineId/agentId#requestId`), and what is known of each.
  final Set<String> needIds;
  final Map<String, DaemonSubject> needs;

  /// A harness you have open failed to start or its last turn failed. A
  /// machine that is asleep or unreachable is not a failure ([away]).
  final bool failing;
  final List<DaemonSubject> failed;

  /// Finished and failed turns you started, counted per machine, and the
  /// last few that ended per machine (who they were).
  final Map<String, int> turns, fails;
  final Map<String, List<DaemonTurnEnd>> ended;

  /// Open harnesses with nothing to do.
  final int idleCount;

  /// The pane in front of you, `machineId/agentId`: never spoken about.
  final String? focus;

  /// Machines that are asleep or unreachable, by name: shown calmly.
  final List<String> away;
}

enum _LineKind {
  /// Something needs you or failed: the message line, in yellow.
  alert,

  /// You asked (a boop, a hatch, an answer): dim, in the status line's ink.
  reply,
}

class DaemonFace extends ChangeNotifier {
  DaemonFace(
    this.zoo, {
    DaemonRoster? roster,
    DateTime Function()? now,
    DaemonSettings? settings,
  }) : roster = roster ?? zoo.roster,
       settings = settings ?? DaemonSettings(),
       _ownsSettings = settings == null,
       _now = now ?? DateTime.now {
    zoo.addListener(_zooChanged);
    this.settings.addListener(_settingsChanged);
    _events = zoo.events.listen(_zooEvent);
  }

  final ZooController zoo;
  final DaemonSettings settings;
  final bool _ownsSettings;
  late final StreamSubscription<ZooEvent> _events;

  /// How long a new egg shows in the slot before the daemon comes back.
  static const eggShowFor = Duration(seconds: 3);
  final DaemonRoster roster;
  final DateTime Function() _now;

  static const doneCooldown = Duration(seconds: 20);
  static const backAfter = Duration(minutes: 15);
  static const napLength = Duration(minutes: 15);
  static const lookEvery = Duration(milliseconds: 2500);
  static const voiceFor = Duration(milliseconds: 5200);

  /// A line nobody asked for waits until 8 s after the last key (or Enter,
  /// or a pane switch), and is dropped if it still waits after 20 s.
  static const typingQuiet = Duration(seconds: 8);
  static const voiceExpires = Duration(seconds: 20);

  /// At most one line nobody asked for this often.
  static const unsolicitedEvery = Duration(minutes: 2);

  /// Work frames step at most this often.
  static const stepEvery = Duration(milliseconds: 500);

  /// How long a roster line waits for the brain's own line about the same
  /// moment (`daemons/BRAIN.md`: prefer a `daemon_say` within 2.5 s).
  static const brainWait = Duration(milliseconds: 2500);

  /// A line with answers stays up this long unless its `ttlMs` says otherwise
  /// or it is answered, withdrawn or dismissed.
  static const askFor = Duration(seconds: 30);

  bool _disposed = false;
  bool _foreground = true, _reduceMotion = false;
  bool _revealing = false;

  // What it watches.
  bool _working = false, _failing = false;
  int _workingCount = 0, _idleCount = 0;
  Set<String> _needIds = const {};
  Map<String, DaemonSubject> _needs = const {};
  List<DaemonSubject> _failed = const [];
  List<String> _away = const [];
  String? _focus;
  final _heardNeeds = <String>{};
  final _turns = <String, int>{}, _fails = <String, int>{};
  bool _baselined = false;

  // The tally: finished turns since you looked, and while you were away.
  int _doneCount = 0, _doneWhileAway = 0;

  // Held faces.
  DaemonMood? _held;
  Timer? _holdTimer;
  bool _booped = false;
  Timer? _boopTimer;
  DateTime? _napUntil;
  Timer? _napTimer;
  DateTime? _awayAt, _lastDone, _lastLook;

  // Blinks, work steps and the wave.
  String? _lid;
  Timer? _blinkTimer;
  int _step = 0;
  DateTime? _lastStep;
  Timer? _stepTimer;
  int _backT = 0;
  Timer? _backTimer;

  // Voice.
  final _voice = ValueNotifier<String?>(null);
  Timer? _voiceTimer;
  _Line? _pendingVoice;
  _Line? _spoken;
  DateTime? _lastUnsolicited;

  /// Whether this harnessd's pair brain is talking (it sent `daemon_state`).
  bool brainActive = false;
  Timer? _pendingTimer;
  DateTime? _lastKey;

  /// A dialog, picker or the reveal is open: lines wait.
  bool Function() dialogOpen = _never;
  static bool _never() => false;

  String? _pairKey;
  ZooEgg? _arriving;
  Timer? _arrivingTimer;

  // ── what it shows ──────────────────────────────────────────────────────────

  bool get visible => zoo.loaded;
  bool get motionEnabled => _foreground && !_reduceMotion && settings.motion;
  bool get revealing => _revealing;
  bool get napping => _napUntil != null;
  bool get quiet => settings.quiet;

  /// The paired daemon, withheld while its hatch reveal is still running.
  ZooDaemon? get daemon => _revealing ? null : zoo.paired;
  DaemonDef? get def => roster.byId(daemon?.id);
  String get name => daemon?.nickname ?? def?.id ?? '';
  int get versionIndex => roster.versionIndex(daemon?.version);
  bool get shiny => daemon?.shiny == true;

  bool get eggReady => daemon == null && zoo.readyEgg != null;

  DaemonMood get mood {
    if (_booped) return DaemonMood.boop;
    if (_needIds.isNotEmpty) return DaemonMood.need;
    if (napping) return DaemonMood.nap;
    if (_held case final held?) return held;
    if (_working) return DaemonMood.work;
    if (_failing) return DaemonMood.fail;
    return DaemonMood.idle;
  }

  /// The blink lid for this instant, or null.
  String? get lid => _lid;

  /// Milliseconds into the sprite's current motion: whole steps of its work
  /// frames (or the borrowed baton's), or of the return wave.
  int get t {
    final d = def;
    if (d == null) return 0;
    if (mood == DaemonMood.back) return _backT;
    if (mood != DaemonMood.work) return 0;
    final last = versionIndex == roster.rules.versions.length - 1;
    return _step * (last ? d.workMs : 130);
  }

  /// The same steps for the portrait's moving parts, one frame each.
  int get portraitT {
    final d = def;
    if (d == null || mood != DaemonMood.work) return 0;
    final ms = d.parts.values.firstOrNull?.ms ?? d.workMs;
    return _step * ms;
  }

  /// How many work steps have been taken since agents started working.
  int get steps => _step;

  /// How an egg looks in the nest: the first egg's ready face, or its kind's
  /// look (`rules.eggs[kind].look`).
  String eggLook(ZooEgg egg) => egg.kind == 'first'
      ? roster.rules.nest.last
      : roster.rules.eggs[egg.kind]?.look ?? roster.rules.nest.last;

  /// Eggs waiting to be hatched.
  int get eggsWaiting => zoo.zoo.eggs.length;

  /// Finished turns since you last looked.
  int get doneCount => _doneCount;

  /// Machines asleep or unreachable, by name.
  List<String> get away => _away;

  /// The slot shows the daemon itself (not a new egg's moment in the nest).
  bool get showsDaemon => def != null && !_showsArrival;

  bool get _showsArrival =>
      _arriving != null &&
      mood != DaemonMood.need &&
      mood != DaemonMood.boop;

  /// The sprite, nest or egg for the status slot (at most eight cells).
  String get glyph {
    if (!visible) return '';
    final d = def;
    if (d == null) {
      if (_revealing) return roster.rules.nest.last;
      final egg = zoo.readyEgg;
      if (egg != null) return eggLook(egg);
      return nestFor(roster, zoo.habitsDone);
    }
    // A new egg sits in the nest for a moment, unless something needs you.
    if (_showsArrival) return eggLook(_arriving!);
    return renderSprite(
      roster,
      d,
      versionIndex,
      mood,
      t: t,
      lid: _lid,
      motion: motionEnabled,
    );
  }

  /// The slot's ten cells: the glyph centred on the version's base sprite (so
  /// a baton or a nap's `z` never moves the face), a gutter each side, and a
  /// shiny daemon's `*` in the left gutter.
  String get cell {
    final g = glyph;
    if (g.isEmpty) return '';
    final d = def;
    final daemonShown = d != null && !_showsArrival;
    var c = statusCell(
      roster,
      g,
      daemonShown ? baseWidth(roster, d, versionIndex) : null,
    );
    final width = roster.rules.statusCells + 2;
    if (c.length > width && c.substring(width).trim().isEmpty) {
      c = c.substring(0, width);
    }
    if (daemonShown && shiny) c = '*${c.substring(1)}';
    return c;
  }

  /// Beside the slot: `+3` turns finished since you looked, `+1 egg` while
  /// eggs wait to be opened. Empty before the first hatch (the slot is the
  /// egg then) and while a reveal runs.
  String get tally {
    if (!visible || _revealing || def == null) return '';
    final eggs = eggsWaiting;
    return [
      if (_doneCount > 0) '+$_doneCount',
      if (eggs > 0) '+$eggs ${eggs == 1 ? 'egg' : 'eggs'}',
    ].join(' ');
  }

  /// `tim: bell in codex@office: run the migration?` while it speaks.
  String? get voice => _voice.value;

  /// Only the spoken line, for what swaps the status line's context: it does
  /// not change on every work frame.
  ValueListenable<String?> get voiceLine => _voice;

  /// Whether the line being spoken is an alert (needs you, failed): the
  /// message yellow. Otherwise it is a reply, in the status line's own ink.
  bool get voiceAlert => _spoken?.kind == _LineKind.alert;

  /// The brain's answers offered with the line being spoken: `[y] [n]`.
  List<DaemonAction> get voiceActions => _spoken?.actions ?? const [];

  /// The brain's id for the line being spoken, to answer it.
  String? get voiceSayId => _spoken?.sayId;

  static const moodWords = {
    DaemonMood.idle: 'content',
    DaemonMood.work: 'agents working',
    DaemonMood.need: 'a harness needs you',
    DaemonMood.done: 'a turn finished',
    DaemonMood.fail: 'something failed',
    DaemonMood.back: 'welcome back',
    DaemonMood.nap: 'napping',
    DaemonMood.boop: 'booped',
  };

  String get label {
    if (_revealing) return 'Hatching';
    if (def != null) return name;
    return eggReady ? 'Egg, ready to hatch' : 'Egg';
  }

  String get detail {
    if (_revealing) return 'Hatching';
    final d = def;
    if (d != null) {
      final eggs = eggsWaiting;
      return '${d.id} ${daemon!.version}, ${moodWords[mood]}'
          '${_doneCount == 0 ? '' : ', $_doneCount finished since you looked'}'
          '${eggs == 0 ? '' : ', $eggs ${eggs == 1 ? 'egg' : 'eggs'} waiting'}';
    }
    if (eggReady) {
      return eggsWaiting > 1
          ? 'Ready to hatch, $eggsWaiting eggs'
          : 'Ready to hatch';
    }
    return '${zoo.habitsDone} of ${zoo.habitsNeeded} habits';
  }

  String get tooltip {
    if (_revealing) return 'Hatching...';
    final d = def;
    if (d != null) {
      final eggs = zoo.zoo.eggs;
      return [
        '$name · ${moodWords[mood]}',
        '${d.id} ${daemon!.version}',
        if (_doneCount > 0)
          '+$_doneCount: ${_doneCount == 1 ? 'a turn' : 'turns'} finished '
              'since you looked',
        if (eggs.isNotEmpty)
          '${eggLook(eggs.first)} x${eggs.length} waiting. Click to open.',
        for (final machine in _away) '$machine is asleep or unreachable.',
        if (quiet) 'Quiet: it says nothing until you turn Quiet off.',
      ].join('\n');
    }
    if (eggReady) {
      final egg = zoo.readyEgg!;
      return eggsWaiting > 1
          ? '${eggLook(egg)} x$eggsWaiting. Your egg is ready. '
                'Click to hatch it.'
          : 'Your egg is ready. Click to hatch it.';
    }
    return 'A daemon is incubating: ${zoo.habitsDone} of '
        '${zoo.habitsNeeded} habits.\nClick to see them.';
  }

  // ── lines ──────────────────────────────────────────────────────────────────

  /// What the window knows right now for a line's slots.
  Map<String, String?> slotsFor(DaemonMood mood, [DaemonSubject? subject]) {
    final about =
        subject ??
        switch (mood) {
          DaemonMood.need => _needs.values.firstOrNull,
          DaemonMood.fail => _failed.firstOrNull,
          _ => null,
        };
    return {
      'who': slotValue(about?.who, limit: 32),
      'q': slotValue(about?.q, limit: 48),
      'recap': slotValue(about?.recap, limit: 60),
      'n': switch (mood) {
        DaemonMood.work => _workingCount > 0 ? '$_workingCount' : null,
        DaemonMood.need => _needIds.isEmpty ? null : '${_needIds.length}',
        DaemonMood.idle => '$_idleCount',
        DaemonMood.fail =>
          _failed.isNotEmpty
              ? '${_failed.length}'
              : subject != null
              ? '1'
              : null,
        DaemonMood.done => _doneCount > 0 ? '$_doneCount' : null,
        _ => null,
      },
      'summary': mood == DaemonMood.back ? _summary() : null,
    };
  }

  /// The brief's facts, as far as this window knows them:
  /// `2 done, 1 waiting 40m`. Null when there are none.
  String? _summary() {
    final waiting = _needIds.length;
    DateTime? oldest;
    for (final need in _needs.values) {
      final since = need.since;
      if (since != null && (oldest == null || since.isBefore(oldest))) {
        oldest = since;
      }
    }
    final parts = [
      if (_doneWhileAway > 0) '$_doneWhileAway done',
      if (waiting > 0)
        '$waiting waiting'
            '${oldest == null ? '' : ' ${_age(_now().difference(oldest))}'}',
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  static String _age(Duration d) => d.inHours >= 1
      ? '${d.inHours}h'
      : d.inMinutes >= 1
      ? '${d.inMinutes}m'
      : '${d.inSeconds}s';

  /// The line for [mood] now, for the panel: filled from what is known, the
  /// roster's example while nothing is going on, never a made-up fact.
  String currentLine(DaemonMood mood) {
    final d = def;
    if (d == null) return '';
    final values = slotsFor(mood);
    return mood == DaemonMood.idle
        ? daemonPreviewLine(d, mood, values)
        : daemonLine(d, mood, values);
  }

  // ── inputs ─────────────────────────────────────────────────────────────────

  void setEnvironment({required bool foreground, required bool reduceMotion}) {
    if (_disposed) return;
    final was = _foreground;
    final changed = _foreground != foreground || _reduceMotion != reduceMotion;
    _foreground = foreground;
    _reduceMotion = reduceMotion;
    if (!changed) return;
    if (!foreground) {
      if (_awayAt == null) {
        _awayAt = _now();
        _doneWhileAway = 0;
      }
      _stopBlink();
    } else if (!was) {
      final away = _awayAt;
      _awayAt = null;
      if (away != null && _now().difference(away) >= backAfter) {
        _back();
      } else {
        look(force: true);
      }
    }
    if (!motionEnabled) _stopBlink();
    _update(force: true);
  }

  void sync(DaemonWatch watch) {
    if (_disposed) return;
    final before = mood;
    final newNeeds = watch.needIds.difference(_heardNeeds);
    final finished = _newEnds(_turns, watch.turns, watch.ended, failed: false);
    final failed = _newEnds(_fails, watch.fails, watch.ended, failed: true);
    _working = watch.working;
    _workingCount = watch.workingCount;
    _failing = watch.failing;
    _failed = watch.failed;
    _needIds = watch.needIds;
    _needs = watch.needs;
    _idleCount = watch.idleCount;
    final awayChanged = !listEquals(watch.away, _away);
    _away = watch.away;
    final focusChanged = watch.focus != _focus;
    _focus = watch.focus;
    _heardNeeds.addAll(watch.needIds);
    if (_heardNeeds.length > 512) _heardNeeds.retainAll(watch.needIds);
    if (focusChanged) {
      // A pane switch is a pause in thought: a waiting line may speak now.
      // A line about the pane you just switched to has done its job.
      if (_spoken?.about != null && _spoken!.about == _focus) _silence();
      _lastKey = null;
      if (_pendingVoice != null) _trySpeak();
    }
    // Restored state, imported history and reconnects are baselines.
    if (!_baselined || def == null) {
      _baselined = def != null;
      _update(before: before, force: awayChanged);
      return;
    }
    final d = def!;
    if (newNeeds.isNotEmpty) {
      _napUntil = null;
      _napTimer?.cancel();
      _blink('ack', delay: const Duration(milliseconds: 160));
      // About a harness you are not looking at, if there is one.
      final id = newNeeds.firstWhere(
        (id) => _aboutOf(id) != _focus,
        orElse: () => newNeeds.first,
      );
      final subject = _needs[id];
      _say(
        daemonLine(d, DaemonMood.need, slotsFor(DaemonMood.need, subject)),
        mood: DaemonMood.need,
        kind: _LineKind.alert,
        about: subject?.key ?? _aboutOf(id),
      );
    }
    if (failed.isNotEmpty) {
      _hold(DaemonMood.fail);
      _blink('ack', delay: const Duration(milliseconds: 160));
      final subject = failed.whereType<DaemonSubject>().lastOrNull;
      if (newNeeds.isEmpty) {
        _say(
          daemonLine(d, DaemonMood.fail, slotsFor(DaemonMood.fail, subject)),
          mood: DaemonMood.fail,
          kind: _LineKind.alert,
          about: subject?.key,
        );
      }
    } else if (finished.isNotEmpty) {
      _blink('ack', delay: const Duration(milliseconds: 160));
      // Finished turns are a count beside the slot, never a line; the pane
      // in front of you is already seen.
      final unseen = finished.where((s) => s == null || s.key != _focus);
      _doneCount += unseen.length;
      if (!_foreground) _doneWhileAway += unseen.length;
      final now = _now();
      if (_lastDone == null || now.difference(_lastDone!) >= doneCooldown) {
        _lastDone = now;
        _hold(DaemonMood.done);
      }
    }
    _update(before: before, force: finished.isNotEmpty || awayChanged);
  }

  static String _aboutOf(String needId) {
    final hash = needId.indexOf('#');
    return hash < 0 ? needId : needId.substring(0, hash);
  }

  /// The turns that ended since the last count, one entry each: who they
  /// were when the window knows (newest last), null when it does not.
  static List<DaemonSubject?> _newEnds(
    Map<String, int> seen,
    Map<String, int> now,
    Map<String, List<DaemonTurnEnd>> ended, {
    required bool failed,
  }) {
    final out = <DaemonSubject?>[];
    for (final entry in now.entries) {
      final previous = seen[entry.key];
      seen[entry.key] = entry.value;
      if (previous == null || entry.value <= previous) continue;
      final count = entry.value - previous;
      final known = [
        for (final end in ended[entry.key] ?? const <DaemonTurnEnd>[])
          if (end.failed == failed) end.subject,
      ];
      final recent = known.length > count
          ? known.sublist(known.length - count)
          : known;
      out
        ..addAll(List<DaemonSubject?>.filled(count - recent.length, null))
        ..addAll(recent);
    }
    return out;
  }

  /// A real agent event (a tool starting, output arriving, a turn starting
  /// or ending): the work frame steps once, at most twice a second.
  void pulse() {
    if (_disposed ||
        def == null ||
        !motionEnabled ||
        mood != DaemonMood.work ||
        _stepTimer != null) {
      return;
    }
    final since = _lastStep == null ? null : _now().difference(_lastStep!);
    if (since == null || since >= stepEvery) {
      _advance();
      return;
    }
    _stepTimer = Timer(stepEvery - since, () {
      _stepTimer = null;
      _advance();
    });
  }

  void _advance() {
    if (_disposed || def == null || !motionEnabled || mood != DaemonMood.work) {
      return;
    }
    _step++;
    _lastStep = _now();
    _lastGlyph = glyph;
    notifyListeners();
  }

  /// A key went down somewhere in the window. Enter ends a thought: a line
  /// waiting for you may speak now. Any other key holds it for 8 s more.
  void noteKey({bool enter = false}) {
    if (enter) {
      _lastKey = null;
      if (_pendingVoice != null) _trySpeak();
    } else {
      _lastKey = _now();
    }
  }

  /// You looked at the slot (hover, its panel): the tally of finished turns
  /// has been seen.
  void seen() {
    if (_disposed || _doneCount == 0) return;
    _doneCount = 0;
    notifyListeners();
  }

  /// A click on the daemon.
  void boop() {
    if (_disposed || def == null) return;
    wake(notify: false);
    _booped = true;
    _boopTimer?.cancel();
    _boopTimer = Timer(roster.rules.hold(DaemonMood.boop), () {
      _booped = false;
      _update(force: true);
    });
    _say(
      def!.line(DaemonMood.boop),
      mood: DaemonMood.boop,
      kind: _LineKind.reply,
    );
    _update(force: true);
  }

  /// "I see you": hover, its panel opening, the window coming back.
  void look({bool force = false}) {
    if (_disposed || def == null) return;
    final now = _now();
    if (_lastLook != null && now.difference(_lastLook!) < lookEvery) return;
    _lastLook = now;
    _blink('look', delay: force ? const Duration(milliseconds: 250) : null);
  }

  void nap() {
    if (_disposed || def == null) return;
    _napUntil = _now().add(napLength);
    _napTimer?.cancel();
    _napTimer = Timer(napLength, () => wake());
    _update(force: true);
  }

  void wake({bool notify = true}) {
    if (_napUntil == null) return;
    _napUntil = null;
    _napTimer?.cancel();
    _napTimer = null;
    if (notify) _update(force: true);
  }

  /// The hatch reveal is running: the status slot keeps the egg and nothing
  /// names the hatchling until [endReveal].
  void beginReveal() {
    if (_disposed || _revealing) return;
    _revealing = true;
    _update(force: true);
  }

  /// The reveal finished or was dismissed. The daemon arrives and says its
  /// first words, with a slow blink: they have just met.
  void endReveal() {
    if (_disposed || !_revealing) return;
    _revealing = false;
    _baselined = false;
    final d = def;
    if (d != null) {
      _pairKey = daemon?.id;
      _blink('slow', delay: const Duration(milliseconds: 300));
      _say(d.first, mood: null, kind: _LineKind.reply);
    }
    _update(force: true);
  }

  void _zooChanged() {
    if (_disposed) return;
    final key = daemon?.id;
    if (key != _pairKey) {
      // A different pair: what it watches starts again from a baseline.
      _pairKey = key;
      _baselined = false;
      _held = null;
      _holdTimer?.cancel();
    }
    _update(force: true);
  }

  void _settingsChanged() {
    if (_disposed) return;
    if (settings.quiet) {
      _pendingVoice = null;
      _pendingTimer?.cancel();
      _silence();
    }
    if (!motionEnabled) _stopBlink();
    _update(force: true);
  }

  /// A new egg or a level-up, here or on another client. Neither is a line:
  /// the egg waits beside the slot (`+1 egg`) until it is opened, and a
  /// level-up is a slow blink.
  void _zooEvent(ZooEvent event) {
    if (_disposed) return;
    final d = def;
    switch (event) {
      case ZooEggArrived(:final egg):
        // Before the first hatch the slot already shows the egg itself.
        if (d == null) return;
        _arriving = egg;
        _arrivingTimer?.cancel();
        _arrivingTimer = Timer(eggShowFor, () {
          _arriving = null;
          _update(force: true);
        });
        _blink('ack', delay: const Duration(milliseconds: 160));
        _update(force: true);
      case ZooDaemonGrew(:final daemon):
        if (d == null || daemon.id != this.daemon?.id) return;
        // "I trust you": a slow blink.
        _blink('slow', delay: const Duration(milliseconds: 200));
        _update(force: true);
    }
  }

  // ── reactions ──────────────────────────────────────────────────────────────

  void _hold(DaemonMood held) {
    _held = held;
    _holdTimer?.cancel();
    _holdTimer = Timer(roster.rules.hold(held), () {
      _held = null;
      _update(force: true);
    });
  }

  /// Back after 15 minutes or more: it waves and blinks slowly. The brief
  /// (or the panel) carries the facts; no line takes over the status line.
  void _back() {
    if (def == null || _needIds.isNotEmpty || napping) return;
    _hold(DaemonMood.back);
    _blink(
      'slow',
      delay:
          roster.rules.hold(DaemonMood.back) +
          const Duration(milliseconds: 120),
    );
  }

  void _blink(String kind, {Duration? delay}) {
    final steps = roster.rules.blinks[kind];
    if (steps == null || !motionEnabled || def == null) return;
    _stopBlink();
    var index = 0;
    void step() {
      if (_disposed) return;
      if (index >= steps.length || !motionEnabled) {
        _lid = null;
        _blinkTimer = null;
        notifyListeners();
        return;
      }
      final (lid, ms) = steps[index++];
      // No blinks while working, napping or booped.
      _lid = roster.rules.noBlinkMoods.contains(mood.name) ? null : lid;
      notifyListeners();
      _blinkTimer = Timer(Duration(milliseconds: ms), step);
    }

    if (delay == null || delay == Duration.zero) {
      step();
    } else {
      _blinkTimer = Timer(delay, step);
    }
  }

  void _stopBlink() {
    _blinkTimer?.cancel();
    _blinkTimer = null;
    _lid = null;
  }

  // ── voice ──────────────────────────────────────────────────────────────────

  void _say(
    String line, {
    required DaemonMood? mood,
    required _LineKind kind,
    String? about,
  }) {
    if (line.isEmpty || quiet) return;
    // A reply never pushes aside an alert waiting to be said.
    if (kind == _LineKind.reply && _pendingVoice?.kind == _LineKind.alert) {
      return;
    }
    final now = _now();
    // With a brain, a roster alert waits a moment for the brain's own words.
    final waits = brainActive && kind == _LineKind.alert;
    _pendingVoice = _Line(
      line,
      at: now,
      mood: mood,
      kind: kind,
      about: about,
      holdUntil: waits ? now.add(brainWait) : null,
    );
    _trySpeak();
  }

  /// The brain's line (`daemon_say`). Only a harness waiting on you, a
  /// failure, or a line offering answers takes over the status line; the
  /// brain's other lines (a finished turn, a return) are carried by the tally
  /// and the brief. A line about the one already spoken replaces it in place.
  void sayFromBrain(DaemonSay say) {
    if (_disposed || def == null || quiet) return;
    final alert =
        say.mood == DaemonMood.need ||
        say.mood == DaemonMood.fail ||
        say.actions.isNotEmpty;
    if (!alert) return;
    final line = _Line(
      say.line,
      at: _now(),
      mood: say.mood,
      kind: _LineKind.alert,
      about: say.about,
      sayId: say.id,
      actions: say.actions,
      ttl: say.ttl,
    );
    final spoken = _spoken;
    if (spoken != null &&
        spoken.kind == _LineKind.alert &&
        say.about != null &&
        spoken.about == say.about) {
      _show(line, countsAsUnsolicited: false);
      return;
    }
    _pendingVoice = line;
    _trySpeak();
  }

  /// A line of the window's own, such as why an answer did not go through.
  void sayNote(String line) {
    if (_disposed || def == null) return;
    _say(line, mood: null, kind: _LineKind.reply);
  }

  /// `daemon_unsay`: answered elsewhere, gone, done or stale.
  void unsay(String id) {
    if (_pendingVoice?.sayId == id) _pendingVoice = null;
    if (_spoken?.sayId == id) _silence();
  }

  /// Escape: the line goes.
  void dismissVoice() => _silence();

  /// You answered the line: it goes, and since you are already with the
  /// daemon, the next question may follow without the two-minute wait.
  void answered() {
    _lastUnsolicited = null;
    _silence();
  }

  void _silence() {
    _voiceTimer?.cancel();
    _voiceTimer = null;
    _spoken = null;
    if (_voice.value == null) return;
    _voice.value = null;
    if (!_disposed) notifyListeners();
  }

  void _trySpeak() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    final pending = _pendingVoice;
    if (pending == null || _disposed) return;
    final now = _now();
    final unsolicited = pending.kind == _LineKind.alert;
    final stale =
        now.difference(pending.at) > (pending.ttl ?? voiceExpires) ||
        (pending.mood == DaemonMood.need &&
            pending.sayId == null &&
            _needIds.isEmpty) ||
        def == null ||
        quiet ||
        // Nothing about the pane in front of you.
        (pending.about != null && pending.about == _focus) ||
        // A nap keeps it quiet, except for what needs you.
        (napping && pending.mood != DaemonMood.need && unsolicited) ||
        // At most one line nobody asked for every two minutes.
        (unsolicited &&
            _lastUnsolicited != null &&
            now.difference(_lastUnsolicited!) < unsolicitedEvery);
    if (stale) {
      _pendingVoice = null;
      return;
    }
    Duration? wait;
    if (pending.holdUntil case final until? when now.isBefore(until)) {
      wait = until.difference(now);
    } else if (_lastKey case final key?
        when unsolicited && now.difference(key) < typingQuiet) {
      // Never mid-thought: after Enter, a pane switch or 8 s without a key.
      wait = typingQuiet - now.difference(key);
    } else if (dialogOpen() || !_foreground) {
      wait = const Duration(milliseconds: 500);
    }
    if (wait != null) {
      _pendingTimer = Timer(wait, _trySpeak);
      return;
    }
    _pendingVoice = null;
    _show(pending, countsAsUnsolicited: unsolicited);
  }

  void _show(_Line line, {required bool countsAsUnsolicited}) {
    _spoken = line;
    if (countsAsUnsolicited) _lastUnsolicited = _now();
    _voice.value = '$name: ${line.line}';
    _voiceTimer?.cancel();
    final showFor = line.actions.isEmpty ? voiceFor : line.ttl ?? askFor;
    _voiceTimer = Timer(showFor, _silence);
    notifyListeners();
  }

  // ── frames ─────────────────────────────────────────────────────────────────

  DaemonMood? _lastMood;
  String? _lastGlyph;

  void _update({DaemonMood? before, bool force = false}) {
    if (_disposed) return;
    final now = mood;
    _runMotion(now);
    final glyph = this.glyph;
    if (force || now != (before ?? _lastMood) || glyph != _lastGlyph) {
      _lastMood = now;
      _lastGlyph = glyph;
      notifyListeners();
    }
  }

  void _runMotion(DaemonMood now) {
    final d = def;
    // Work frames step only on agent events; leaving work puts them at rest.
    if (d == null || !motionEnabled || now != DaemonMood.work) {
      _stepTimer?.cancel();
      _stepTimer = null;
      _step = 0;
      _lastStep = null;
    }
    // The return wave is finite: it runs while `back` is held.
    final waving = d != null && motionEnabled && now == DaemonMood.back;
    if (!waving) {
      _backTimer?.cancel();
      _backTimer = null;
      _backT = 0;
      return;
    }
    if (_backTimer != null) return;
    final last = versionIndex == roster.rules.versions.length - 1;
    final ms = last ? roster.rules.backFrameMs : 130;
    _backTimer = Timer.periodic(Duration(milliseconds: ms), (_) {
      if (_disposed) return;
      _backT += ms;
      final glyph = this.glyph;
      if (glyph != _lastGlyph) {
        _lastGlyph = glyph;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    zoo.removeListener(_zooChanged);
    settings.removeListener(_settingsChanged);
    if (_ownsSettings) settings.dispose();
    unawaited(_events.cancel());
    for (final timer in [
      _arrivingTimer,
      _holdTimer,
      _boopTimer,
      _napTimer,
      _blinkTimer,
      _stepTimer,
      _backTimer,
      _voiceTimer,
      _pendingTimer,
    ]) {
      timer?.cancel();
    }
    _voice.dispose();
    super.dispose();
  }
}

class _Line {
  const _Line(
    this.line, {
    required this.at,
    required this.kind,
    this.mood,
    this.about,
    this.sayId,
    this.actions = const [],
    this.ttl,
    this.holdUntil,
  });
  final String line;
  final DateTime at;
  final _LineKind kind;
  final DaemonMood? mood;

  /// `machineId/agentId` of the harness it is about, when it is about one.
  final String? about;
  final String? sayId;
  final List<DaemonAction> actions;
  final Duration? ttl;

  /// A roster line waiting for the brain's words until then.
  final DateTime? holdUntil;
}
