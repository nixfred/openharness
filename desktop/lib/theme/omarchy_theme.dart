// UNTESTED: written on a machine without the Flutter SDK. Compile and wire before trusting.
//
// Omarchy theme following for the Harness desktop app (nixfred fork, PLAN.md Phase 1.7).
// Reads ~/.local/state/omarchy/current/theme/colors.toml, a flat file of `key = "#rrggbb"` lines
// (blue, yellow, red, green, background, foreground, accent and friends), and turns it into a
// Flutter ColorScheme. Nothing here touches the app yet; call omarchyColorScheme() from the
// theme builder and rebuild when the file changes (a FileSystemEntity.watch on the directory).

import 'dart:io';

import 'package:flutter/material.dart';

const String omarchyColorsPath = '.local/state/omarchy/current/theme/colors.toml';

/// Parse `key = "#hex"` lines. Six or eight hex digits, quotes and the hash optional.
Map<String, Color> parseOmarchyColors(String text) {
  final out = <String, Color>{};
  final re = RegExp(r'^\s*([A-Za-z0-9_]+)\s*=\s*"?#?([0-9a-fA-F]{6}|[0-9a-fA-F]{8})"?', multiLine: true);
  for (final m in re.allMatches(text)) {
    final hex = m.group(2)!;
    final argb = hex.length == 6 ? int.parse('ff$hex', radix: 16) : int.parse(hex, radix: 16);
    out[m.group(1)!.toLowerCase()] = Color(argb);
  }
  return out;
}

/// Read the current theme file, or an empty map when Omarchy is not installed.
Map<String, Color> readOmarchyColors({String? home}) {
  final h = home ?? Platform.environment['HOME'];
  if (h == null) return const {};
  final f = File('$h/$omarchyColorsPath');
  try {
    if (!f.existsSync()) return const {};
    return parseOmarchyColors(f.readAsStringSync());
  } catch (_) {
    return const {};
  }
}

Color _pick(Map<String, Color> c, List<String> keys, Color fallback) {
  for (final k in keys) {
    final v = c[k];
    if (v != null) return v;
  }
  return fallback;
}

/// A ColorScheme from the Omarchy palette. Falls back to Material defaults per slot, so a partial
/// theme file still yields a usable scheme.
ColorScheme omarchyColorScheme(Brightness brightness, {Map<String, Color>? colors}) {
  final c = colors ?? readOmarchyColors();
  final base = brightness == Brightness.dark ? const ColorScheme.dark() : const ColorScheme.light();
  final background = _pick(c, ['background', 'bg', 'base'], base.surface);
  final foreground = _pick(c, ['foreground', 'fg', 'text'], base.onSurface);
  final accent = _pick(c, ['accent', 'blue', 'primary'], base.primary);
  final secondary = _pick(c, ['cyan', 'teal', 'magenta', 'purple'], base.secondary);
  final error = _pick(c, ['red', 'error'], base.error);
  final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;
  return base.copyWith(
    surface: background,
    onSurface: foreground,
    primary: accent,
    onPrimary: onAccent,
    secondary: secondary,
    error: error,
    outline: foreground.withValues(alpha: 0.35),
  );
}

/// State colours for agent attention, matching the Harness Pulse bar widget.
class OmarchyAttentionColors {
  OmarchyAttentionColors(Map<String, Color> c, ColorScheme scheme)
      : working = _pick(c, ['accent', 'blue'], scheme.primary),
        waiting = _pick(c, ['yellow', 'warning'], const Color(0xFFE0B341)),
        permission = _pick(c, ['red', 'error'], scheme.error),
        failed = _pick(c, ['red', 'error'], scheme.error),
        done = _pick(c, ['green', 'success'], const Color(0xFF5FB760)),
        offline = scheme.onSurface.withValues(alpha: 0.28);

  final Color working;
  final Color waiting;
  final Color permission;
  final Color failed;
  final Color done;
  final Color offline;
}
