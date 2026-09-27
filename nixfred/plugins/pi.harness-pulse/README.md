# Harness Pulse (pi.harness-pulse)

One ring per coding agent across every linked OpenHarness machine, on the Omarchy bar.

State language (all behind the `reducedMotion` setting):

- working: a bright quarter arc sweeps clockwise once every 3 s in the accent colour
- waiting on you: the ring breathes (1.0 to 1.08, 1.2 s) in the theme yellow and a soft dot travels along the bar toward it
- permission: same breath, theme red
- done, unreviewed: the ring fills to a solid dot and settles
- failed: two quick flashes, then a steady thin red ring
- offline: dim grey
- every state change: 220 ms colour fade

Rings never change the row height or width (Law 17). The daemon glyph at the left is a hexagon: outline when the daemon is up, filled when it is not. With `reducedMotion` on, each ring shows a one-character glyph instead of moving.

Click a ring to focus the Harness window (`hyprctl dispatch focuswindow class:^(harness)$`; change `focusWindowClass` if the class differs). Hover for name, engine, machine, state and detail.

## Data

`pulse-feed` (python3, no dependencies) polls `GET /api/attention` on the local daemon, over the Unix socket `~/.harness/daemon-18473.sock` first and 127.0.0.1:18473 second, once per `refreshIntervalSec`, and prints one JSON line per poll. Nothing leaves the machine. Exit 3 means the daemon was unreachable for a minute; the widget restarts the feed every 5 s.

The `/api/attention` route is part of the nixfred fork of OpenHarness (PLAN.md Phase 2.2). Stock upstream does not have it yet; the widget then shows the filled hexagon and "Harness daemon not running" until the fork's daemon is installed.

## Install

```
cp -r nixfred/plugins/pi.harness-pulse ~/.config/omarchy/plugins/pi.harness-pulse
omarchy restart shell
```

Never `omarchy refresh`: that is a factory reset of the bar. Add the widget with the bar's own IPC if it does not appear:

```
omarchy-shell shell putBarWidget pi.harness-pulse '{"section":"right","index":1}'
```

Settings live in `~/.config/omarchy/shell.json` under the widget: `refreshIntervalSec`, `maxAgents`, `reducedMotion`, `showMachine`, `focusWindowClass`, `ringSize`.
