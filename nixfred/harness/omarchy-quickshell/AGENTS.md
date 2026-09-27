# Omarchy Quickshell harness

You are building an Omarchy bar plugin (Quickshell + QML on Hyprland/Wayland). This workspace is
one plugin: `manifest.json` at the root, `Panel.qml` as the bar widget entry point, helpers beside
them. Work only inside this workspace.

## Hard rules on this desk

- Keyboard: the physical key labelled Alt sends SUPER on this machine (altwin:swap_alt_win). When you
  describe a shortcut, use physical key labels and never ask for the same key twice.
- Law 17, no page scrolls: every setting and control of a panel is on screen at once. Lists may scroll
  in place inside a fixed box. Width is the remedy, not height. Pro density.
- Helpers are python3, never bun or node: the shell runs plugins with python3 on PATH.
- Never run `omarchy refresh <anything>`. It is a factory reset of the bar. To restart the shell use
  `omarchy restart shell`, and only inside the Test Drive VM.
- Never restore `~/.config/omarchy/shell.json` from a backup. Add a widget through
  `omarchy-shell shell putBarWidget <id> '{...}'`.
- No em dashes in any file you write.

## Test in a VM, not on the live desktop

```
test-drive new plugin <task-name>        # a fresh VM from the plugin-dev checkpoint
test-drive push <vm> . <plugin-id>       # copy this workspace in as the plugin
test-drive restart-shell <vm>
test-drive check <vm>                    # QML errors, shell log
test-drive shot <vm>                     # PNG of the bar
```

Copy every `shot` PNG into `shots/`, then run `toolchain/shots-index.sh` to regenerate
`shots/index.html`; the live viewer shows it. Look at the bottom edge of every screenshot: clipping
is worse than scrolling because nothing tells you rows are missing. Check the shortest screen in the
fleet (1920x1080) as well as the wide one.

Never boot the Test Drive template or reset `test-drive-standby`. One global lock covers all VMs;
"waiting for another test-drive command" means a peer is mid-call. It queues, it is not hung.

## Before you hand back

- `qmllint Panel.qml` (and every QML file) is clean, or the warnings are explained.
- `manifest.json` has id, name, version, kinds, entryPoints.barWidget and barWidget.defaults.
- `version-lock.json` lists the sha256 of every runtime file (see `toolchain/lock.sh`).
- Write `.harness/verdict.json` with `ready`, a one-line `summary`, `findings` and the `artifact`
  (the newest shot).
