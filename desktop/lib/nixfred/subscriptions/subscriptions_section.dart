// nixfred: Settings ▸ Subscriptions. Every AI plan on this machine on one screen: the weekly percent
// used as an arc, the percent banked against an even pace (green when banked, amber or red when over),
// a burndown line against the even-pace diagonal, the reset countdown, a pace sentence, and which plan
// to reach for next. Pace math ported from Burn Bar (github.com/nixfred/burnbar); the numbers come from
// the local daemon (GET /api/subscriptions), so Burn Bar does not have to be installed.
//
// nixfred/DESIGN.md: arcs are quantities, glow is urgency (only the suggested plan glows), every
// animation sits behind reduced motion and never changes layout, and the pane never scrolls (Law 17).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../shared/theme/app_theme.dart' as grid;
import '../../shared/widgets/section_scaffold.dart';
import 'subscriptions_model.dart';

/// Reads and switches subscriptions through the local daemon. Replaceable in tests.
abstract class SubscriptionsSource {
  Future<SubsPayload> fetch();
  Future<void> setEnabled(String id, bool on);
}

/// The local daemon over plain `dart:io`, owned by one section and closed with it ([close]).
///
/// Not Dio: a request still in flight when the section goes (a daemon that is down or slow) must end
/// with the section, and Dio finishes a cancelled request through a timer of its own that outlives the
/// widget tree. Since upstream's test/flutter_test_config.dart lets widget tests reach loopback for real
/// (it used to answer every request 400 at once), that timer failed every Settings render test. Here the
/// connect timeout is the client's own, the read timeout is a timer this source holds, and [close]
/// cancels both and drops the connection.
class DaemonSubscriptionsSource implements SubscriptionsSource {
  DaemonSubscriptionsSource(String baseUrl) : _base = Uri.parse(baseUrl) {
    _http.connectionTimeout = const Duration(seconds: 3);
  }
  final Uri _base;
  final HttpClient _http = HttpClient();
  final Set<Timer> _timers = {};
  bool _closed = false;

  Future<Object?> _request(String method, String path, {Object? body, Map<String, String> headers = const {}}) async {
    if (_closed) throw StateError('closed');
    final request = await _http.openUrl(method, _base.resolve(path));
    // The whole answer within 30 s, as before; abort() ends a stalled read.
    final timer = Timer(const Duration(seconds: 30), () => request.abort(TimeoutException('daemon read')));
    _timers.add(timer);
    try {
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) throw HttpException('HTTP ${response.statusCode}', uri: _base.resolve(path));
      return text.isEmpty ? null : jsonDecode(text);
    } finally {
      timer.cancel();
      _timers.remove(timer);
    }
  }

  @override
  Future<SubsPayload> fetch() async => SubsPayload.fromJson(await _request('GET', '/api/subscriptions'));

  @override
  Future<void> setEnabled(String id, bool on) async {
    await _request(
      'POST',
      '/api/nixfred',
      body: {'action': 'subs-set', 'id': id, 'enabled': on ? 'on' : 'off'},
      // The daemon's same-origin gate for local mutations.
      headers: {'x-adapter-local': '1'},
    );
  }

  /// The section is gone: every timer cancelled, every connection dropped, nothing new started.
  void close() {
    _closed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _http.close(force: true);
  }
}

class SubscriptionsSection extends StatefulWidget {
  const SubscriptionsSection({super.key, required this.source, this.pollEvery = const Duration(seconds: 60)});

  final SubscriptionsSource source;
  final Duration pollEvery;

  @override
  State<SubscriptionsSection> createState() => _SubscriptionsSectionState();
}

