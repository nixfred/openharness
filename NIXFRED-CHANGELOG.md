# nixfred changelog

The nixfred fork of OpenHarness (github.com/nixfred/openharness) adds the features listed in PLAN.md
on top of upstream. Every entry names the upstream commit it sits on, what was verified and what was
not. Upstream's own CHANGELOG.md is untouched. Nothing here has been submitted upstream yet; see
"Submitting" in PLAN.md for how each piece becomes its own PR when the time comes.

## Device firmware graphics, first slice, 2026-09-30 (branch nixfred/firmware-graphics)

Sits on nixfred/main 7275f4fa. Firmware version `0.0.86-nixfred.1` (devices/harness-device/firmware/version.txt),
built with ESP-IDF v5.5 (the version dependencies.lock pins, 5.5.0), 1,659,584 B against an 8 MB slot.

- Renderer: two new run types in the habitat compositor (terminal.c), both integer only and allocation
  free. `ht_ring` draws an antialiased ring or arc (1/4096 turn, clockwise from 12 o'clock) and reports
  a tight sector box for damage, so a moving rim segment repaints its sector and not the face.
  `ht_mask` draws a one-colour alpha mask through the sprite path.
- Boot, loading and firmware-transfer face (`render_brand`): the Harness mark (generated from this
  repository's docs/branding/app-logo/harness-logo-4.svg, 150 px) in the theme accent with a three-band
  glow, the wordmark under it, and the rim: a scanner segment that laps once a second while it boots
  or waits for the daemon (a stuck boot is a stopped line), or an arc filling with the transfer percent
  plus the number when the daemon pushes firmware (`ui_ota_boot_pct` was a no-op before).
- Question screens (question, choices, answer review): the waiting ring in yellow on the rim with a
  soft inner glow and a badge at 12 o'clock holding a neutral person figure. A permission prompt turns
  the ring red and adds a lock glyph beside the badge. The daemon now marks each item of a permission
  dialog `permission: true` (`withPermissionFlag`, cli/src/cable/cableHost.ts); stock dials ignore it.
- Hooks, not features: the cable protocol carries no logo, avatar or initials, so the logo is the
  bundled Harness mark and the badge reads `s.avatar_initials` (empty today, neutral figure). No spend
  data reaches the dial, so the spend arc is not in this slice. Nothing of Omarchy's and no face is
  bundled.
- Stock auto-offer: the daemon never offers a published release to a dial whose version is not plain
  x.y.z (the upstream dev-build rule in fwPush.ts `shouldOffer`), so the `-nixfred.N` suffix keeps stock
  from overwriting this image. A spec pins that for this version string.
- Verified: firmware builds; new host test test/test_nixfred_ring.c (ring coverage, sweep direction,
  wrap across 12 o'clock, partial redraw equals full redraw, mask) passes under UBSan; CLI specs for
  cableHost and fwPush pass (62), tsc clean. Flashed to the dial on gus over USB (idf.py flash, NVS kept);
  the daemon logged `dial 80:45:6B:35:06:CC on fw 0.0.86-nixfred.1 proto 3` and made no offer.
  nixfred/device-art/firmware-graphics-host-render.png is a HOST render of the firmware's own drawing
  calls (test_nixfred_ring with NIXFRED_SHOT_DIR), not a photo of the glass; the firmware has no
  screen-capture path. Not verified: the physical screen by eye, a live permission prompt on the dial.
- Known: test/run.sh stops at its first compile on this host (glibc hides `strnlen` under -std=c11);
  pre-existing, not touched here. The new test compiles with `-D_DEFAULT_SOURCE`.
- Recovery: the unchanged stock 0.0.86 build is kept on gus at ~/esp/recovery-stock-0.0.86
  (`esptool write_flash @flash_args` from that folder, or `harness flash` for the published image).

## Watch mode: live Orca sessions on the app and the device, 2026-09-30 (branch nixfred/orca-sessions)

Sits on nixfred/main 1a455d60 merged with upstream/main (385 commits). See docs/nixfred-orca.md.

- Claude and Codex sessions this daemon did not start (Orca terminals, any terminal) become external
  roster rows from their own hooks: engine, cwd, title, live transcript, attention state. They are
  marked `external` on the agent frame and the attention feed, and are never moved, resumed or killed.
- Answers from the device, the app or `harness orca answer` are typed into the session's Orca
  terminal with `orca terminal send`; tmux rows keep the stock path. Ctrl-C/Ctrl-D refused. Every
  send is journaled (`kind: answer`). Orca's hook token is never forwarded.
- Off by default: `harness orca on|off|answers on|off`, `HARNESS_ORCA_WATCH=0`. With it off,
  notify.mjs posts nothing for non-tmux sessions (stock behaviour).
- Claude Notification hook added to the installer (inert in tmux panes and while watch mode is off).
- Fix: registry.save() dropped every hosted row (Hermes store rows included) from memory; kept now.
  The Hermes sweep no longer retires rows that are not its own.
- Verified: tsc clean; CLI suite 7596 pass, 3 fail, 37 skipped (the same 3 environmental failures as
  the post-sync baseline: two dsh node-path specs that also fail on nixfred/main, one real-tmux timing
  spec). Live on a second daemon (port 18599, scratch data, cable disabled): a real Claude session in a
  real Orca terminal registered from SessionStart, asked two AskUserQuestion dialogs, both answered
  (window-protocol answer and `harness orca answer`) and delivered into Orca; answers-off refused a
  third without typing; SessionEnd took the row offline; off switch ignored further hooks.
  Codex only simulated through notify.mjs. Not verified: the physical USB device (the live daemon owns
  it), a real permission prompt (Bash is pre-allowed on the test machine), the desktop app UI.

## nixfred desktop motion and branding on nixfred/main b82e4135, 2026-09-29 (branch nixfred/heavy-anim-app)

- Pane attention frame, one motion per state: working sweeps an accent comet around the border,
  waiting breathes yellow, permission and failed pulse red with a scan band inside the border
  (failed opens with a double flash), done draws its border once in green. 280 ms colour
  cross-fades between states. Idle and offline paint nothing and schedule no frames.
- Spend arc around the pane header's engine mark (accent, amber from 80 percent, red at the cap
  with one pulse). While an agent waits on you, the mark becomes your avatar inside the ring.
- Fleet overview (command bar "Fleet overview", Ctrl+Shift+G): hub, machine hexagons, agent rings
  in their state colours; orbit only while work runs, packets out for work and back for questions.
- Cold-launch boot splash, 1.5 s, skippable by click or key, still under reduced motion.
- Settings, Appearance: boot logo picker (Omarchy read at runtime from /usr/share/omarchy, Harness,
  Custom SVG or PNG up to 2 MB, None) and avatar picker (generic, initials, ~/.face, custom image).
  Nothing of Omarchy's and no personal asset is bundled. Keys documented in nixfred/DESIGN.md.
- Reduced motion from the platform or HARNESS_REDUCED_MOTION=1; loops stop when the window is
  unfocused or nothing is live; RepaintBoundary around every painter.
- Verified: flutter analyze has no issues outside vendored third_party/xterm (13 there, pre-existing);
  flutter test 3832 pass, 0 fail (baseline on this worktree 3806 pass, 0 fail); flutter build linux
  --release succeeds; screenshots taken from running release builds. Gallery CPU (release, 30 s,
  sampled before the branding pass): all idle 0.00 percent, states cycling 9.63 percent of one core,
  reduced motion 0.40 percent. Not verified: focus-loss pausing on the real Linux embedder, the pane
  states inside the production app with a live daemon, and dispatch or clip-drop flow lines (the
  attention frame does not carry them).

## Harness Pulse 0.2.0: heavy animation and a fleet view, 2026-09-30 (branch nixfred/heavy-anim-bar)

- Bar rings: working throws a comet with a fading trail; waiting breathes a halo; permission strobes
  red with a chromatic glitch; failed strobes and glitches once, then holds with a glitch tick every
  6 s; done fills with an overshoot and a shockwave; offline is a dim dashed ring; idle shrinks to a
  dot. Spend arc sweeps to new values. Shape paths and render-thread animators replace Canvas.
- Fleet view popup (right-click, or `qs ipc call nixfred.harness-pulse toggle`): machine hubs with
  agents in orbit (the orbit turns only while something works), glowing hub and tethers for agents
  that need you, state chips, pulsing collision badge, spend gauges that sweep up on open, a bounded
  activity ticker (40 rows, the only thing that scrolls) and a hold-to-stop hexagon that charges edge
  by edge over 2 s.
- Public-release settings in the widget settings UI: `avatar` (Auto: avatarPath, else ~/.face, else
  initials; Initials; None), `avatarPath`, `avatarInitials`, `logo` (Harness, Omarchy read from
  /usr/share/omarchy/logo.svg at runtime, Custom, None), `logoPath`, plus the existing ones. Every
  setting documented in the plugin README. Nothing personal ships.
- The roster is dropped after a minute without the daemon, so the popup never shows stale agents.
- Verified in Test Drive (Omarchy 4.0.2, quickshell 0.3.1) against a fake daemon with generic
  machine and agent names: shell log clean apart from the expected missing ~/.face notice; bar,
  popup, reduced motion, Omarchy logo and connecting states screenshotted. Not verified: the physical
  press and hold (no pointer injection in the VM), animation smoothness and CPU cost over time (stills
  only), and a real daemon.

## Subscriptions screen (branch nixfred/subscriptions), 2026-09-30

- One screen for every AI plan on the computer: Settings, Subscriptions in the app, `harness subs
  [--json]`, `harness subs set <id> on|off`, `GET /api/subscriptions`, a local `subscriptions` frame,
  and a compact `subscriptions` block on the attention payload for the bar and the device.
- Per plan: weekly (Kimi: monthly) percent used as an arc, percent banked against an even pace
  (signed: negative means over pace), a burndown line against the even-pace diagonal, reset
  countdown, come-back timer when over, a pace sentence, and the "use this plan next" verdict with
  a glow on that card. Reduced-motion aware; the pane never scrolls.
- Providers: Claude (OAuth usage endpoint with Claude Code's own login; macOS keychain supported),
  Codex (rate-limit snapshot in its own session rollouts, no network), Grok (billing snapshot in its
  own log, no network), Kimi (`/usages` with `KIMI_API_KEY`). Absent providers read "not detected"
  and make no request. The local GPU is not a subscription card.
- Pace, banked, come-back and next-plan math ported from Burn Bar (github.com/nixfred/burnbar),
  with its pace and guidance suites ported case for case (46 tests). Burn Bar is not needed.
- Docs: `docs/nixfred-subscriptions.md`.

Verified on gus: all four providers live through a local daemon surface and `harness subs`.
Not verified: macOS keychain path on a real Mac, the frame on the device, the bar widget (follow-up,
owned by the bar branch).

## nixfred 0.1.3 synced to upstream 56651674, 2026-09-27

- Merged upstream through #399 (engine store paths, Hermes hook timing, session branches). Upstream
  renamed `updatedAt` to `touchedAt`; Hermes hosted rows follow it.
- PLAN.md Phase 0: install with `--no-updates` (unsigned updates, OH-6) and a day-0 swap from stock
  to fork that keeps a copy of `~/.harness`.
- Verified: tsc clean, CLI 5368 pass / 7 fail (all upstream or known flakes), flutter analyze clean.
  Not verified: anything on the device, which arrives Tuesday.

## nixfred 0.1.3 (CLI 0.2.88-nixfred.3) on upstream aeb50151, 2026-09-27

- Synced to upstream aeb50151 (session search across machines, #368).
- Desktop pane glow: a pane's border breathes yellow while its agent waits on you and red on a
  permission request or failure. Value-equal state rows, so the once-a-second frame repaints nothing.
- Omarchy palette: Settings, Appearance gains "Omarchy", read live from your Omarchy theme file
  (background, darker/lighter background, accent, foreground), re-read when picked, Graphite's
  colours as fallback. The other presets are unchanged.
- Mike Gannotti's per-computer tab profile (upstream PR #233) carried, rebased onto current main,
  with two follow-ups upstream's new tab bar needed. Also on its own branch,
  `nixfred/pr-233-rebased`, for him.
- Harness Pulse: hold the hexagon 2 s to stop every agent on the machine.
- README section on how this fork differs from upstream; `nixfred/main` is the fork's default branch.

Verified: Flutter 3.47.5 installed user-local; `flutter build linux --release` succeeds; glow (2),
palette and appearance (71), tab profile, settings and swarm (316) tests pass; the full Dart suite
fails the same 25 tests upstream fails on the same commit. CLI suite: the 11 baseline failures plus
the known orchestrator flake. Not seen live: the glow and the Omarchy palette in a running app,
the physical hold on the bar.

## nixfred 0.1.2 (CLI 0.2.88-nixfred.3) on upstream 46897998, 2026-09-27

- Fleet dispatcher end to end (`harness dispatch`, `dispatches`): a bounded job to a linked machine
  over the daemon's own E2EE relay session; result read off the worker's `DISPATCH_RESULT:` line.
- Clipboard and file drop between paired machines (`harness clip push`), sealed as a machine request.
- Harness Pulse: spend arc on each ring's outer edge (accent, amber at 80 percent, red at the cap)
  and the person's face inside the ring of an agent waiting on them, from an `avatarPath` setting
  (empty by default). Validated in a Test Drive VM (quickshell 0.3.1): MultiEffect round mask works,
  arcs at 0.31, 0.86 and 1.04 render as accent, warning and red; screenshots under ~/VMs/test-drive/evidence/.
- Attention payload carries `spend` and `lane` per agent. README lists every fork command.

## nixfred 0.1.1 (CLI 0.2.88-nixfred.2) on upstream 46897998, 2026-09-27

Everything read off Mike Gannotti's fleet (@MichaelGannotti, 23 Hermes/Grok Bot/OpenClaw agents on
Omarchy, the person who put the device in front of Fred). Details are in the 0.1.0 section under
"For Mike Gannotti's flow".

- Every Hermes profile session on the roster, pane or not (Hermes Desktop bots, Bot Mode, gateway).
- Gate lanes: per-agent rules by name. Collision alarm with branch locks and a bar badge.
- Hermes profile race fixed (OH-F1). Hermes health check with doctor stamp (`harness hermes`).
- CI-failure wake into the agent's pane. Battery mode. `harness attention --kanban`, `harness loops`.
- Hermes attention plugin skeleton (agent tool + slash command + Desktop status bar) under
  nixfred/hermes-plugin/, built from Nous's plugin docs; untested inside Hermes (no install here).
- Not carried: his PR #233 (conflicts on current main, Flutter).

Verified: tsc clean; full suite baseline plus one timing flake; real sqlite3 specs for the Hermes
backend and reader; badge validated in a Test Drive VM. Not run on a device or inside Hermes.

## nixfred 0.1.0 (CLI 0.2.88-nixfred.1) on upstream 46897998, 2026-09-26

The first cut. Phases 1 through 5 of PLAN.md in code; Phase 0 (stock baseline) and Phase 6 (device
firmware) wait for the device and for firmware signing.

### Daemon (cli/)

- Attention states. One typed state per agent: working, waiting, permission, failed, done (unreviewed),
  idle, offline, each with a non-colour glyph and a label. Fed from turn events, the question watcher,
  permission dialogs, cancels and engine errors. Pushed to local windows as an `attention` frame,
  served at `GET /api/attention` on the loopback API, summarised by the most urgent state present.
- Desktop notice. `notify-send` (Linux) or `osascript` (macOS) when an agent waits, needs permission
  or fails, with a "Show me" action that focuses the Harness window. Never steals focus on its own.
- Recap export. On every finished turn a JSON line under `data/recaps/<day>.jsonl` (machine, agent,
  engine, cwd, detail) so breadcrumbs and `mem search` never parse engine transcripts.
- Destructive-action gate. `harness gate init|install|uninstall|status|reload`. Opt-in Claude Code
  PreToolUse hook; the daemon classifies each tool call against `data/action-policy.json` (default:
  git push, force push, hard reset, branch -D, rm -rf, sudo, curl|sh, chmod 777, writes under
  ~/.claude, systemctl changes ask; disk writes, ~/.ssh, ~/.env, `omarchy refresh` deny) and answers
  with `permissionDecision`, so the engine shows its own prompt and the device mirrors it.
- Spend brake. `harness spend status|set|off|on`. Per-agent and per-day token and dollar caps with a
  price table by model family; 80 percent warns, 100 percent holds the pane and tells the web why.
- Machine capabilities and loop policy. `harness capabilities`, `harness placement`. GPU (nvidia-smi),
  CPU load, AC/battery, thermal, lid, toolchains on PATH. A `/loop` submit is deferred on battery,
  closed lid, busy GPU or quiet hours (23:00 to 07:00 America/New_York), and one machine per job via
  a lease file.
- Adopt existing panes. `harness adopt %N [engine]`, `unadopt`, `adopted`. A pane the daemon did not
  create is whitelisted for discovery, so a long-running agent shows up without a restart.
- Panic stop. `harness stop-all [--except=<agentId>]` cancels every agent turn on this machine.
- Audit journal. Append-only, secret-redacted `data/audit.jsonl` (rotates at 20 MB, keeps 5) for
  tool starts, turn transitions, gate and spend decisions and commands. `harness audit [n]`.
- Spans. OpenTelemetry-shaped spans per agent turn to `data/spans.jsonl`, and to
  `OTEL_EXPORTER_OTLP_ENDPOINT/v1/traces` when that variable is set.
- Checkpoints and bundles. `harness checkpoint <agent> --brief=...`, `checkpoints`, `restore`,
  `harness bundle <agent>` (redacted transcript excerpt, patch, diff stat, audit tail, sha256 manifest,
  tarball).
- Session recording. `harness record start|stop <agent>`, `harness pin <agent> <label>`, `pins`,
  `asciicast` (tmux pipe-pane to a raw log with pinned moments, exported as asciicast v2).
- Remote orchestrator backend (library only, not wired): `cli/src/nixfred/remoteOrchestratorBackend.ts`
  gives the existing orchestrator a way to create, message and await an agent on another machine.
  The worker-side `dispatch_result` frame is not emitted yet.

All of it lives in new files plus small taps in `cli.ts`, `hookServer.ts`, `hook/notify.mjs`,
`lib/hooks.ts`, `lib/askQuestion.ts` (permission flag on onQuestion) and `lib/tmuxAgentDiscovery.ts`.

### Omarchy side (nixfred/)

- `plugins/pi.harness-pulse`: Quickshell bar widget, one animated ring per agent off `/api/attention`
  (working sweep, waiting breath, permission breath in red, done fill, failed double flash, offline
  dim), reduced-motion switch, Law 17 density, python3 feed helper.
- `hooks/harness-breadcrumb.hook.ts` (Claude Stop hook writes a breadcrumb note under
  ~/.claude/MEMORY/BREADCRUMBS), `hooks/harness-blip-question.hook.ts` (question to iMessage via
  Blip, self thread), `bin/harness-blip-answer`, `bin/harness-second-opinion` (diff to codex, grok or
  kimi), `bin/harness-changelog-x` (CHANGE.log line plus an X post draft, never posts).
- Domain harnesses: `harness/omarchy-quickshell` (pinned Qt6, qmllint, Test Drive push/check/shot,
  AGENTS.md with the Alt/Super swap and the no-scroll rule), `harness/larry-memory` (read-only
  `mem search`), `harness/pai-skills` (any engine gets the PAI skills library, read-only).

### Desktop (desktop/)

- `lib/theme/omarchy_theme.dart`: Omarchy `colors.toml` to a Flutter ColorScheme. Written without a
  Flutter SDK on the build host; UNTESTED and not wired into the app yet.

### For Mike Gannotti's flow (shipped in 0.1.1, detailed below)

Read from his last week on X (@MichaelGannotti, 23 Hermes/Grok Bot/OpenClaw agents on Omarchy, the
person who put this device in front of Fred). Three things he said, three things built:

- "agents drift quietly towards grabbing things solo and I have to occasionally reign them in", and
  lanes are "who plans, who checks, who drafts, and who is never allowed to merge or post without me":
  the gate now has **lanes**. `action-policy.json` takes `lanes: [{name, agent: <regex on the agent's
  name>, rules: [...]}]`; lane rules run before the machine rules, so a planner named Aiona can be
  denied every git write while Peyton PR is asked before `gh pr merge`.
- His bug #191 (activity cards empty for Hermes profile agents) was fixed upstream, but the race we
  reported as OH-F1 remained: the first session in a new `hermes -p <profile>` could poll the default
  store forever. **HermesReader now re-resolves the store** while nothing has been read and switches
  the moment the profile's state.db appears (`resolveDbPath`, test included).
- "I really love LOVE the Hermes Kanban and it's essential when orchestrating an AI fleet":
  `harness attention --kanban` prints the fleet as columns (needs you, failed, done unreviewed,
  working, idle), the same states the bar and the device show.
- "agents drift quietly towards grabbing things solo": the **collision alarm**. Every tool call is
  journaled and fed to a watcher; two agents on the same file, the same folder or the same branch
  inside an hour raise one alert (deduped per hour) that rides on the attention payload, reaches the
  bar and the desktop notification, and shows in `harness collisions`. Branches are observed every
  minute from each agent's folder. `harness lock <repo> <branch>` claims a branch for one agent so
  anyone else touching it alarms at once; locks persist in `data/branch-locks.json`.
- His five Hermes rules as a check: `harness hermes` reports every Hermes home (default plus each
  `profiles/<name>`) with state.db size and age, processes holding it open (lsof), memory folder
  size against a budget, profile isolation, and whether `hermes doctor` has run since the current
  version (`harness hermes doctor-done` stamps it). Green, amber or red per home and overall, ready
  to draw as one arc per profile.
- CI-failure wake (library, wired when the Hermes session backend lands): `nixfred/ciWatch.ts` polls
  `gh pr checks` for an agent's branch and produces one message per newly failing check with the
  log tail and "fix, test locally, push, do not merge". His Peyton PR sweep only interrupts on red.
- Battery mode: when the machine is on battery, a waiting agent shows on the bar and device but only
  permission and failure pop a desktop notification. `harness loops` lists the loop policy, live
  leases and the capability line.
- Fleet dispatcher, end to end: `harness dispatch --machine=<id> --repo=</path/on/that/machine> "brief"`
  hands a bounded job to a linked machine over the daemon's own E2EE relay session (the same pool the
  window uses), creates the agent there on its own branch, and reads the result back off the worker's
  own text: the worker prints one `DISPATCH_RESULT: {json}` line and the controller parses it at turn
  end. No new wire type and no change on the worker side. `harness dispatches` lists records; each
  finished job is appended to `data/dispatches.jsonl` and pops a desktop notice.
- Known flake: the wiring spec's spend-brake case failed twice out of about twenty runs, only when the
  whole suite ran alongside it; 11 consecutive runs of the file alone pass. Not understood yet.
- Clipboard and file drop between paired machines: `harness clip push --machine=<id> [text]` or
  `--file=<path>` (25 MB cap). Sealed end to end as a machine request (registered in
  applicationFrames.ts; core.ts is a pinned interop keystone and is untouched). Text lands on the
  remote clipboard (wl-copy, xclip or pbcopy), files under ~/Downloads/harness-drop with basename-only
  names and no overwrite. With no text or file, the local clipboard is what gets sent.
- His open upstream PR #233 (per-computer tab profile) no longer merges cleanly on current main
  (conflicts in desktop/lib/state/app_state.dart and screens/swarm_screen.dart); not carried here
  because the Flutter side cannot be built on this host. Worth telling him.

### Verified

- `cd cli && npm run typecheck`: clean.
- `npm test`: 4,851 passed, the same 11 environment-bound failures as upstream 46897998 on this host
  (dsh shell suites, hookNotify launcher journal, gridHandoff child). 82 new tests.
- `RUN_REAL_TMUX_DISCOVERY=1 npm run test:tmux-real` (tmux 3.7c): 11 passed, 6 skipped for engines
  not installed here.
- Bar widget: see the Test Drive result recorded in PLAN.md status.

### Not verified

- No Harness device was available. Nothing device-side was run.
- No Flutter SDK: the Dart theme file is unbuilt.
- The gate's PreToolUse path was unit-tested at the daemon and the hook script was syntax-checked,
  but not run against a live Claude Code session yet.
- Loop leases are per machine file; the cross-machine story needs the dispatcher.

### Known gaps carried to the next cut

- Fleet dispatcher end to end (worker emits `dispatch_result`; orchestrator gets a machine backend).
- Encrypted clipboard and file drop between paired machines.
- Device firmware work (Phase 6) waits on signed firmware.
- Hyprland urgency hint is via notify-send only; no window-manager urgency flag yet.
