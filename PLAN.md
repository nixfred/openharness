# OpenHarness enhancement plan (nixfred fork)

Working copy for the 24 ideas in the 2026-09-26 review. The stock checkout at
`~/Projects/autonomus.harness.device` is never modified; it is what gets installed on
Tuesday 2026-09-29 when the device arrives. Everything here is built on `nixfred/main` and,
where it belongs upstream, offered as a PR from the `nixfred/openharness` fork.

War cry: We can fix everything!

Legend: (a) upstream contribution, (b) ours (Omarchy plugin, hook, side tool), (c) both.
Risk: how much Harness core has to change. Impact: how much of a normal day it changes.

## Phase 0: stock baseline (Tuesday 2026-09-29, day 0)

Install stock from the checkout, not the installer: `cd cli && npm ci && bash scripts/install-cli.sh`,
then `harness login`, `harness remote-password set`, `harness start`, plug in the device.
Record the baseline: screenshots of the app on gus, a short phone video of the device, `harness status`,
the daemon log, and notes on what the device shows for each agent state. Do NOT touch the fork
until this is done. Everything after is judged against this baseline.

Also on day 0, read-only observations we need for Phase 1: the exact Unix socket path the daemon
opens (#364), the frame types it emits for agent state, and the recap payload the device receives.

## Phase 1: low-hanging fruit (week 1). Zero change to Harness core, all (b), all reversible

These read from the daemon or from hooks. They cannot break Harness, and each is a stand-alone win.

1. Harness Pulse bar widget (idea 4 from the first list, the bar feed). Quickshell plugin reading the
   daemon's local socket: one ring per agent, colour by state (working, waiting on you, failed, done
   unreviewed), machine glyph, click focuses the pane. Impact high: this is the device's job, on the
   bar, on every monitor. Risk none. THE animation showcase, see below.
2. Turn breadcrumbs (15). Stop-hook writer: what, why, tags, repo, machine, agent, into ~/.claude so
   `git log --grep` and `mem search` find agent work. Impact medium, effort small.
3. Second-opinion command (17). `harness-second-opinion [codex|grok|kimi]` sends the current diff
   for review, using the runners that already exist. Impact medium, effort small.
4. CHANGE.log to X-queue pipeline (24). On merge, draft the CHANGE.log line and the X post with
   verified handles. Impact medium, it automates a standing rule. Effort small.
5. Blip answer channel (18). Claude Code question hook to Blip iMessage, reply routed back to the
   pane by agentId. Impact high for time away from the desk. Effort medium. Risk low, hooks only.
6. Omarchy/Quickshell domain harness (10). A folder with harness.json: pinned Qt6, qmllint,
   Test Drive push/check/shot, an AGENTS.md carrying the Alt/Super swap, Law 17 no-scroll, and the bar
   conventions; `shot` PNGs into the web viewer. Impact very high for plugin work, and it is the
   flagship harness for omarchy.nixfred.com. Effort medium. Risk none to core.
7. Omarchy theme following in the desktop app (19, app half). Read ~/.config/omarchy/current/theme
   and map to the Flutter theme. Small Dart change in the fork only. Device half waits for Phase 6.
8. Command audit journal (12, local half). Append-only, redacted, per machine. Hook-based first;
   the upstream version comes in Phase 5.

## Phase 2: foundations upstream (weeks 2-3). (a), moderate risk, unblocks Phases 3-4

Order matters here: 1 before everything, 5 before the brakes.

1. Adopt existing tmux panes (1). Register a running pane, transcript and cwd with the daemon
   without restarting the agent. Impact: the device and app finally see the Larrys already running.
   Risk moderate (registry and transcript readers). First upstream PR.
2. Attention classification (5, plumbing half). One typed event for question / permission / failure /
   done-unreviewed / idle, emitted on the local socket and to the device. Impact high, it is the
   input for Pulse, the inbox, the brakes and the device. Risk moderate (touches turn lifecycle).
3. Local recap export (15, upstream half). A stable per-turn recap file so breadcrumbs stop parsing
   each engine's transcript. Small.
4. Hyprland urgency and notify-send with a "show me" action (5, desktop half). Small, (c).

## Phase 3: the brakes (weeks 3-4). Depend on Phase 2.2. Highest safety value

1. Destructive-action gate (4). Policy file per machine; matching tool calls become the question
   card the device already has; the pane holds until a tap. Impact very high: it turns the default
   auto-approve into something Fred's Laws allow. Risk moderate (hooks into engine permission flow).
2. Spend brake (3). Per agent, machine and Loop; pause the pane, show the number on the device and in
   Burn Bar. Impact very high (overnight-bill insurance). Risk moderate.
3. Tailnet panic stop (14). One chord, one device tile, every turn cancelled except the named pane.
   Small once 2.2 exists. Impact high in the bad moment.
4. Accessibility pass on states (16, software half): non-colour status, reduced motion switch,
   colourblind-safe palette. Cheap to do while touching the state model.

## Phase 4: the fleet (weeks 5-8). Depend on Phases 2 and 3

1. Machine advertisement and placement (6): VRAM, load, battery, thermals, toolchains; refuse
   GPU-heavy work on a busy card. Foundation for 2 and 3 below.
