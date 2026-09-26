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
enum HatchStage { egg, pitch, silhouette, colour, banner, card, failed }

/// A still of the reveal, for review captures and Reduce Motion.
@immutable
class HatchFrame {
  const HatchFrame({
    required this.stage,
    this.egg,
    this.sprite,
    this.bannerRows = 0,
  });
  final HatchStage stage;
  final String? egg, sprite;
  final int bannerRows;
}

/// The hatch reveal (`daemons/README.md`, Hatching): the egg wobbles twice,
/// cracks and pops; the 0.1 sprite appears as `#` in the faint colour for
/// 850 ms, fills with its colour and blinks; its name types in as a small
/// banner; the rarity stamp and first words appear; then the card, which
/// copies as a fenced code block. A secret's reveal starts pitch black.
/// Reduce Motion goes straight to the card.
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

  /// Draw one fixed moment instead of running (render checks only).
  final HatchFrame? still;

  @override
  State<DaemonHatchReveal> createState() => _DaemonHatchRevealState();
}

class _DaemonHatchRevealState extends State<DaemonHatchReveal> {
  final _focus = FocusNode(debugLabel: 'Hatch reveal');
  final _copyFocus = FocusNode(debugLabel: 'Copy card');
  HatchStage _stage = HatchStage.egg;
  late String _egg = eggFrame(widget.roster);
  String? _sprite;
  bool _faint = false;
  int _bannerRows = 0;
  ZooHatch? _hatch;
  bool _closed = false, _revealed = false;
  String? _copyNote;

  DaemonRoster get roster => widget.roster;
  DaemonDef? get _def => roster.byId(_hatch?.daemonId);

