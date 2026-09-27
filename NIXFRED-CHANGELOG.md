# nixfred changelog

The nixfred fork of OpenHarness (github.com/nixfred/openharness) adds the features listed in PLAN.md
on top of upstream. Every entry names the upstream commit it sits on, what was verified and what was
not. Upstream's own CHANGELOG.md is untouched. Nothing here has been submitted upstream yet; see
"Submitting" in PLAN.md for how each piece becomes its own PR when the time comes.

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
