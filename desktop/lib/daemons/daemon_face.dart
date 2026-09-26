/// The paired daemon's face in the status line: its mood, its blinks, the
/// frames it draws while agents work, and the one line it says.
///
/// The rules are the README's (`daemons/README.md`, Moods, Motion and blinks,
/// Voice). Moods come from work, never from the clock: there is no idle timer.
/// Timers exist only to end a held reaction, run a blink, step work frames
/// while agents work, end a nap, and clear a spoken line. Reduce Motion and a
/// background window stop every frame and blink; the face still changes.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'render.dart';
import 'roster.dart';
import 'zoo.dart';
import 'zoo_controller.dart';

/// What the workspace is doing, as the daemon watches it.
@immutable
class DaemonWatch {
  const DaemonWatch({
    this.working = false,
    this.needIds = const {},
    this.failing = false,
    this.turns = const {},
    this.fails = const {},
  });

  /// Any agent is working.
  final bool working;

  /// Harnesses waiting on you, by a stable id per question.
  final Set<String> needIds;

  /// A harness you have open is offline or failed to start.
  final bool failing;

  /// Finished and failed turns you started, counted per machine.
  final Map<String, int> turns, fails;
}

class DaemonFace extends ChangeNotifier {
  DaemonFace(this.zoo, {DaemonRoster? roster, DateTime Function()? now})
    : roster = roster ?? zoo.roster,
      _now = now ?? DateTime.now {
    zoo.addListener(_zooChanged);
  }

  final ZooController zoo;
  final DaemonRoster roster;
  final DateTime Function() _now;

  static const doneCooldown = Duration(seconds: 20);
  static const backAfter = Duration(minutes: 15);
  static const napLength = Duration(minutes: 15);
  static const lookEvery = Duration(milliseconds: 2500);
  static const voiceFor = Duration(milliseconds: 5200);
  static const typingQuiet = Duration(seconds: 2);
  static const voiceExpires = Duration(seconds: 10);

  bool _disposed = false;
  bool _foreground = true, _reduceMotion = false;
  bool _revealing = false;

  // What it watches.
  bool _working = false, _failing = false;
  Set<String> _needIds = const {};
  final _heardNeeds = <String>{};
  final _turns = <String, int>{}, _fails = <String, int>{};
  bool _baselined = false;

  // Held faces.
  DaemonMood? _held;
  Timer? _holdTimer;
  bool _booped = false;
  Timer? _boopTimer;
  DateTime? _napUntil;
  Timer? _napTimer;
  DateTime? _awayAt, _lastDone, _lastLook;

  // Blinks and frames.
  String? _lid;
  Timer? _blinkTimer;
  int _t = 0;
  Timer? _frameTimer;
  DaemonMood? _framesFor;

  // Voice.
  String? _voice;
  Timer? _voiceTimer;
  ({String line, DateTime at, DaemonMood? mood})? _pendingVoice;
  Timer? _pendingTimer;
  DateTime? _lastKey;
  bool Function() quiet = _never;
  static bool _never() => false;

  String? _pairKey;

  // ── what it shows ──────────────────────────────────────────────────────────

  bool get visible => zoo.loaded;
  bool get motionEnabled => _foreground && !_reduceMotion;
  bool get revealing => _revealing;
  bool get napping => _napUntil != null;

  /// The paired daemon, withheld while its hatch reveal is still running.
  ZooDaemon? get daemon => _revealing ? null : zoo.paired;
  DaemonDef? get def => roster.byId(daemon?.id);
  String get name => daemon?.nickname ?? def?.id ?? '';
  int get versionIndex => roster.versionIndex(daemon?.version);

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

  /// Milliseconds into the current motion.
  int get t => _t;

  /// The sprite, nest or egg for the status slot (at most eight cells).
  String get glyph {
    if (!visible) return '';
    final d = def;
    if (d == null) {
      if (_revealing || zoo.readyEgg != null) return roster.rules.nest.last;
      return nestFor(roster, zoo.habitsDone);
    }
    return renderSprite(
      roster,
      d,
      versionIndex,
      mood,
      t: _t,
      lid: _lid,
      motion: motionEnabled,
    );
  }