  @override
  void initState() {
    super.initState();
    if (widget.still case final still?) {
      _stage = still.stage;
      _egg = still.egg ?? _egg;
      _sprite = still.sprite;
      _faint = still.stage == HatchStage.silhouette;
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
    _focus.dispose();
    _copyFocus.dispose();
    super.dispose();
  }

  Future<bool> _wait(int ms) async {
    if (widget.reduceMotion) return !_closed;
    await Future<void>.delayed(Duration(milliseconds: ms));
    return !_closed && mounted;
  }

  void _show(VoidCallback change) {
    if (_closed || !mounted) return;
    setState(change);
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
    while (!widget.reduceMotion && (wobbles < 2 || !answered)) {
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
    if (_closed || !mounted) return;
    final result = hatch;
    if (result == null || roster.byId(result.daemonId) == null) {
      _show(() => _stage = HatchStage.failed);
      return;
    }
    _hatch = result;
    // Crack, shake, crack wider, pop.
    if (!widget.reduceMotion) {
      _show(() => _egg = eggFrame(roster, crack: 1));
      if (!await _wait(450)) return;
      for (final offset in const [-1, 1, -1, 1, 0]) {
        _show(() => _egg = eggFrame(roster, offset: offset, crack: 1));
        if (!await _wait(60)) return;
      }
      _show(() => _egg = eggFrame(roster, crack: 2));
      if (!await _wait(520)) return;
      _show(() => _egg = eggPopFrame(roster));
      if (!await _wait(480)) return;
    }
    final def = _def!;
    final sprite = renderSprite(roster, def, 0, DaemonMood.idle);
    if (def.secret && !widget.reduceMotion) {
      _show(() => _stage = HatchStage.pitch);
      if (!await _wait(1600)) return;
    }
    if (!widget.reduceMotion) {
      _show(() {
        _stage = HatchStage.silhouette;
        _sprite = silhouette(sprite);
        _faint = true;
      });
      if (!await _wait(850)) return;
      _show(() {
        _stage = HatchStage.colour;
        _sprite = sprite;
        _faint = false;
      });
      if (!await _wait(320)) return;
      _show(
        () => _sprite = renderSprite(
          roster,
          def,
          0,
          DaemonMood.idle,
          lid: def.lid ?? '-',
        ),
      );
      if (!await _wait(120)) return;
      _show(() => _sprite = sprite);
      if (!await _wait(220)) return;
      final rows = bannerRows(def.id).length;
      for (var row = 1; row <= rows; row++) {
        _show(() {
          _stage = HatchStage.banner;
          _bannerRows = row;
        });
        if (!await _wait(90)) return;
      }
    }
    _show(() {
      _stage = HatchStage.card;
      _sprite = sprite;
      _faint = false;
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

  String? get _card {
    final def = _def, hatch = _hatch;
    if (def == null || hatch == null) return null;
    final owned = widget.zoo().daemons.where((d) => d.id == def.id);
    return daemonCard(
      roster,
      def,
      shiny: hatch.shiny,
      eggKind: widget.egg.kind,
      hatchedAt: owned.isEmpty ? DateTime.now() : owned.last.hatchedDate,
    );
  }

  Future<void> _copy() async {
    final card = _card;
    if (card == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: '```\n$card\n```'));
      if (mounted) setState(() => _copyNote = 'Copied as a code block.');
    } catch (_) {
      if (mounted) setState(() => _copyNote = 'Could not copy.');
    }
  }

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
        final def = _def;
        final pitch =
            def?.secret == true &&
            _stage != HatchStage.failed &&
            _stage != HatchStage.egg;
        final background = pitch ? const Color(0xff000000) : theme.background;
        final ink = terminalContentStyle(color: theme.foreground)
            .copyWith(fontFeatures: daemonTextFeatures);
        final muted = theme.foreground.withValues(alpha: .6);
        return CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
          child: Focus(
            focusNode: _focus,
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: _children(theme, cell, ink, muted, pitch),
                  ),
                ),
              ),
            ),
          ),
        );
      },
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
    if (_stage == HatchStage.egg || def == null) {
      return [
        Text(
          _egg,
          key: const ValueKey('daemon-hatch-egg'),
          semanticsLabel: 'An egg, hatching',
          style: ink.copyWith(color: theme.yellow),
        ),
      ];
    }
    final colour = daemonColor(def, theme, shiny: _hatch?.shiny == true);
    final big = ink.copyWith(
      fontSize: (ink.fontSize ?? 13) * 3,
      height: 1,
      fontWeight: FontWeight.w500,
      color: _faint ? theme.foreground.withValues(alpha: .35) : colour,
    );
    final rarity = switch (def.rarity) {
      'rare' => theme.cyan,
      'legendary' => theme.yellow,
      'secret' => theme.magenta,
      _ => theme.foreground,
    };
    final rows = bannerRows(def.id);
    final card = _stage == HatchStage.card ? _card : null;
    return [
      if (pitch)
        Padding(
          padding: EdgeInsets.only(bottom: cell.height),
          child: Text(
            'It is pitch black. You are likely to be eaten by a grue.',
            textAlign: TextAlign.center,
            style: ink.copyWith(color: const Color(0xff949494)),
          ),
        ),
      if (_sprite != null)
        Text(
          _sprite!,
          key: const ValueKey('daemon-hatch-sprite'),
          semanticsLabel: _stage == HatchStage.silhouette
              ? 'A silhouette'
              : '${def.id} 0.1',
          style: big,
        ),
      if (_bannerRows > 0) ...[
        SizedBox(height: cell.height),
        Text(
          rows.take(_bannerRows).join('\n'),
          key: const ValueKey('daemon-hatch-banner'),
          semanticsLabel: def.id,
          style: ink.copyWith(color: theme.brightWhite, height: 1.1),
        ),
      ],
      if (_stage == HatchStage.card) ...[
        SizedBox(height: cell.height),
        Text(
          rarityStamp(roster, def, shiny: _hatch?.shiny == true),
          key: const ValueKey('daemon-hatch-stamp'),
          style: ink.copyWith(color: rarity, letterSpacing: 1),
        ),
        SizedBox(height: cell.height / 2),
        Text(
          "fork() returned 0. it's a ${def.id}.\n${def.id} 0.1: ${def.first}",
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
              border: Border.all(color: theme.foreground.withValues(alpha: .2)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                card,
                key: const ValueKey('daemon-hatch-card'),
                style: ink.copyWith(fontSize: (ink.fontSize ?? 13) * .92),
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
          foregroundColor: theme.foreground,
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
    child: Text(label, style: ink.copyWith(color: theme.cursor)),
  );
}