class _SubscriptionsSectionState extends State<SubscriptionsSection> {
  SubsPayload? _data;
  String _error = '';
  DateTime _fetchedAt = DateTime.now();
  Timer? _poll;
  Timer? _tick;
  final Set<String> _pending = {};

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(widget.pollEvery, (_) => _load());
    // The clocks run between polls: banked time climbs and countdowns fall every second.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    final source = widget.source;
    if (source is DaemonSubscriptionsSource) source.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.source.fetch();
      if (!mounted) return;
      setState(() { _data = d; _error = ''; _fetchedAt = DateTime.now(); });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'The Harness daemon is not answering on this computer. Start it with `harness start`.');
    }
  }

  Future<void> _toggle(SubCard s, bool on) async {
    setState(() => _pending.add(s.id));
    try {
      await widget.source.setEnabled(s.id, on);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not switch ${s.name} ${on ? 'on' : 'off'}.');
    } finally {
      if (mounted) setState(() => _pending.remove(s.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    grid.AppTheme.watch(context);
    final data = _data;
    final sinceMs = DateTime.now().difference(_fetchedAt).inMilliseconds;
    return SectionScaffold(
      title: 'Subscriptions',
      subtitle: 'Every plan on this computer: weekly use, banked pace, and which one to use next.',
      child: data == null
          ? Center(child: Text(_error.isEmpty ? 'Reading your plans…' : _error, style: TextStyle(color: grid.AppPalette.textSecondary)))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Verdict(text: data.verdict, urgent: data.urgent, error: _error),
                const SizedBox(height: 12),
                Expanded(child: _CardGrid(data: data, sinceMs: sinceMs, pending: _pending, onToggle: _toggle)),
              ],
            ),
    );
  }
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.text, required this.urgent, required this.error});
  final String text;
  final bool urgent;
  final String error;

  @override
  Widget build(BuildContext context) {
    final accent = urgent ? grid.AppPalette.warn : grid.AppPalette.accentOnSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: grid.AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Row(children: [
        Icon(urgent ? Icons.bolt : Icons.arrow_forward, size: 18, color: accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            error.isNotEmpty ? '$text  ($error)' : text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: grid.AppPalette.textPrimary, fontSize: 13.5, fontWeight: FontWeight.w500),
          ),
        ),
      ]),
    );
  }
}

/// A grid that always fits the pane: columns from the width, rows share the height. Never scrolls.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.data, required this.sinceMs, required this.pending, required this.onToggle});
  final SubsPayload data;
  final int sinceMs;
  final Set<String> pending;
  final Future<void> Function(SubCard, bool) onToggle;

  @override
  Widget build(BuildContext context) {
    final subs = data.subs;
    if (subs.isEmpty) return Center(child: Text('No subscriptions reported.', style: TextStyle(color: grid.AppPalette.textSecondary)));
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= 1100 ? math.min(4, subs.length) : box.maxWidth >= 560 ? math.min(2, subs.length) : 1;
      final rows = (subs.length / cols).ceil();
      const gap = 12.0;
      final w = (box.maxWidth - gap * (cols - 1)) / cols;
      final h = (box.maxHeight - gap * (rows - 1)) / rows;
      return Stack(children: [
        for (var i = 0; i < subs.length; i++)
          Positioned(
            left: (i % cols) * (w + gap),
            top: (i ~/ cols) * (h + gap),
            width: w,
            height: h,
            child: _SubCardView(card: subs[i], sinceMs: sinceMs, busy: pending.contains(subs[i].id), onToggle: (on) => onToggle(subs[i], on)),
          ),
      ]);
    });
  }
}

Color toneColor(SubTone t) => switch (t) {
      SubTone.banked => grid.AppPalette.online,
      SubTone.onPace => grid.AppPalette.accentOnSurface,
      SubTone.amber => grid.AppPalette.warn,
      SubTone.red => grid.AppPalette.dangerFill,
      SubTone.unknown => grid.AppPalette.offline,
    };

