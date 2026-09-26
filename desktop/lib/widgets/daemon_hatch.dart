import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

import '../daemons/render.dart';
import '../daemons/roster.dart';
import '../daemons/zoo.dart';
import '../shared/theme/app_theme.dart';
import '../terminal/terminal_text.dart';
import '../terminal/terminal_theme_store.dart';
import 'box_chrome.dart';
import 'daemon_slot.dart';

/// Where the reveal is. Exposed so render checks can draw any moment of it.
enum HatchStage {
  /// Wobbling while harnessd answers: nothing is known yet.
  egg,

  /// Cracking, with the rarity told on the shell: a rare glows cyan; a
  /// secret's stage has already gone black.
  crack,

  /// The top pops off: a legendary throws yellow sparks.
  pop,

  /// A secret: "It is pitch black."
  pitch,

  /// The portrait as `#`, in the faint colour.
  silhouette,
  colour,
  banner,
  card,
  failed,
}

/// A still of the reveal, for review captures and Reduce Motion.
@immutable
class HatchFrame {
  const HatchFrame({required this.stage, this.egg, this.bannerRows = 0});
  final HatchStage stage;

  /// The egg's frame, for the egg, crack and pop stages.
  final String? egg;
  final int bannerRows;
}

/// The hatch reveal (`daemons/README.md`, Hatching): the egg wobbles twice
/// (and keeps wobbling while harnessd answers), then tells its rarity as it
/// cracks: a rare's shell glows cyan, a legendary's pop throws yellow `*'.`
/// sparks, and a secret's stage goes black before the crack. The hatchling's
/// portrait appears as `#` in the faint colour for 1200 ms, fills with its
/// colour and blinks; its name types in as a banner; the rarity stamp, its
/// first words and the card follow. The card copies as a fenced code block.
/// Reduce Motion goes straight to the card. From the fourth hatch on, any key
/// skips to the card.
///
/// It floats beside the status slot, takes keyboard focus while it is open,
/// and Escape dismisses it at any point. [onRevealed] runs once, when the
/// daemon may be named elsewhere (the card is up, or the reveal was closed).
class DaemonHatchReveal extends StatefulWidget {
  const DaemonHatchReveal({
    super.key,
    required this.roster,
    required this.egg,
    required this.result,
    required this.zoo,
    required this.onClose,
    this.onRevealed,
    this.reduceMotion = false,
    this.skippable = false,
    this.still,
  });

  final DaemonRoster roster;
  final ZooEgg egg;
  final Future<ZooHatch?> result;

  /// The zoo as it is now; the hatchling's date comes from it.
  final Zoo Function() zoo;
  final VoidCallback onClose;
  final VoidCallback? onRevealed;
  final bool reduceMotion;

  /// After the person's third hatch, any key skips to the card.
  final bool skippable;

  /// Draw one fixed moment instead of running (render checks only).
  final HatchFrame? still;

  @override
  State<DaemonHatchReveal> createState() => _DaemonHatchRevealState();
}

class _DaemonHatchRevealState extends State<DaemonHatchReveal> {
  static const silhouetteFor = 1200;

  final _focus = FocusNode(debugLabel: 'Hatch reveal');
  final _copyFocus = FocusNode(debugLabel: 'Copy card');
  HatchStage _stage = HatchStage.egg;
  late String _egg = eggFrame(widget.roster);
  String? _lid;
  int _bannerRows = 0;
  ZooHatch? _hatch;
  bool _closed = false, _revealed = false, _skip = false;
  Timer? _waitTimer;
  Completer<void>? _waitDone;
  String? _copyNote;

  DaemonRoster get roster => widget.roster;
  DaemonDef? get _def => roster.byId(_hatch?.daemonId);
  bool get _alive => !_closed && mounted;

  /// A secret's stage is black from the crack on.
  bool get _pitch =>
      (_def?.secret == true || _def?.darkOnly == true) &&
      _stage != HatchStage.failed &&
      _stage != HatchStage.egg;

  @override
  void initState() {
    super.initState();
    if (widget.still case final still?) {
      _stage = still.stage;
      _egg = still.egg ?? _egg;
      _bannerRows = still.bannerRows;
      unawaited(
        widget.result.then((hatch) {
          if (mounted) setState(() => _hatch = hatch);
        }),
      );
      return;
    }
    unawaited(_run());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _closed = true;
    _waitTimer?.cancel();
    if (_waitDone case final done? when !done.isCompleted) done.complete();
    _focus.dispose();
    _copyFocus.dispose();
    super.dispose();
  }

