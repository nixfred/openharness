# nixfred visual system

Rule from Fred: custom everything, a ton of graphics, cyberpunk, but never a graphic that carries no
function. Every image, ring, arc or glow below answers a question a person has at that moment. Where
a screen is only text, it stays text.

## The language (shared by device, bar and desktop)

- Black is the canvas. The device is AMOLED: black pixels are off, so black saves power and prevents
  burn-in. The bar and the app follow the Omarchy theme's background.
- Neon comes from the theme, not from us: accent, yellow, red, green out of
  `~/.local/state/omarchy/current/theme/colors.toml`. Change the theme and every surface follows.
- One ring per agent, everywhere. Ring colour and motion are the state (working sweep, waiting breath
  in yellow, permission breath in red, done fill, failed double flash, offline dim). A person learns it
  once on the bar and reads it on the device and in the app.
- Arcs are quantities. Spend, token budget, battery, VRAM, thermal: arc from 0 to 100 percent that
  turns amber at the warn point and holds red at the cap. Never a bare number where an arc can be
  read from across the room.
- Glow is urgency. A soft outer glow behind whatever needs Fred next, nothing else glows.
- Scanlines and grain only on idle or transition screens, at 6 to 10 percent opacity, never over text.
- Type: the theme's monospace for anything a person copies (ids, paths, commands), the UI face for
  everything else. All caps for tiny labels only.
- Every animation sits behind one reduced-motion switch and never changes layout (Law 17).
- Accessibility: every state also has a glyph (~ ? ! x * - .) and a word, so colour is never the only
  signal.

## Device (466 x 466 round AMOLED, LVGL 9.5, images baked as RGB565A8 C arrays)

Firmware screens are listed by the functions in `ui_screens.c`. Graphics per screen:

| Screen or function | Graphic that carries function | Not added |
|---|---|---|
| Boot (`ui_enter_boot_loading`, `ui_ota_boot_pct`) | Arc around the rim filling with the OTA or boot percent, a single neon line scanning the rim once per second so a stuck boot is visible as a stopped line | No logo splash: it shows nothing |
| Unpaired / pairing (`ui_show_unpaired`, `ui_show_pairing`) | The pairing code in monospace at 72 px inside a hexagon; hexagon edges pulse until the daemon answers, then snap solid | No illustration |
| Connecting (`ui_show_connecting`) | A dotted ring that draws itself clockwise, one dot per retry, so the count is visible | |
| Home overview (`ui_home_overview`, `ui_show_projects`) | One ring per agent on the rim, agent name in the ring, the busiest ring nearest the top; the centre shows the fleet summary glyph and count (for example `? 1`) | Background stays black |
| Agent detail (`open_agent_detail`, `render_busy_row`, `ui_project_set_todos`) | Ring in the state colour around the agent name; a todo list rendered as a vertical progress rail with lit segments; the engine's icon as a small 44 px glyph (the shipped icon style) | |
| Recap (`render_recap_block`, `ui_notify_task_done`) | Done state: the ring fills to a solid dot then the recap text slides up; a thin diff-stat bar (green added, red removed, proportional) under the text | |
| Question (`ui_question_show`) | Fred's face full-bleed with the yellow ring; options as pill buttons on the lower arc; the option under the finger glows | |
| Permission (question with `permission: true`) | Fred's face with the red ring and a lock glyph at 12 o'clock; the command in monospace | |
| Failed (`ui_show_error`, `ui_leave_error_screen`) | Two quick red flashes of the rim then a steady thin red ring; the error text in monospace; a "retry" pill | |
| Voice (`ui_voice_start`, `ui_voice_stop`, `ui_voice_routed`) | Live level meter as a ring whose thickness follows the microphone; when routed, a dot flies from the centre to the chosen agent's ring | |
| Voice quota (`ui_voice_quota_status`, `ui_voice_quota_exceeded`) | Arc of quota used; exceeded holds red | |
| Machines (`ui_show_machines`, `ui_machine_selected_ack`) | Each machine as a hexagon tile with its capability line under it (GPU free, load, battery) and a small arc for VRAM; the selected one glows | |
| Model picker (`build_model_picker`) | Text list; a small local-vs-cloud glyph per row (a house for local models, a cloud for hosted) | No art |
| Brightness (`build_brightness_screen`) | The arc IS the control | |
| Lock (`ui_lock_setup`, `ui_lock_init_gate`) | The dimmed vignetted idle face (black edges) with the time; drifts 1 px every minute against burn-in; wakes to the unlock pad | |
| Notifications (`ui_notif_open`, `ui_notif_swipe_up`) | Card slides up from the rim with the state colour on its left edge; swipe up dismisses with a short trail | |
| Swarms (`ui_swarms_replace`) | A ring of rings: parent in the centre, children around it, each in its own state | |
| Cable toast (`ui_cable_toast`) | Bottom arc message only | No art |
| Spend brake (new) | Spend arc on the agent ring, amber at 80 percent, red and pulsing once at the cap with the dollar figure | |
| Panic stop (new) | One tile: every ring collapses to a point together, then a single steady red dot until released | |

Assets shipped: `nixfred/device-art/` (round face, waiting ring, permission ring, idle vignette, 96 px
and 48 px). The LVGL C array is regenerated from the PNG (see the ImageMagick and Python one-liner in
the session notes) and lives outside git because it is 3 MB of text.

## Bar (Harness Pulse, Quickshell)

- Rings per agent as shipped, plus: the fleet glyph and count at the left, a spend arc as the outer
  edge of each ring when a cap is set, a machine glyph (hexagon per host) in the tooltip, and the
  48 px face inside the ring that is waiting on Fred.
- Click: focus the Harness window. Middle click: panic stop with a two-second hold (the ring drains
  as you hold, release early to cancel). Scroll: cycle which agent the tooltip shows.
- Idle bar: rings shrink to dots. Nothing animates when nothing needs anyone.

## Desktop app (Flutter)

- Pane border glow in the state colour, 2 px, only for waiting, permission and failed.
- A new task drops into its pane (translate and fade, 240 ms).
- Spend arc on the pane header; token count only on hover.
- Theme following through `omarchy_theme.dart` so the app is the same neon as the bar.
- Machine strip: hexagon tiles with capability arcs, the same shape as the device's machine screen.

## Harness viewers

- The omarchy-quickshell harness viewer shows the Test Drive screenshots in a filmstrip with the
  check result as a ring per shot (green clean, red QML error).
- No graphics in the larry-memory or pai-skills harnesses: they are text tools.

## Order

Device art needs a firmware build (Phase 6). Bar and desktop items need no firmware and can ship in
the next cut: face-in-ring, spend arc, fleet glyph, middle-click panic stop, pane glow, theme following.