class _SubCardView extends StatelessWidget {
  const _SubCardView({required this.card, required this.sinceMs, required this.busy, required this.onToggle});
  final SubCard card;
  final int sinceMs;
  final bool busy;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final w = card.primary;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final dim = !card.enabled || !card.detected;
    final tone = w == null ? SubTone.unknown : w.tone;
    final color = toneColor(tone);
    final body = Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      decoration: BoxDecoration(
        color: grid.AppPalette.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: card.isPick ? grid.AppPalette.accentOnSurface : grid.AppPalette.divider, width: card.isPick ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: card.name, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: grid.AppPalette.textPrimary)),
                  if (card.plan.isNotEmpty) TextSpan(text: '  ${card.plan}', style: TextStyle(fontSize: 12, color: grid.AppPalette.textSecondary)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (card.isPick)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text('USE NEXT', style: TextStyle(fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: grid.AppPalette.accentOnSurface)),
              ),
            Tooltip(
              message: card.enabled ? 'Switch ${card.name} off' : 'Switch ${card.name} on',
              child: Transform.scale(
                scale: 0.8,
                child: Switch(value: card.enabled, onChanged: busy ? null : onToggle),
              ),
            ),
          ]),
          Expanded(
            child: dim || w == null
                ? _Empty(card: card)
                : Opacity(
                    opacity: 1,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(
                        flex: 5,
                        child: Row(children: [
                          Expanded(child: _UsedArc(used: w.used, color: color, label: w.label, reduce: reduce)),
                          const SizedBox(width: 8),
                          Expanded(child: _BankStack(w: w, color: color, sinceMs: sinceMs)),
                        ]),
                      ),
                      const SizedBox(height: 6),
                      Expanded(flex: 3, child: _Burndown(series: w.series, color: color, reduce: reduce)),
                      const SizedBox(height: 6),
                      Text(
                        w.sentence + (card.snapshot ? ' Snapshot from the last Grok start.' : ''),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, height: 1.3, color: grid.AppPalette.textSecondary),
                      ),
                      if (card.status.isNotEmpty)
                        Text(card.status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: grid.AppPalette.textFaint)),
                    ]),
                  ),
          ),
        ],
      ),
    );
    final faded = AnimatedOpacity(opacity: dim ? 0.55 : 1, duration: reduce ? Duration.zero : const Duration(milliseconds: 240), child: body);
    return card.isPick ? _Glow(color: grid.AppPalette.accentOnSurface, reduce: reduce, child: faded) : faded;
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.card});
  final SubCard card;

  @override
  Widget build(BuildContext context) {
    final (title, detail) = switch (card.state) {
      'disabled' => ('Off', 'Switched off here. Its meter is not read.'),
      'not-detected' => ('Not detected', 'No ${card.name} install or key on this computer.'),
      'not-configured' => ('Not signed in', card.help.isNotEmpty ? card.help : card.status),
      _ => ('No reading', [card.status, card.help].where((s) => s.isNotEmpty).join(' ')),
    };
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(card.state == 'error' ? Icons.error_outline : Icons.remove_circle_outline, size: 28, color: grid.AppPalette.textFaint),
        const SizedBox(height: 6),
        Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: grid.AppPalette.textSecondary)),
        const SizedBox(height: 2),
        Text(detail, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: grid.AppPalette.textFaint)),
      ]),
    );
  }
}

/// Soft outer glow that breathes on the suggested plan; steady under reduced motion.
class _Glow extends StatefulWidget {
  const _Glow({required this.color, required this.reduce, required this.child});
  final Color color;
  final bool reduce;
  final Widget child;
  @override
  State<_Glow> createState() => _GlowState();
}

class _GlowState extends State<_Glow> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    if (!widget.reduce) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _Glow old) {
    super.didUpdateWidget(old);
    if (widget.reduce && _c.isAnimating) _c.stop();
    if (!widget.reduce && !_c.isAnimating) _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = widget.reduce ? 0.5 : Curves.easeInOut.transform(_c.value);
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.18 + 0.22 * t), blurRadius: 10 + 10 * t)],
            ),
            child: child,
          );
        },
        child: widget.child,
      );
}

/// The weekly percent used, as a 270-degree arc that sweeps in.
class _UsedArc extends StatelessWidget {
  const _UsedArc({required this.used, required this.color, required this.label, required this.reduce});
  final double used;
  final Color color;
  final String label;
  final bool reduce;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: used),
        duration: reduce ? Duration.zero : const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => CustomPaint(
          painter: _ArcPainter(value: v, color: color, track: grid.AppPalette.divider),
          child: Center(
            child: FittedBox(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${(v * 100).round()}%', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: grid.AppPalette.textPrimary)),
                  Text('${label.split(' ').first.toUpperCase()} USED', style: TextStyle(fontSize: 9, letterSpacing: 1.1, color: grid.AppPalette.textFaint)),
                ]),
              ),
            ),
          ),
        ),
      );
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({required this.value, required this.color, required this.track});
  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height) - 8;
    if (side <= 0) return;
    final rect = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    const start = math.pi * 0.75, sweep = math.pi * 1.5;
    final stroke = math.max(4.0, side * 0.07);
    final base = Paint()..style = PaintingStyle.stroke..strokeWidth = stroke..strokeCap = StrokeCap.round..color = track;
    canvas.drawArc(rect, start, sweep, false, base);
    if (value > 0) canvas.drawArc(rect, start, sweep * value.clamp(0, 1), false, base..color = color);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.value != value || old.color != color || old.track != track;
}