  Future<bool> _wait(int ms) async {
    if (widget.reduceMotion || _skip) return _alive;
    final done = Completer<void>();
    _waitDone = done;
    _waitTimer = Timer(Duration(milliseconds: ms), () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    _waitTimer = null;
    _waitDone = null;
    return _alive;
  }

  void _show(VoidCallback change) {
    if (!_alive) return;
    setState(change);
  }

  /// Any key after the third hatch: straight to the card.
  void _skipToCard() {
    if (_skip || !widget.skippable) return;
    _skip = true;
    _waitTimer?.cancel();
    if (_waitDone case final done? when !done.isCompleted) done.complete();
  }

  Future<void> _run() async {
    var answered = false;
    ZooHatch? hatch;
    unawaited(
      widget.result.then((value) {
        answered = true;
        hatch = value;
      }, onError: (_) => answered = true),
    );
    // The egg wobbles twice, and keeps wobbling while harnessd answers.
    var wobbles = 0;
    while (!widget.reduceMotion && !_skip && (wobbles < 2 || !answered)) {
      for (final offset in const [-1, 0, 1, 0]) {
        _show(() => _egg = eggFrame(roster, offset: offset));
        if (!await _wait(90)) return;
      }
      if (!await _wait(420)) return;
      wobbles++;
      if (wobbles > 40) break;
    }
    try {
      hatch = await widget.result;
    } catch (_) {
      hatch = null;
    }
    if (!_alive) return;
    final result = hatch;
    if (result == null || roster.byId(result.daemonId) == null) {
      _show(() => _stage = HatchStage.failed);
      return;
    }
    _hatch = result;
    final def = _def!;
    if (!widget.reduceMotion && !_skip) {
      // A secret: the stage goes black before the crack.
      if (def.secret || def.darkOnly) {
        _show(() {
          _stage = HatchStage.crack;
          _egg = eggFrame(roster);
        });
        if (!await _wait(700)) return;
      }
      // Crack (a rare's shell glows), shake, crack wider, pop.
      _show(() {
        _stage = HatchStage.crack;
        _egg = eggFrame(roster, crack: 1);
      });
      if (!await _wait(450)) return;
      for (final offset in const [-1, 1, -1, 1, 0]) {
        _show(() => _egg = eggFrame(roster, offset: offset, crack: 1));
        if (!await _wait(60)) return;
      }
      _show(() => _egg = eggFrame(roster, crack: 2));
      if (!await _wait(520)) return;
      _show(() {
        _stage = HatchStage.pop;
        _egg = eggPopFrame(roster, sparks: def.rarity == 'legendary');
      });
      if (!await _wait(def.rarity == 'legendary' ? 900 : 480)) return;
      if (def.darkOnly && !_skip) {
        _show(() => _stage = HatchStage.pitch);
        if (!await _wait(1600)) return;
      }
    }
    if (!widget.reduceMotion && !_skip) {
      _show(() => _stage = HatchStage.silhouette);
      if (!await _wait(silhouetteFor)) return;
      _show(() => _stage = HatchStage.colour);
      if (!await _wait(320)) return;
      _show(() => _lid = def.lid ?? '-');
      if (!await _wait(120)) return;
      _show(() => _lid = null);
      if (!await _wait(220)) return;
      final rows = bannerRows(def.id).length;
      for (var row = 1; row <= rows && !_skip; row++) {
        _show(() {
          _stage = HatchStage.banner;
          _bannerRows = row;
        });
        if (!await _wait(90)) return;
      }
    }
    _show(() {
      _stage = HatchStage.card;
      _lid = null;
      _bannerRows = bannerRows(def.id).length;
    });
    _markRevealed();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focus.hasFocus) _copyFocus.requestFocus();
    });
  }

  void _markRevealed() {
    if (_revealed) return;
    _revealed = true;
    widget.onRevealed?.call();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _markRevealed();
    widget.onClose();
  }

  /// The hatchling's card (card.mjs): at 0.1, with the day it hatched and
  /// the egg it came from.
  List<String>? get _card {
    final def = _def, hatch = _hatch;
    if (def == null || hatch == null) return null;
    final owned = widget.zoo().daemons.where((d) => d.id == def.id).lastOrNull;
    return zooCardLines(
      roster,
      def,
      version: roster.rules.versions.first,
      shiny: hatch.shiny,
      hatchedAt: owned?.hatchedAt ?? DateTime.now().toUtc().toIso8601String(),
      egg: widget.egg.kind,
    );
  }

  Future<void> _copy() async {
    final card = _card;
    if (card == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: cardCodeBlock(card)));
      if (mounted) setState(() => _copyNote = 'Copied as a code block.');
    } catch (_) {
      if (mounted) setState(() => _copyNote = 'Could not copy.');
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        !widget.skippable ||
        _stage == HatchStage.card ||
        _stage == HatchStage.failed ||
        event.logicalKey == LogicalKeyboardKey.escape ||
        _modifiers.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    _skipToCard();
    return KeyEventResult.handled;
  }

  static final _modifiers = {
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
  };

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        terminalFontStore,
        terminalThemeStore,
        AppTheme.palette,
      ]),
      builder: (context, _) {
        final theme = currentTerminalTheme();
        final cell = terminalCellSizeOf(context);
        final pitch = _pitch;
        final background = pitch ? daemonPitch : theme.background;
        // On the black stage the ink is light, whatever the theme.
        final fg = pitch ? const Color(0xffd0d0d0) : theme.foreground;
        final ink = terminalContentStyle(
          color: fg,
        ).copyWith(fontFeatures: daemonTextFeatures);
        final muted = fg.withValues(alpha: .6);
        return CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _onKey,
            child: Semantics(
              scopesRoute: true,
              explicitChildNodes: true,
              label: 'Hatching',
              child: Material(
                key: const ValueKey('daemon-hatch'),
                color: background,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kTerminalCornerRadius),
                  side: terminalPaneBorder(focused: true),
                ),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: cell.width * 2,
                    vertical: cell.height,
                  ),
                  // A steady stage: the egg, the portrait and the banner all
                  // fit, so the reveal never jumps before the card.
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: cell.height * 14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _children(theme, cell, ink, muted, pitch),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The egg's frame, told by the hatchling's rarity while it cracks: a
  /// rare's shell glows cyan, a legendary's pop throws yellow sparks.
  Widget _eggText(TerminalTheme theme, TextStyle ink) {
    final def = _def;
    final telling = _stage == HatchStage.crack || _stage == HatchStage.pop;
    final rare = telling && def?.rarity == 'rare';
    final legendary = _stage == HatchStage.pop && def?.rarity == 'legendary';
    final shell = rare
        ? ink.copyWith(
            color: theme.cyan,
            shadows: [
              Shadow(color: theme.cyan.withValues(alpha: .9), blurRadius: 6),
              Shadow(color: theme.cyan.withValues(alpha: .5), blurRadius: 14),
            ],
          )
        : ink;
    final rows = _egg.split('\n');
    final sparks = legendary
        ? {for (final (r, c, _) in eggSparks) (r, c)}
        : const <(int, int)>{};
    final spark = ink.copyWith(
      color: theme.yellow,
      shadows: [Shadow(color: theme.yellow, blurRadius: 6)],
    );
    return Text.rich(
      TextSpan(
        children: [
          for (final (r, row) in rows.indexed) ...[
            if (sparks.isEmpty)
              TextSpan(text: row, style: shell)
            else
              for (final (c, ch) in row.split('').indexed)
                TextSpan(
                  text: ch,
                  style: sparks.contains((r, c)) ? spark : shell,
                ),
            if (r < rows.length - 1) const TextSpan(text: '\n'),
          ],
        ],
      ),
      key: ValueKey(
        rare
            ? 'daemon-hatch-egg-rare'
            : legendary
            ? 'daemon-hatch-egg-legendary'
            : 'daemon-hatch-egg',
      ),
      semanticsLabel: 'An egg, hatching',
      style: ink,
    );
  }

  List<Widget> _children(
    TerminalTheme theme,
    Size cell,
    TextStyle ink,
    Color muted,
    bool pitch,
  ) {
    final def = _def;
    if (_stage == HatchStage.failed) {
      return [
        Text(
          'The egg did not open.',
          key: const ValueKey('daemon-hatch-failed'),
          style: ink,
        ),
        Text(
          'harnessd could not be reached. It is still in your zoo.',
          textAlign: TextAlign.center,
          style: ink.copyWith(color: muted),
        ),
        SizedBox(height: cell.height),
        _button('[ close ]', _close, theme, ink),
      ];
    }
    if (_stage == HatchStage.egg ||
        _stage == HatchStage.crack ||
        _stage == HatchStage.pop ||
        def == null) {
      return [_eggText(theme, ink)];
    }
    final shiny = _hatch?.shiny == true;
    final colour = daemonColor(def, theme, shiny: shiny);
    final backdrop = daemonBackdrop(def);
    final version = roster.rules.versions.first;
    final portrait = renderPortrait(
      roster,
      def,
      version,
      DaemonMood.idle,
      lid: _lid,
      motion: false,
    );
    final silhouetted = _stage == HatchStage.silhouette;
    final rarity = switch (def.rarity) {
      'rare' => theme.cyan,
      'legendary' => theme.yellow,
      'secret' => theme.magenta,
      _ => ink.color ?? theme.foreground,
    };
    final rows = bannerRows(def.id);
    final card = _stage == HatchStage.card ? _card : null;
    // The shared banner face (daemons/banner.json), monospace, at a line
    // height that keeps its rows from touching.
    final banner = ink.copyWith(height: 1.15);
    return [
      if (_stage == HatchStage.pitch)
        Padding(
          padding: EdgeInsets.only(bottom: cell.height),
          child: Text(
            'It is pitch black. You are likely to be eaten by a grue.',
            key: const ValueKey('daemon-hatch-pitch'),
            textAlign: TextAlign.center,
            style: ink.copyWith(color: const Color(0xff949494)),
          ),
        ),
      if (_stage != HatchStage.pitch && card == null)
        Container(
          color: silhouetted ? null : backdrop,
          child: Text(
            (silhouetted ? portrait.map(silhouette) : portrait).join('\n'),
            key: const ValueKey('daemon-hatch-portrait'),
            semanticsLabel: silhouetted ? 'A silhouette' : '${def.id} $version',
            style: ink.copyWith(
              color: silhouetted ? ink.color!.withValues(alpha: .35) : colour,
              height: 1.15,
            ),
          ),
        ),
      if (_bannerRows > 0) ...[
        SizedBox(height: cell.height / 2),
        Text(
          rows.take(_bannerRows).join('\n'),
          key: const ValueKey('daemon-hatch-banner'),
          semanticsLabel: def.id,
          style: banner,
        ),
      ],
      if (_stage == HatchStage.card) ...[
        SizedBox(height: cell.height / 2),
        Text(
          rarityStamp(roster, def, shiny: shiny),
          key: const ValueKey('daemon-hatch-stamp'),
          style: ink.copyWith(color: rarity, letterSpacing: 1),
        ),
        SizedBox(height: cell.height / 2),
        Text(
          "fork() returned 0. it's a ${def.id}.",
          key: const ValueKey('daemon-hatch-words'),
          textAlign: TextAlign.center,
          style: ink.copyWith(color: muted),
        ),
        if (card != null) ...[
          SizedBox(height: cell.height),
          Container(
            padding: EdgeInsets.all(cell.width),
            decoration: BoxDecoration(
              color: pitch
                  ? const Color(0xff0c0c0c)
                  : Color.lerp(theme.background, theme.foreground, .04),
              border: Border.all(color: ink.color!.withValues(alpha: .2)),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: DaemonCardText(
                key: const ValueKey('daemon-hatch-card'),
                lines: card,
                portraitRows: portraitFor(roster, def, version).length,
                style: ink.copyWith(fontSize: (ink.fontSize ?? 13) * .92),
                colour: colour,
                backdrop: backdrop,
              ),
            ),
          ),
          SizedBox(height: cell.height / 2),
          Row(
            children: [
              _button(
                '[ copy ]',
                _copy,
                theme,
                ink,
                focusNode: _copyFocus,
                key: const ValueKey('daemon-hatch-copy'),
              ),
              SizedBox(width: cell.width),
              _button('[ close ]', _close, theme, ink),
              SizedBox(width: cell.width * 2),
              Expanded(
                child: Text(
                  _copyNote ?? 'esc closes',
                  style: ink.copyWith(color: muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    ];
  }

  Widget _button(
    String label,
    VoidCallback onPressed,
    TerminalTheme theme,
    TextStyle ink, {
    FocusNode? focusNode,
    Key? key,
  }) => TextButton(
    key: key,
    focusNode: focusNode,
    onPressed: onPressed,
    style:
        TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: ink.color,
          shape: const RoundedRectangleBorder(),
          splashFactory: NoSplash.splashFactory,
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
                ? theme.selection.withValues(alpha: .5)
                : Colors.transparent,
          ),
        ),
    child: Text(
      label,
      style: ink.copyWith(color: _pitch ? ink.color : theme.cursor),
    ),
  );
}