  /// `tim: two agents idle. nothing needs you.` while it speaks.
  String? get voice => _voice;

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
      return '${d.id} ${daemon!.version}, ${moodWords[mood]}';
    }
    if (eggReady) return 'Ready to hatch';
    return '${zoo.habitsDone} of ${zoo.habitsNeeded} habits';
  }

  String get tooltip {
    if (_revealing) return 'Hatching...';
    if (def != null) return '$name · ${moodWords[mood]}\n$detail';
    if (eggReady) return 'Your egg is ready. Click to hatch it.';
    return 'A daemon is incubating: ${zoo.habitsDone} of '
        '${zoo.habitsNeeded} habits.\nClick to see them.';
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
      _awayAt ??= _now();
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
    final finished = _increased(_turns, watch.turns);
    final failed = _increased(_fails, watch.fails);
    _working = watch.working;
    _failing = watch.failing;
    _needIds = watch.needIds;
    _heardNeeds.addAll(watch.needIds);
    if (_heardNeeds.length > 512) _heardNeeds.retainAll(watch.needIds);
    // Restored state, imported history and reconnects are baselines.
    if (!_baselined || def == null) {
      _baselined = def != null;
      _update(before: before);
      return;
    }
    if (newNeeds.isNotEmpty) {
      _napUntil = null;
      _napTimer?.cancel();
      _blink('ack', delay: const Duration(milliseconds: 160));
      _say(def!.line(DaemonMood.need), mood: DaemonMood.need);
    } else if (failed) {
      _hold(DaemonMood.fail);
      _blink('ack', delay: const Duration(milliseconds: 160));
      _say(def!.line(DaemonMood.fail), mood: DaemonMood.fail);
    } else if (finished) {
      final now = _now();
      _blink('ack', delay: const Duration(milliseconds: 160));
      if (_lastDone == null || now.difference(_lastDone!) >= doneCooldown) {
        _lastDone = now;
        _hold(DaemonMood.done);
        _say(def!.line(DaemonMood.done), mood: DaemonMood.done);
      }
    }
    _update(before: before);
  }

  static bool _increased(Map<String, int> seen, Map<String, int> now) {
    var increased = false;
    for (final entry in now.entries) {
      final previous = seen[entry.key];
      if (previous != null && entry.value > previous) increased = true;
      seen[entry.key] = entry.value;
    }
    return increased;
  }

  /// A key went down somewhere in the window. It only delays speaking.
  void noteKey() => _lastKey = _now();

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
    _say(def!.line(DaemonMood.boop), mood: DaemonMood.boop);
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
      _pairKey = _keyOf(daemon);
      _blink('slow', delay: const Duration(milliseconds: 300));
      _say(d.first, mood: null);
    }
    _update(force: true);
  }

  static String? _keyOf(ZooDaemon? d) =>
      d == null ? null : '${d.id}@${d.version}';

  void _zooChanged() {
    if (_disposed) return;
    final key = _keyOf(daemon);
    if (key != _pairKey) {
      final previous = _pairKey;
      _pairKey = key;
      // A new version of the same daemon is a level up: a slow blink.
      if (previous != null &&
          key != null &&
          previous.split('@').first == key.split('@').first) {
        _blink('slow');
      } else {
        _baselined = false;
        _held = null;
        _holdTimer?.cancel();
      }
    }
    _update(force: true);
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

  void _back() {
    if (def == null || _needIds.isNotEmpty || napping) return;
    _hold(DaemonMood.back);
    _blink(
      'slow',
      delay:
          roster.rules.hold(DaemonMood.back) +
          const Duration(milliseconds: 120),
    );
    _say(def!.line(DaemonMood.back), mood: DaemonMood.back);
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

  void _say(String line, {required DaemonMood? mood}) {
    if (line.isEmpty) return;
    _pendingVoice = (line: line, at: _now(), mood: mood);
    _trySpeak();
  }

  void _trySpeak() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    final pending = _pendingVoice;
    if (pending == null || _disposed) return;
    final now = _now();
    if (now.difference(pending.at) > voiceExpires ||
        (pending.mood == DaemonMood.need && _needIds.isEmpty) ||
        def == null) {
      _pendingVoice = null;
      return;
    }
    Duration? wait;
    if (_lastKey case final key? when now.difference(key) < typingQuiet) {
      wait = typingQuiet - now.difference(key);
    } else if (quiet() || !_foreground) {
      wait = const Duration(milliseconds: 500);
    }
    if (wait != null) {
      _pendingTimer = Timer(wait, _trySpeak);
      return;
    }
    _pendingVoice = null;
    _voice = '$name: ${pending.line}';
    _voiceTimer?.cancel();
    _voiceTimer = Timer(voiceFor, () {
      _voice = null;
      if (!_disposed) notifyListeners();
    });
    notifyListeners();
  }

  // ── frames ─────────────────────────────────────────────────────────────────

  DaemonMood? _lastMood;
  String? _lastGlyph;

  void _update({DaemonMood? before, bool force = false}) {
    if (_disposed) return;
    final now = mood;
    _runFrames(now);
    final glyph = this.glyph;
    if (force || now != (before ?? _lastMood) || glyph != _lastGlyph) {
      _lastMood = now;
      _lastGlyph = glyph;
      notifyListeners();
    }
  }

  void _runFrames(DaemonMood now) {
    final d = def;
    final moving =
        d != null &&
        motionEnabled &&
        (now == DaemonMood.work || now == DaemonMood.back);
    if (!moving) {
      _frameTimer?.cancel();
      _frameTimer = null;
      _framesFor = null;
      _t = 0;
      return;
    }
    if (_framesFor == now && _frameTimer != null) return;
    _frameTimer?.cancel();
    _framesFor = now;
    _t = 0;
    final last = versionIndex == roster.rules.versions.length - 1;
    final ms = !last
        ? 130
        : now == DaemonMood.back
        ? roster.rules.backFrameMs
        : d.workMs;
    _frameTimer = Timer.periodic(Duration(milliseconds: ms), (_) {
      if (_disposed) return;
      _t += ms;
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
    for (final timer in [
      _holdTimer,
      _boopTimer,
      _napTimer,
      _blinkTimer,
      _frameTimer,
      _voiceTimer,
      _pendingTimer,
    ]) {
      timer?.cancel();
    }
    super.dispose();
  }
}
