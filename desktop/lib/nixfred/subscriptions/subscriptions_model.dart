// nixfred: the Subscriptions screen's data, as the local daemon serves it on GET /api/subscriptions
// (cli/src/nixfred/subscriptions). The math lives in the daemon (ported from Burn Bar,
// github.com/nixfred/burnbar); this side only parses it and keeps the clocks running between polls.
library;

/// How a plan stands against an even pace. Arcs are quantities; the tone picks their colour.
enum SubTone { banked, onPace, amber, red, unknown }

SubTone subToneFromWire(Object? v) => switch (v) {
      'banked' => SubTone.banked,
      'on-pace' => SubTone.onPace,
      'amber' => SubTone.amber,
      'red' => SubTone.red,
      _ => SubTone.unknown,
    };

double _d(Object? v, [double fallback = 0]) => v is num ? v.toDouble() : fallback;
int _i(Object? v) => v is num ? v.toInt() : 0;
String _s(Object? v) => v is String ? v : '';

/// The window a plan is judged by (weekly where there is one, else the monthly pool).
class SubWindow {
  const SubWindow({
    required this.label,
    required this.used,
    required this.resetsInMs,
    required this.windowMs,
    required this.elapsed,
    required this.bankedSigned,
    required this.bankedMs,
    required this.comeBackMs,
    required this.spent,
    required this.over,
    required this.tone,
    required this.sentence,
    required this.series,
  });

  final String label;
  final double used;
  final int resetsInMs;
  final int windowMs;
  final double elapsed;

  /// elapsed minus used: positive is banked, negative is over pace.
  final double bankedSigned;
  final double bankedMs;
  final int comeBackMs;
  final bool spent;
  final bool over;
  final SubTone tone;
  final String sentence;

  /// Burndown: x = share of the window elapsed, y = share of the plan spent. The diagonal is even pace.
  final List<(double, double)> series;

  static SubWindow? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pace = raw['pace'] is Map ? raw['pace'] as Map : const {};
    final series = <(double, double)>[];
    final s = pace['series'];
    if (s is List) {
      for (final p in s) {
        if (p is List && p.length == 2 && p[0] is num && p[1] is num) {
          series.add(((p[0] as num).toDouble().clamp(0, 1), (p[1] as num).toDouble().clamp(0, 1)));
        }
      }
    }
    return SubWindow(
      label: _s(raw['label']),
      used: _d(raw['used']).clamp(0, 1),
      resetsInMs: _i(raw['resetsInMs']),
      windowMs: _i(raw['windowMs']),
      elapsed: _d(raw['elapsed']).clamp(0, 1),
      bankedSigned: _d(raw['bankedSigned']),
      bankedMs: _d(raw['bankedMs']),
      comeBackMs: _i(raw['comeBackMs']),
      spent: raw['spent'] == true,
      over: raw['over'] == true,
      tone: subToneFromWire(raw['tone']),
      sentence: _s(raw['sentence']),
      series: series,
    );
  }
}

class SubCard {
  const SubCard({
    required this.id,
    required this.name,
    required this.state,
    required this.enabled,
    required this.plan,
    required this.snapshot,
    required this.status,
    required this.help,
    required this.primary,
    required this.isPick,
    required this.blocked,
  });

  final String id;
  final String name;

  /// ok, not-detected, not-configured, error, disabled.
  final String state;
  final bool enabled;
  final String plan;
  final bool snapshot;
  final String status;
  final String help;
  final SubWindow? primary;
  final bool isPick;
  final bool blocked;

  bool get detected => state != 'not-detected';

  static SubCard? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = _s(raw['id']);
    if (id.isEmpty) return null;
    return SubCard(
      id: id,
      name: _s(raw['name']).isEmpty ? id : _s(raw['name']),
      state: _s(raw['state']),
      enabled: raw['enabled'] != false,
      plan: _s(raw['plan']),
      snapshot: raw['snapshot'] == true,
      status: _s(raw['status']),
      help: _s(raw['help']),
      primary: SubWindow.fromJson(raw['primary']),
      isPick: raw['isPick'] == true,
      blocked: raw['blocked'] == true,
    );
  }
}

class SubsPayload {
  const SubsPayload({required this.at, required this.subs, required this.verdict, required this.pick, required this.urgent});

  final int at;
  final List<SubCard> subs;
  final String verdict;
  final String pick;
  final bool urgent;

  /// Unknown shapes parse to an empty payload, never a throw.
  factory SubsPayload.fromJson(Object? raw) {
    if (raw is! Map) return const SubsPayload(at: 0, subs: [], verdict: '', pick: '', urgent: false);
    final guide = raw['guide'] is Map ? raw['guide'] as Map : const {};
    return SubsPayload(
      at: _i(raw['at']),
      subs: [
        for (final s in (raw['subs'] is List ? raw['subs'] as List : const [])) ?SubCard.fromJson(s),
      ],
      verdict: _s(guide['verdict']),
      pick: _s(guide['pick']),
      urgent: guide['urgent'] == true,
    );
  }
}

/// "3d 10h", "6h 40m", "45m": two units at most (Burn Bar's spanWords).
String spanWords(num ms) {
  final mins = (ms / 60000).round();
  if (mins < 1) return 'under a minute';
  final d = mins ~/ 1440, h = (mins % 1440) ~/ 60, m = mins % 60;
  if (d > 0) return h > 0 ? '${d}d ${h}h' : '${d}d';
  if (h > 0) return m > 0 ? '${h}h ${m}m' : '${h}h';
  return '${m}m';
}

/// A running clock: "3d 09:12:45", "7:13:22", "13:05" (Burn Bar's clockSpan).
String clockSpan(num ms) {
  final total = ms <= 0 ? 0 : ms ~/ 1000;
  final d = total ~/ 86400, h = (total % 86400) ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  if (d > 0) return '${d}d ${two(h)}:${two(m)}:${two(s)}';
  if (h > 0) return '$h:${two(m)}:${two(s)}';
  return '$m:${two(s)}';
}

/// The banked chip text: "+6% banked" or "10% over pace".
String bankedLabel(double bankedSigned) {
  final pct = (bankedSigned.abs() * 100).round();
  if (pct == 0) return 'on pace';
  return bankedSigned > 0 ? '+$pct% banked' : '$pct% over pace';
}
