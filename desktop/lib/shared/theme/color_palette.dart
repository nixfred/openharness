import '../../theme/omarchy_theme.dart';
import 'package:flutter/painting.dart';

/// Coordinated workspace colors. These feed the existing design-system tokens,
/// native tabs/search, and terminal defaults; they do not change agent state.
enum HarnessPalette {
  graphite(
    'Graphite',
    'Neutral charcoal',
    background: Color(0xff181818),
    panel: Color(0xff141414),
    card: Color(0xff1e1e1e),
    hover: Color(0xff252525),
    workspace: Color(0xff282828),
    tabBar: Color(0xff1c1c1c),
    search: Color(0xff2c2c2c),
    accent: Color(0xffbdcbdc),
  ),
  dusk(
    'Dusk',
    'Soft plum',
    background: Color(0xff181818),
    panel: Color(0xff141414),
    card: Color(0xff1e1e1e),
    hover: Color(0xff252525),
    workspace: Color(0xff463746),
    tabBar: Color(0xff332936),
    search: Color(0xff3d333f),
    accent: Color(0xffd8cce1),
  ),
  midnight(
    'Midnight',
    'Deep indigo',
    background: Color(0xff171b29),
    panel: Color(0xff141722),
    card: Color(0xff202638),
    hover: Color(0xff2a3348),
    workspace: Color(0xff252d43),
    tabBar: Color(0xff1b2030),
    search: Color(0xff262f46),
    accent: Color(0xffb1c7f5),
  ),
  slate(
    'Slate',
    'Cool blue gray',
    background: Color(0xff222a35),
    panel: Color(0xff1b222c),
    card: Color(0xff2c3543),
    hover: Color(0xff374457),
    workspace: Color(0xff354153),
    tabBar: Color(0xff273140),
    search: Color(0xff344154),
    accent: Color(0xffbdd3e7),
  ),
  forest(
    'Forest',
    'Quiet evergreen',
    background: Color(0xff18231e),
    panel: Color(0xff141c18),
    card: Color(0xff202c25),
    hover: Color(0xff2a3a31),
    workspace: Color(0xff2b3b31),
    tabBar: Color(0xff1b2720),
    search: Color(0xff293a31),
    accent: Color(0xffb4d8be),
  ),
  ember(
    'Ember',
    'Warm earth',
    background: Color(0xff26201c),
    panel: Color(0xff1e1a17),
    card: Color(0xff312923),
    hover: Color(0xff3d342c),
    workspace: Color(0xff3d322a),
    tabBar: Color(0xff2b221d),
    search: Color(0xff3c3129),
    accent: Color(0xffe6c39e),
  ),
  omarchy(
    'Omarchy',
    'Follows your Omarchy theme',
    background: Color(0xff181818),
    panel: Color(0xff141414),
    card: Color(0xff1e1e1e),
    hover: Color(0xff252525),
    workspace: Color(0xff282828),
    tabBar: Color(0xff1c1c1c),
    search: Color(0xff2c2c2c),
    accent: Color(0xffbdcbdc),
  );

  const HarnessPalette(
    this.label,
    this.description, {
    required this._background,
    required this._panel,
    required this._card,
    required this._hover,
    required this._workspace,
    required this._tabBar,
    required this._search,
    required this._accent,
  });

  final String label, description;
  final Color _background, _panel, _card, _hover, _workspace, _tabBar, _search, _accent;

  // nixfred: every preset answers with its own constants; `omarchy` answers from the live Omarchy
  // theme file (~/.local/state/omarchy/current/theme/colors.toml), falling back to its constants
  // (Graphite's) when the file is missing or a key is absent.
  Color _live(String key, Color fallback) => this == omarchy ? (OmarchyLivePalette.color(key) ?? fallback) : fallback;
  Color get background => _live('background', _background);
  Color get panel => _live('darker_background', _panel);
  Color get card => _live('lighter_background', _card);
  Color get hover => _live('lighter_background', _hover);
  Color get workspace => _live('dark_background', _workspace);
  Color get tabBar => _live('darker_background', _tabBar);
  Color get search => _live('lighter_background', _search);
  Color get accent => _live('accent', _accent);
  Color get foreground => _live('foreground', const Color(0xfff5f5f5));

  static HarnessPalette fromId(String? id) =>
      values.where((palette) => palette.name == id).firstOrNull ?? graphite;

  Map<String, int> get nativeColors => {
    'tabBar': tabBar.toARGB32(),
    'workspace': workspace.toARGB32(),
    'search': search.toARGB32(),
    'accent': accent.toARGB32(),
  };
}

/// nixfred: the Omarchy theme's colours, read once and on demand. `refresh()` re-reads the file (the
/// palette picker calls it when Omarchy is chosen, so a theme switch shows on the next pick).
abstract final class OmarchyLivePalette {
  static Map<String, Color>? _colors;
  static Color? color(String key) => (_colors ??= readOmarchyColors())[key];
  static void refresh() => _colors = readOmarchyColors();
}