/// Banked (or over) as a signed figure, the time it is worth, and the reset clock.
class _BankStack extends StatelessWidget {
  const _BankStack({required this.w, required this.color, required this.sinceMs});
  final SubWindow w;
  final Color color;
  final int sinceMs;

  @override
  Widget build(BuildContext context) {
    // Between polls the clock keeps moving: banked grows (or the come-back time shrinks) by the
    // share of the window that has passed.
    final drift = w.windowMs > 0 ? sinceMs / w.windowMs : 0.0;
    final signed = w.spent ? w.bankedSigned : w.bankedSigned + drift;
    final resetIn = math.max(0, w.resetsInMs - sinceMs);
    final comeBack = math.max(0, w.comeBackMs - sinceMs);
    final small = TextStyle(fontSize: 10, letterSpacing: 1.1, color: grid.AppPalette.textFaint);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
          child: Text(bankedLabel(signed), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: color)),
        ),
        const SizedBox(height: 8),
        if (w.spent || w.over) ...[
          Text('BACK ON PACE IN', style: small),
          Text(clockSpan(w.spent ? resetIn : comeBack), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()], color: color)),
        ] else ...[
          Text('BANKED TIME', style: small),
          Text(clockSpan(w.bankedMs + (w.windowMs * drift)), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()], color: grid.AppPalette.textPrimary)),
        ],
        const SizedBox(height: 6),
        Text('RESETS IN', style: small),
        Text(clockSpan(resetIn), style: TextStyle(fontSize: 14, fontFeatures: const [FontFeature.tabularFigures()], color: grid.AppPalette.textSecondary)),
      ]),
    );
  }
}

/// The burndown: spend against the even-pace diagonal, drawn in from the left.
class _Burndown extends StatelessWidget {
  const _Burndown({required this.series, required this.color, required this.reduce});
  final List<(double, double)> series;
  final Color color;
  final bool reduce;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: reduce ? Duration.zero : const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => CustomPaint(
          painter: _BurndownPainter(series: series, color: color, grid: grid.AppPalette.divider, reveal: t),
          size: Size.infinite,
        ),
      );
}

class _BurndownPainter extends CustomPainter {
  _BurndownPainter({required this.series, required this.color, required this.grid, required this.reveal});
  final List<(double, double)> series;
  final Color color;
  final Color grid;
  final double reveal;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    Offset at(double x, double y) => Offset(x * size.width, size.height - y * size.height);
    final frame = Paint()..color = grid..strokeWidth = 1..style = PaintingStyle.stroke;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)), frame);
    // Even pace: the diagonal, dashed.
    const dashes = 24;
    for (var i = 0; i < dashes; i += 2) {
      canvas.drawLine(at(i / dashes, i / dashes), at((i + 1) / dashes, (i + 1) / dashes), frame);
    }
    if (series.isEmpty) return;
    final visible = series.where((p) => p.$1 <= series.last.$1 * reveal + 1e-9).toList();
    if (visible.isEmpty) return;
    final path = Path()..moveTo(at(visible.first.$1, visible.first.$2).dx, at(visible.first.$1, visible.first.$2).dy);
    for (final p in visible.skip(1)) {
      final o = at(p.$1, p.$2);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, Paint()..color = color..strokeWidth = 2..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round);
    final now = at(visible.last.$1, visible.last.$2);
    canvas.drawCircle(now, 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BurndownPainter old) => old.series != series || old.color != color || old.reveal != reveal || old.grid != grid;
}