2. Fleet dispatcher / task graph (2): brief out, worktree there, result back. Impact very high.
3. Loop leases and machine-aware scheduling (8): one Larry runs a job; defer on battery/lid/GPU busy;
   catch up on wake; America/New_York.
4. Worktree/PR lifecycle, fleet branch lock, CI-failure wake with log excerpt (9).
5. Portable task checkpoints and context capsules (11): lid-close handoff.
6. Encrypted clipboard and file drop between paired machines (20): rides the E2EE channel.

## Phase 5: memory, observability, sharing (weeks 8-12)

1. Shared memory plane with provenance, read-only mount of Larry's store (7).
2. OpenTelemetry spans and Prometheus metrics; Grafana on mind or blu (12, upstream half).
3. Review and incident bundles, read-only shadow sessions (13).
4. Terminal session replay with pinned moments (21).
5. PAI skills as an installable domain harness (22).

## Phase 6: the device itself (after OH-11 firmware signing lands upstream, or on our own signed build)

1. Device animations: attention pulse, spend arc, handoff sweep (see below).
2. Device as privacy indicator and hard mic mute; GPU/thermal glance tile (23).
3. Theme following on the device screen (19, device half).
4. Accessibility on the device: non-colour states, large-text cards (16, firmware half).
5. Destructive gate and panic stop tiles on the device (4, 14, device half).

Firmware work waits deliberately: flashing our own image on an unsigned pipeline is exactly the
risk OH-11 describes. We either wait for Secure Boot upstream or sign our own build first.

## Animations (Fred's standing interest)

Bar (Quickshell, Phase 1): each agent is a ring. Working: a slow clockwise sweep, 3 s period, theme
accent. Waiting on you: the ring breathes (scale 1.0 to 1.08, 1.2 s, ease-in-out) in the warning
colour, and a single soft pulse travels along the bar toward the ring so the eye is led there even
on the 49-inch. Done unreviewed: the ring fills and settles to a solid dot. Failed: two quick red
flashes then a steady thin red ring, no strobing. Handoff between machines: a dot flies from one
machine glyph to the other along a bezier, 400 ms. Panic stop: every ring collapses to a point
together, 250 ms. All timings behind one `reducedMotion` switch (Law 17 density rules apply; no
layout jumps, rings resize in place).

Desktop app (Flutter, Phase 2-3): pane border glow follows the same state colours; a new task
"drops" into its pane; the spend brake shows a filling arc on the pane header that turns amber at
80 percent and holds at 100 percent with the pane dimmed.

Device (LVGL, Phase 6): the 466x466 round display is made for radial motion. Same ring language as
the bar so the desk and the screen agree; the spend arc wraps the rim; a handoff sweeps around the
bezel; a tap-to-approve ripple confirms the gate.

## Low-risk vs high-change summary

Do first, low risk: Phase 1 in full. Nothing in it can break Harness, everything is ours, each
piece ships alone, and the bar widget is visible on day two.

Do next, moderate change, highest leverage: Phase 2.1 (adopt panes) and 2.2 (attention events).
Almost everything else stands on those two.

Do carefully: Phase 3 brakes touch permission flow; Phase 4 fleet touches transport; Phase 6 touches
firmware. Each waits for its foundation and for upstream's signing work.

## Submitting (per upstream CONTRIBUTING.md, applied 2026-09-26)

Nothing goes upstream until Fred says so and the device has run the code. When it does:

- One topic per PR, cherry-picked from `nixfred/main` onto a fresh branch off `upstream/main` (PRs are squash-merged, so the integration branch itself is never the PR).
- Every PR that touches `cli/` runs `cd cli && npm install && npm run typecheck && npm test`, and, because adoption touches discovery, `RUN_REAL_TMUX_DISCOVERY=1 npm run test:tmux-real`; the PR says exactly which suites ran and which rows were unavailable.
- The PR template is filled in full: what it helps someone do, how to try it (install command, one prompt, expected output, screenshot for anything visual), what was verified (engine, OS, versions, known limits).
- New frame types (`attention`) and the local `/api/attention`, `/api/nixfred` routes count as a shared-protocol change: open an issue first to agree the interface.
- Harness folders (`nixfred/harness/*`) go to `store/agents/<name>/` with `harness dsh check` output and a real run; credit upstream tools and licenses.
- Credentials and private project content are scrubbed from every log and recording before it is attached.

Suggested PR order: adopt panes (1), attention state + /api/attention (2), gate (3), spend brake (4), machine capabilities + loop policy (5), audit + spans (6), checkpoints/bundles/recording (7), harness folders (8), Dart theme (9, after a Flutter build).

## Status 2026-09-26 (nixfred 0.1.0)

Phase 1: all eight shipped in nixfred/ (bar widget QML pending Test Drive result below). Phase 2: adopt panes and attention events shipped; recap export shipped; notify-send with Show action shipped (no WM urgency flag). Phase 3: gate, spend brake, panic stop, glyph/label accessibility shipped. Phase 4: capabilities + placement, loop defer + lease, checkpoints shipped; dispatcher is a library only; clipboard/file drop not started; worktree lock/CI wake not started. Phase 5: audit journal, spans, bundles, recording shipped; memory and PAI skills harnesses shipped. Phase 6: not started by design.
