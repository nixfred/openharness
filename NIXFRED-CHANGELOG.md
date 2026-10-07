# nixfred changelog

The nixfred fork of OpenHarness (github.com/nixfred/openharness) adds the features listed in PLAN.md
on top of upstream. Every entry names the upstream commit it sits on, what was verified and what was
not. Upstream's own CHANGELOG.md is untouched. Nothing here has been submitted upstream yet; see
"Submitting" in PLAN.md for how each piece becomes its own PR when the time comes.

## Flashing rule (2026-10-02)

Always `systemctl --user stop harness.service` BEFORE `idf.py flash`. The running daemon holds /dev/ttyACM0; on the nixfred.8 flash that left a new bootloader over the old app until a second flash with the daemon stopped. Start the service again after the flash and confirm `on fw <version>` in `journalctl --user -u harness.service`.

## Upstream sync: 70 commits from autonomous-ai/openharness main (7305140e), and go-live, 2026-10-07

Merges upstream/main 7305140e0 into the harnessd sync branch (51c6ba67, the 404-commit port below) as 1ed0916d,
then fast-forwards nixfred/main 6ce9b08a to it. This is the first nixfred/main on upstream's harnessd. Firmware
`0.0.86-nixfred.10`, ESP-IDF v5.5.0, 3,056,480 B against an 8 MB slot (63% free); .9 was never flashed.

- Upstream brought: architecture.spec drops its line budgets for an informational size report (the import
  boundaries are still gated), so the fork's +5,400/+20 allowances are gone; the shell service may run out of
  the core and the remaining daemon feature boundaries moved into services (#1008); SQLite loads lazily in the
  edge services (#981); the gateway and models processes start only when needed (#971, #972); engine contracts
  for Claude Code and Codex (#1010); a Stop hook closes only its own turn (#970); a turn that ended while the
  daemon was stopped (an update, a dial flash) still gets its recap, quietly (`settled` in attach); window auto
  rename from the daemon's `window_name` (#992, #994; off by default, it spends a small model's tokens); SCM
  launch records on registry rows (`scmLaunch`) and `scm_project_info`; device dictation no longer follows a
  stale pane focus (#1005); the desktop pane roster survives a closed connection (#996); false Codex
  suggestion-menu holds (#1003) and answered dialogs above the live composer (#1012) fixed; hn 0.1.15/0.1.16;
  Harness OS 0.1.1 and Apple Silicon installer media; Ollama decision models; daemon soak and chaos tests.
  On the dial (#989, 877dc87e): the 12 o'clock unread dot is gone; the pet holds a blue bell bubble with the
  unread count, rings for about 5 s on a new notice, and a tap on it opens the inbox; the recap card grows with
  its lines.
- Conflicts (7): architecture.spec.ts (upstream's); core/main.ts (upstream's out-of-process shell guard plus the
  `nixfredClip` served request; hook handlers keep the gate verdict and turn-stop attention wrappers beside
  upstream's `onPromptHook` and `stopHookDelayMs`); core/transcripts/attach.ts (nixfred `current` beside
  upstream `settled`); applicationFrames.ts (`clip_push` beside `scm_project_info`); registry.ts (hosted and
  external row fields beside `scmLaunch`; hosted rows still never written to registry.json); ui_habitat.c
  (upstream's bell bubble and its hit target with the nixfred done slide, fleet rim and grab notch, which no
  longer has a dot on it); test_touch_ui.py (nixfred function list without upstream's removed `focus_dot`).
- Verified on the branch: cli npm ci, tsc clean. vitest, first run with TMPDIR=/tmp: 98 failed, 90 of them
  because an empty /tmp/.git (created 15:19 on 2026-10-07 by something else on gus) makes agentHandoff's
  `dotGitAbove` read every temp folder as "unknown"; rerun with TMPDIR=/dev/shm/ohs2-vtmp: 11,101 passed,
  5 failed, 108 skipped (last sync 10,843/8). The 5 are all from the known 8 (dsh shell and engineLaunch node
  PATH, tmuxStream.decode, processName hard link, master link name); localModels x2 and tmuxPaneInfo pass now.
  test:core 1,309 passed with its coverage gates; architecture.spec 6/6. Desktop: flutter analyze 0 errors
  0 warnings (16 infos, upstream's), nixfred and settings tests 115 passed, boot_flow 36 passed, linux release
  build. Firmware: idf.py build; full test/run.sh passes with the cc wrapper (unchanged, with -lm). Scratch
  daemon (HOME, XDG_RUNTIME_DIR, TMUX_TMPDIR under /tmp/claude-1000/ohs2, port 28474, CABLE_DISABLE,
  DISABLE_HOOK_INSTALL=true, updates off): status, orca, subs, attention, spend (enabled false), gate,
  capabilities, loops, collisions, hermes; a simulated Orca row (ORCA_TERMINAL_HANDLE set, no TMUX_PANE)
  through dist/notify.mjs SessionStart, UserPromptSubmit, permission Notification, Stop and SessionEnd went
  idle, working, permission, done and offline, carrying its Orca terminal.
- Go-live: nixfred/main 1ed0916d pushed; `install-cli.sh --no-updates --no-restart`, then `systemctl --user
  restart harness.service`. `harness status` says v0.3.64-dev.1ed0916da, backend connected; the journal shows
  the master, the core ready, search, viewers, edge, gateway, models and shell services connected (windowNames
  too), `[orca] watch mode ON · answers ON (file) · orca CLI found`, and the live Claude sessions rediscovered.
  `harness orca` lists 8 live sessions and `harness subs` reads Claude, Codex, Grok and Kimi. The desktop
  release bundle was rebuilt in this checkout (not launched).
- NOT flashed: the dial is not on USB (no /dev/ttyACM*, no Espressif device on the bus; the journal last saw it
  on 2026-10-05 16:28). The devices process is on demand since the 404-commit sync, so it did not start
  either, and the dial frames through it are unverified. fw .10 is built in this checkout; flash it with the
  rule above once the dial is plugged in. It is still on .8.
- Not verified: anything on the glass; the dial end to end through the devices process; Orca answers and
  prompts into a real Orca terminal; clip_push and dispatch between two machines; the gate verdict through a
  real PreToolUse hook.

## Upstream sync: 404 commits from autonomous-ai/openharness main (b9bbc76f), 2026-10-06

Merges upstream/main b9bbc76fc into nixfred/main 6ce9b08a (branch nixfred/sync-upstream-2026-10-06). Firmware
`0.0.86-nixfred.9`, ESP-IDF v5.5.0, 3,218,208 B against an 8 MB slot (61% free); the growth is upstream's Inter
faces and pet art.

- Upstream re-architected the daemon (harnessd): a master (`harness start -f`) runs the core and services in
  processes of their own (search; viewers and the Store; the edge host with workspaces, usage, monitor, projects,
  handoff and recaps; the gateway with the relay and its E2EE; models; and on demand the devices: the dials,
  window bridges, fleet and Wi-Fi device). The updater left the core for a process the master runs, the old web
  dashboard is gone, the orchestrator, Tab collaboration, Share and the command bar are experiments started on
  demand. runForeground moved from cli.ts to core/main.ts and into core modules, held to line and import budgets
  by architecture.spec.ts. Also: Harness OS on Apple Silicon (Asahi) and T2 Macs, hn 0.1.14, coding memory
  isolated from the core, many end-to-end hardening rounds, Codex 0.160 support.
- HOW THE FORK WAS PORTED (not resurrected): the fork's daemon side lives in cli/src/nixfred/coreWiring.ts, built
  by one call from runForeground, and reaches the core modules only through optional dependencies the fork added:
  core/input.ts `externalPrompt` (voice and typed prompts into Orca) and `brake` (spend cap, then loop policy);
  core/questions.ts `route` (Orca dialogs read and answered through the ExternalTerminalRouter) and `attention`;
  core/transcripts/attach.ts (a hosted row attaches without a terminal; Hermes `resolveDbPath` for a late profile
  home). The funnel, announceTurnAborted, the tool-start and turn-stop hooks, cancel and onAgentSeen are wrapped
  in main.ts for attention and the gate. The dial's `nixfred.*` frames go through a new `DevicesPort.nixfred`
  member (core/api.ts, devicesLink, devicesProcess, services/devices.ts), so they reach the dial in the devices'
  own process. cable/cableHost.ts reads external rows and the reveal target from `wiring.sessions()` instead of
  the registry module (an empty copy in the devices' process). `clip_push` left backendSocket's switch for a
  served request (nixfred/clipPush.ts, `serviceHost.serve('nixfredClip', ...)`). withPermissionFlag moved to
  nixfred/permissionFlag.ts so the core does not import the cable host. architecture.spec.ts gets two labelled
  fork allowances (core closure +5,400 lines, runForeground +20) instead of edits to upstream's budgets.
  FOLLOW-UP: move subscriptions, audit and checkpoints into a nixfred service in the edge host.
- Conflicts: notify.mjs (watch-mode branch before upstream's routeToPaneOwner; gate verdict output kept, memory
  output gone with upstream's memory routes), hookServer.ts (nixfred routes kept, upstream's dashboard and memory
  routes removed), backendSocket.ts and cli.ts (upstream's; the CLI-side `harness <nixfred command>` survives in
  cli.ts), registry.ts (imports), tmuxAgentDiscovery.ts (adopted panes kept, unless another daemon tagged them),
  applicationFrames.ts (clip_push beside agent_handoff_prepare and SHELL_REQUESTS), specs (both sides),
  desktop_workspace.dart (FleetOverviewHost around upstream's CommunityForkHost), firmware terminal.c/.h (the
  nixfred ring renamed `nring` beside upstream's new `ring`), ui_habitat.c (nixfred boot face drawn in Inter on
  Focus, hub agents_open plus upstream's pane reset, the shade owns the release before the carousels),
  test_touch_ui.py. Firmware also: upstream dropped the Geist faces (mapped to Inter), Focus allows one font
  (three nixfred labels draw in Inter on Focus; the machines back arrow is the word "back"), upstream's unread dot
  sits over the notch at 12 o'clock.
- Fixes found on the way: desktop Subscriptions used Dio, whose timers outlived a test now that upstream's
  flutter_test_config allows loopback; it uses dart:io HttpClient and closes on dispose. machineCapabilities.ts
  called `require` in ESM: `harness capabilities` and `harness loops` failed with "require is not defined"
  whenever HOSTNAME was not exported.
- Verified: cli npm ci, tsc clean; vitest 10,843 passed, 8 failed, 101 skipped (last sync 9,054/4). The 4 known
  (dsh shell and engineLaunch node PATH, tmuxPaneInfo, tmuxStream.decode) plus 4 new that fail identically on
  pristine upstream/main here (localModels x2, master link name, processName hard link). test:core 1,242 passed at
  100% per-file coverage; architecture.spec 7/7. Desktop: flutter analyze 0 errors 0 warnings (16 infos in
  third_party/xterm), nixfred/settings tests 117 passed, boot_flow 36 passed, release build. Firmware: idf.py
  build; full test/run.sh passes with the cc wrapper, which now also needs `-lm` (upstream's focus.c calls sinf
  and its run.sh links test_character without -lm): `exec /usr/bin/cc "$@" -D_DEFAULT_SOURCE
  -Wno-format-truncation -Wno-misleading-indentation -Wno-restrict -Wno-clobbered -Wno-sign-compare -lm`.
  Scratch daemon (HOME, XDG_RUNTIME_DIR, TMUX_TMPDIR in /tmp, port 28473, CABLE_DISABLE, DISABLE_HOOK_INSTALL,
  updates off) under the new master with every service process: `harness status`, `orca`, `subs`, `attention`,
  `spend` (off by default), `gate`, `capabilities`, `loops`, `collisions`, `hermes`; a simulated notify.mjs
  SessionStart, UserPromptSubmit, permission Notification, Stop and SessionEnd moved one external row through
  working, permission, done and offline.
- Not verified: anything on the glass (fw .9 not flashed); the dial frames end to end through the devices'
  process; Orca answers and prompts into a real Orca terminal; clip_push and dispatch between two machines;
  the gate verdict through a real Claude Code PreToolUse hook; the release bundle (`install-cli.sh`).

## Upstream sync: 40 commits from autonomous-ai/openharness main (30d2381b), 2026-10-02

Merges upstream/main 30d2381b4 into nixfred/main c60b38ba. Firmware `0.0.86-nixfred.8`, ESP-IDF v5.5.0,
2,800,096 B against an 8 MB slot (66% free); the growth is upstream's pet scenes and arc geometry.

- Upstream merged PR #608, a port of this fork's attention feed, destructive-action gate, spend brake,
  capabilities, dispatcher, Omarchy palette, desktop attention and Harness Pulse, then reverted it in
  #610 pending review. Net zero upstream; the fork's own files (cli/src/lib/attention.ts, actionPolicy.ts,
  spendBrake.ts, desktop attention_glow.dart, nixfred/plugins) are byte-identical after the merge.
- Upstream brought: Focus pet scenes on the dial (Clawd cooks while working, wears headphones while
  listening, launches a rocket on send; the Codex robot with sandboxes, mic bars and a paper plane;
  "Listening" swept along the lower arc, curved labels in Geist Medium 26); a tamper-evident Devices key
  history with dismiss and rebaseline; agent purge and worktree delete with a confirmed cleanup dialog;
  footer inventory counts and per-account allowance; paste pictures and files into a New Harness; Cmd-N
  focus and launch fixes; restart pane loss fix; one Cancel/Stop dialog for tab sessions; companion runtime
  kept for background learning and a stalled-learning explanation; web and mobile seal agent_resume,
  agent_fork and the Devices DSH frames; web store banner and phone footer; hn 0.1.11 TUI fixes; CI and
  release speedups. Dial gestures are unchanged, so the README dial section stands.
- Conflicts, both sides kept: hookServer.spec.ts (watch-mode specs plus device history/dismiss/rebaseline
  specs); applicationFrames.ts (agent_purge and agent_worktree_delete beside clip_push); app_shell.dart
  (upstream appFrame inside the nixfred BootSplash); desktop_workspace.dart (FleetOverviewHost plus
  appFrame); firmware terminal.c/.h (ht_ring and ht_mask beside upstream's proportional arc labels and
  cell sprites; the alpha mask draws only when a sprite has neither pixels nor cells); test_touch_ui
  (adds habitat_next_wake_ms) and test_voice_ui (voice_engine in the mirrored state).
- Verified: cli npm ci, tsc clean; vitest 9054 passed, 4 failed, 58 skipped (last sync 8842 passed, 4
  failed); the same four known failures (dsh shell and engineLaunch node PATH, tmuxPaneInfo,
  tmuxStream.decode retention). Desktop: flutter analyze no errors or warnings, nixfred/attention_glow/
  settings tests 116 passed, release build. boot_flow_widget_test "offline unlinked remote" fails, and
  fails identically on pristine upstream/main (upstream's own). Firmware: idf.py build; full test/run.sh
  passes with the cc wrapper, which now also needs -Wno-sign-compare (upstream's new pet asserts in
  test_touch_ui fail the same way on pristine upstream under host GCC).
- Not verified: the pet scenes and arc labels by eye on the glass; Devices key history end to end.

## Upstream sync: 164 commits from autonomous-ai/openharness main (c43b0186), 2026-10-02

Merges upstream/main c43b01863 into nixfred/main 6c92df3e. Firmware `0.0.86-nixfred.7`, ESP-IDF v5.5.0,
2,141,552 B against an 8 MB slot (74% free); the growth is upstream's Geist faces and engine pets.

- Upstream brought: coding memory across Claude, Codex and OpenCode (prompt recall hooks, feedback,
  notebooks), Harness Monitor and a live resource footer, session close and save across workspaces, local
  model switching ("Use"), Google and Apple sign-in, hn 0.1.9/0.1.10, a Devices DSH, a CPU spin fix for a
  stale attach entry, steadier machine connections across restarts, and on the dial a new Focus face:
  agent name on the top arc (tap: pane list), a tap anywhere on the face talks (no microphone button, no
  tab pill), a recap card in Geist Medium 30, the bell at the bottom, animated engine pets.
- Conflicts and how they were resolved (both sides kept everywhere):
  - cli/src/cli.ts: upstream's DialVerdicts import next to the nixfred withPermissionFlag and orcaWatch
    imports; the hook server gets the nixfred onExternalHook plus upstream's new onPromptContext (persona
    plus memory recall), onMemoryContext, onMemoryContextEmitted and onOpenCodeMemoryRuntime.
  - cli/src/hookServer.ts: the nixfred /api/hook/external route and upstream's three memory routes.
  - cli/src/lib/e2ee/applicationFrames.ts: upstream's agents_cleanup_preview and agent_close plus nixfred
    clip_push in the sealed machine requests.
  - cli/src/lib/registry.ts: upstream moved the row snapshot ahead of the lock to skip unchanged saves; the
    nixfred filter that keeps hosted rows (Hermes, watch-mode external) out of the file moved with it, and
    the hosted-row reindex after a save stays.
  - desktop terminal_panel.dart: upstream's showIdentityMark gate, with the nixfred SpendRing around the mark.
  - firmware terminal.c: ht_ring and ht_mask kept, arc_text takes upstream's face argument.
  - firmware ui_habitat.c: the done motion and upstream's pet frame clock both run; Focus's A_PET target is
    upstream's whole face, the fleet rim summary sits at y 350 on every skin (the mic it sat above is gone),
    the notch stays. The nixfred machines screen used upstream's removed focus_title and the old
    focus_centred: a local nf_title and the new `room` argument (348) fix it.
  - DELIBERATE CHOICE: upstream opens the tab list on a hold of the Focus face; the nixfred slice 6 hold
    opens the hub instead (the tab list is a hub wedge), and a press under 650 ms now talks, as upstream
    intends. test_touch_ui updated to say so; the name tap moved to y 30.
  - test/run.sh: the nixfred host tests link focus_marks.c, focus_faces.c and pets.c.
- Verified: cli npm ci, tsc clean; vitest 8842 passed, 4 failed, 56 skipped (pre-merge baseline 7624
  passed, 4 failed, 37 skipped). Failures after: dsh shell and engineLaunch DSH PATH specs (fail before
  too: node lives in /usr/bin here), tmuxPaneInfo (flaky, fails in the baseline checkout on rerun),
  tmuxStream.decode buffer retention (new upstream spec, file identical to upstream; 65599 > 64000 on
  Node 26). nixfredWiring and e2ee manager failures seen once in the baseline pass on rerun. Desktop:
  flutter analyze no errors or warnings, nixfred/attention_glow/settings tests 116 passed, release build.
  Firmware: idf.py build, full test/run.sh with the slice 2 cc wrapper passes.
- Not verified: the new Focus face and the hold-to-hub by a finger on the glass; coding memory end to end.

## Device firmware: smart navigation, a shade that never talks, 2026-10-01 (branch nixfred/firmware-smartnav)

Sits on nixfred/main 98da920e. Firmware `0.0.86-nixfred.6`, ESP-IDF v5.5.0, 1,737,115 B against an 8 MB slot
(79% free), DIRAM 45.33% used (+0.12 points; the new state lives in the PSRAM struct).

- Fred: "It is very hard to get to the menu sometimes and starts talking when I'm trying to go to the
  menu." And: "When I click on a machine it seems to go to my workload list."
- ROOT CAUSE of "starts talking": slice 4 exempted the home face's footer controls from the hold so a slow
  press still acted on release, for up to 1800 ms. The microphone's target is the bottom-centre band of the
  glass (x 143..323, y 353 to the bottom edge), exactly where a thumb rests on a round device. A hold there
  showed no ring and opened no hub; on release (anything under 1.8 s) it started voice, and the next tap
  ("finish voice") sent the clip. Evidence: the daemon journal on fw .5 logged twelve voice uploads of 0.1
  to 1.2 s between 22:03 and 22:06, two of which reached an agent as turns ("Sorry. Yep.", "Hello?").
  The old test even pinned it ("the microphone footer still starts speech on a slow press").
- ROOT CAUSE of "goes to my workload list": a tile pressed slowly ran into the hold, which on fw .4 opened
  the session list (on .5 the hub). Machine selection itself never changes view (the ack only moves the
  check mark); nothing on the host does either.
- Fred's video on fw .5 (2026-10-01 night): holding for the hub repeatedly started voice ("that's trying
  to talk") and only sometimes opened the hub, depending on where the finger sat. That matches the cause
  below: inside the mic band the hold was never armed. README "This fork" now lists the dial gestures.
- Gestures before: tap; hold 650 ms still (ring from 200 ms) opens the hub except on the footers, voice,
  draft, form, selection, answer review, transfer; footer slow press up to 1800 ms acts on release (the
  mic STARTS VOICE); creature middle tap starts voice (Focus: nothing); vertical swipes scroll or page,
  pull down on Focus opens the inbox; horizontal swipes switch agents on the face, go home from lists,
  step back in questions; BOOT tap aborts voice or stops the turn or goes home, BOOT hold 800 ms toggles the
  screen; PWR tap toggles the screen. The CST9217 driver reads one point (no multi-touch).
- Gestures after:
  - THE SHADE: pull down from the top rim (a contact starting in the top 60 px, 14 px of mostly vertical
    travel engages it, 96 px opens). Opens the hub from the faces, the lists, plans, machines, settings and
    a question or permission (never answering it). Not armed where something is being composed or spoken.
    It owns the contact once engaged: nothing scrolls, pages or presses under it, and an early release
    opens nothing. The notch follows the finger and an arc spreads from 12 o'clock; full pull lights a glow.
  - THE NOTCH: a small pill at 12 o'clock on Focus's home and agent faces, the shade's affordance.
  - THE HOLD is armed on the footers now, the microphone included: a press under 650 ms still presses, at
    650 ms the hub opens and the contact is consumed, so a hold NEVER starts voice. Not armed on the
    workspace slider (its own press-and-slide) or on a machine tile.
  - BACK: a swipe in from the left rim (start x < 44, 90 px across) steps back along an 8-deep history of
    views; on a list a plain swipe right is back too (left is still home). The hub is never a step of its
    own: a wedge's screen goes back to where the hub was opened.
  - Machine tile: a tap or a slow press (under 1.8 s, under 24 px of drift) selects it and stays on
    machines; the acknowledgement shows "gus selected" with this machine's load. Never the session list.
  - BOOT and PWR unchanged, except BOOT also stops the answer chain.
- SUGGESTED NEXT: the hub's centre is one action from live state, in priority order: a permission waiting
  (red, "Answer <agent>" with the question), a question waiting (yellow), a finished agent with an unread
  recap (green, opens its face), an unread inbox, then with nothing urgent the plan with the most banked
  share ("Use Kimi", "+36% banked"). Otherwise "close". One tap does it; it only opens, it never answers.
- WEDGE ORDER: urgent wedges (sessions with someone waiting, an unread inbox) move to the front in their
  base order; otherwise the positions never move. Re-ranking by recency each use would move wedges under
  the hand, so the wedge used last carries a small dot instead (remembered across hub openings).
- ANSWER CHAIN: when a question or permission answered on the dial gets its receipt, a toast says
  "next: <agent>" / "tap to stay" for 1.6 s, then that agent's question opens. A tap anywhere (or BOOT)
  stops it. With nobody left, the view steps back to where the question was opened from.
- NOTIFICATION CARD: a tap opens that agent's face (its recap), not the inbox list; the inbox when the agent
  is not on this dial.
- Host: `nixfred.fleet` gains `perm`, the ids of agents whose open question is a permission (attention
  state `permission`, at most 8), so the ranking knows a permission the dial has not loaded yet. Stock
  firmware drops the frame as before.
- Renderer: `nixfred_notch` (1 run), `nixfred_shade` (3 runs, constant through the pull), `nixfred_toast`
  (3 runs) in nixfred_art.c; the hub keeps its 39 runs plus one for the last-wedge dot, the centre's core
  ring grew to r 94 so the suggestion's lines stay inside it. Hub hits unchanged (7 of 24). The machine tile
  prints "63%" (it printed a cut "load ..").
- Verified: full test/run.sh passes on gus with the slice 2 cc wrapper, with and without IDF_PATH. New
  test_nixfred_smartnav.c (notch, shade and toast keep their runs, partial redraw equals full, inside the
  glass, glow only at full pull). test_touch_ui gains smartnav_checks (Tim and Tux): the shade opens the hub
  from eight screens at three x positions and from a question and a permission, never voice and never an
  answer; a mid-pull opens nothing; no shade in voice; every priority of the suggestion and its tap; the
  permission outranks a question; urgent-first order and the remembered wedge; the chain, its stop and its
  return; back from a wedge's screen and through two screens; the card to the recap; the machine tap and a
  slow press stay on machines with the confirmation. longpress_checks now holds across the whole mic band
  (none starts voice, all open the hub) and the slow mic and roll cases run inside 650 ms.
  test_machine_ui: the ack confirms on machines and never moves the view. test_question_ui and
  test_voice_ui mirror the new hooks. CLI: nixfredWiring and cable specs pass (416), tsc clean.
  nixfred/firmware-graphics-6-host-render.png is a HOST render through the touch harness (notch, shade at
  half pull, the hub in each suggestion case, the "next" toast, the machine confirmation), not a photo of
  the glass. Flashed over USB with the slice 1-5 method (same four images and offsets, NVS untouched); the
  daemon logged `dial 80:45:6B:35:06:CC on fw 0.0.86-nixfred.6 proto 3`, no offer.
- Not verified: any of it by a real finger on the glass (the shade's 60 px start band and 96 px pull, the
  left-rim back, the hold on the mic band), the toast and the chain over a live question, the suggestion
  against live `nixfred.fleet` perm frames on the device.

## Device firmware: the hub, hold anywhere for every screen, 2026-10-01 (branch nixfred/firmware-hub)

Sits on nixfred/main 8a428937. Firmware `0.0.86-nixfred.5`, ESP-IDF v5.5.0, 1,730,480 B against an 8 MB
slot (79% free), DIRAM 45.21% used (unchanged from slice 3).

- Fred: "We need a slick way to get to the menu with all the info like the banked subscription." The
  plans face was only reachable by the bottom-corner arcs, which the stock compose control covered.
- The slice 4 hold (650 ms still finger, the same rim ring filling from 200 ms, the same exceptions)
  now opens THE HUB instead of the session list. Five wedges clockwise from 12 o'clock, each a rim arc,
  a glyph, a label and one live line:
  - SESSIONS: "9 agents", or "2/9 need you" glowing red (a permission) or yellow (a question). Opens the
    session list (Focus AGENTS view, what the hold opened before).
  - PLANS: the next plan and its banked share ("KIMI +8%"), its weekly use as a gauge. Opens NF_PLANS.
  - MACHINES: "load 63%", load and VRAM (battery without a GPU) as two arcs. Opens machines.
  - SWARMS: "4 tabs", a ring of rings. Opens the tab list with the swarm overlay.
  - INBOX: "3 unread" glowing (yellow when a question waits), or "all read" drawn dim and inert. Opens it.
  - The centre: the clock (from `nixfred.fleet`, "--:--" until one arrives), the "! 1/9" fleet summary
    and "close".
- STOP ALL is NOT on the hub. The dial has no request that stops every agent: `nixfred.panic` runs host to
  dial only (after `harness stop-all`), and A_STOP_YES stops one agent's turn. So no wedge was drawn
  rather than one that does something else. Adding it needs a new dial-to-host frame and a daemon handler.
- Closing: a tap on the centre, a tap on the glass between the wedges, or a swipe either way returns to
  the view the hold began on (the home face when that cannot be re-entered: a message, a transfer, a
  question answered meanwhile). Holding inside the hub arms nothing.
- Opening: a 380 ms bloom. The rim arcs light in turn as a sweep passes from 12 o'clock, then each wedge
  fades in (plus slice 3's view sweep). 30 ms frames during it; afterwards one frame a second for the
  clock, a damage diff of the clock text.
- Never answers: every wedge only changes the view. A hold over a question or permission opens the hub
  and the question stays open and unanswered; the centre returns to it.
- Removed: the two bottom-corner A_NF_PLANS tap targets on the home face. The plan arcs stay there as
  display only. The tap on the agent's name still opens the session list directly.
- Changed: a hold on the session list (AGENTS) now opens the hub too (it was not armed there, as the hold
  used to lead there).
- Renderer: `nixfred_hub` in nixfred_art.c on the habitat compositor, ht_ring/ht_box/ht_text runs only,
  no allocation. 39 runs whatever the readouts, the bloom step or the pressed wedge (budget 56, with
  room for the view sweep and the hold ring), so every frame is a damage diff. Seven hits (of 24).
- Verified: full test/run.sh passes on gus with the slice 2 cc wrapper, with and without IDF_PATH.
  New test_nixfred_hub.c: constant runs across the bloom, partial redraw equals full, readouts drawn,
  glow red only when someone waits, tap targets inside the glass. test_touch_ui gains hub_checks (Tim
  and Tux): the hold opens the hub and consumes the contact; each wedge opens its screen; centre, the
  glass between and swipes close it back to where it began; an empty inbox wedge swallows its tap;
  ten hold-and-tap paths over a question and a permission never send; the home corners no longer open
  plans. longpress_checks now expects the hub (and arms AGENTS and NF_PLANS).
  nixfred/firmware-graphics-5-host-render.png is a HOST render (bloom at 36%, settled from the production
  ui_habitat.c through the touch harness, urgent, nothing known yet), not a photo of the glass.
  Flashed over USB with the slice 1-4 method (same four images and offsets, NVS untouched); the daemon
  logged `dial 80:45:6B:35:06:CC on fw 0.0.86-nixfred.5 proto 3`, no offer.
- Not verified: the hold and the wedge taps by a real finger on the glass, the bloom by eye on the
  device, the live readouts against a real `nixfred.fleet` and `nixfred.subs` on the glass, the hub over
  a live question or permission on the device.

## Device firmware: hold anywhere for the session list, 2026-10-01 (branch nixfred/firmware-longpress)

Sits on nixfred/main 1ad301b6. Firmware `0.0.86-nixfred.4`, ESP-IDF v5.5.0, 1,726,640 B against an 8 MB
slot (79% free).

- The session list is Focus's pane list (the AGENTS view), the list a tap on the agent's name opens.
  A still finger held 650 ms now opens it from any screen, while the finger is still down; the rest of
  that contact is consumed (lifting or sliding selects nothing). Movement past 12 px cancels the hold.
- Feedback: from 200 ms a ring fills clockwise from 12 o'clock on the rim (dim track all the way round,
  thick accent fill, `nixfred_hold_rim`, two runs, 20 steps at 30 ms frames). A tap (350 ms at most)
  shows at most a sliver. Released early, the ring clears and nothing happens. The firmware has no
  reduced-motion setting, so there is nothing to honour; the fill is progress, not decoration.
- Where an existing long press lives, it wins (the hold is not armed there): the voice screen (hold =
  stop into a draft review), a draft (hold on Edit = options), the form, the selection reader, the
  answer review, the firmware transfer face, the boot/connecting face, and the home and agent faces'
  footer controls (microphone, bell, tab pill, return, drop, workspace slider), whose slow press still
  acts on release. The agent's name is armed: its press opens this same list. A creature skin keeps
  its hold-for-tabs on the middle of the face (the device build only draws Focus).
- Changed: on Focus, holding the middle of the home or agent face opened the workspace (tab) list;
  it now opens the session list. The tab list is still one tap on the tab pill. A hold on a question,
  permission, inbox, tab list, settings, machines, stop, models, message or plans screen did nothing
  and now opens the session list. A hold never answers a question or permission: nothing under the
  finger is dispatched, and the question stays open.
- Not touched: the BOOT key (tap interrupts, hold 800 ms toggles the screen) and the PWR key.
- Verified: full test/run.sh passes on gus with the slice 2 cc wrapper, with and without IDF_PATH.
  test_touch_ui gains longpress_checks (Focus home, agent, inbox, tabs, settings, machines; title hold;
  drag and early release; tab pill and microphone slow presses; voice hold; creature skin; ten
  question and permission contacts that never send; the wake schedule) and runs under Tim and Tux.
  New test_nixfred_hold.c: constant runs per step, partial redraw equals full, fill only as far as the
  hold, inside the glass. test_voice_ui mirrors the new `nf_hold_step` field.
  nixfred/firmware-graphics-4-host-render.png is a HOST render (25%, 60%, 95%, and over a permission
  prompt), not a photo of the glass. Flashed over USB; the daemon logged `fw 0.0.86-nixfred.4`, no offer.
- Not verified: the hold by a real finger on the glass, the ring by eye on the device, the hold on a
  live question or permission prompt on the device.

## Device firmware graphics, third slice, 2026-09-30 (branch nixfred/firmware-graphics-3)

Sits on nixfred/main 5e1a0b1e. Firmware `0.0.86-nixfred.3`, ESP-IDF v5.5.0, 1,727,120 B against an 8 MB
slot (79% free), DIRAM 45.21% used (+0.4 points). The outline masks (about 110 KB) live in PSRAM.

- Ambient face: after 45 s untouched on the home face, with nobody waiting, no permission, no failure
  and no unread notice, the dial rests. One particle per agent (up to 12) orbits a hub on three orbits
  with a comet tail in its state colour; the orbit runs half a lap a minute at rest plus three quarters
  per working agent (at most four). The time of day sits in the hub with "3/6 working" under it, plus a
  scan band and two grain rings at 6 to 8 percent, never over the words. The whole face walks a 4 x 4 px
  square 1 px a minute (burn-in). 8 fps, 4 fps once dimmed. Any touch wakes the normal face.
- Dimming: after two quiet minutes the panel steps down to a third of its brightness (never under 8%),
  on the way to the existing five-minute sleep. A touch restores it (display_habitat.c).
- Connecting: a dotted ring inside the boot scanner lights one of 24 dots per connection attempt, with
  "retry N" under the wordmark. Resets when the link comes up.
- Pairing: device and machine pairing codes sit in a hexagon whose six edges pulse in turn from 12
  o'clock until the daemon answers (the screen then leaves; there is no separate "snap solid" frame).
- Machines (Focus): hexagon tiles, up to four a page, edge colour by state (green this computer, accent
  ready, yellow needs-link, dim offline), a glow on the selected one, and for this computer a load arc
  (amber from 80%, red from 95%) plus a thin VRAM arc (battery when there is no GPU) with the numbers.
  Other machines draw no arcs: their capabilities do not reach this daemon.
- Swarm: on the tabs screen, once the carousel rests on the selected tab, its name sits inside a parent
  ring in the most urgent child's colour (glowing when someone waits) with its agents orbiting, each in
  its own state; working children are open rings whose gap turns.
- Notification card: another agent's finished turn slides up from the rim (green left edge, name, one
  line of recap), holds 4.5 s and slides back. A swipe up dismisses it with a fading trail; a tap opens
  the inbox. The active agent keeps slice 2's done motion instead.
- Collision card: a new collision alert opens a card on the home face: both agents' rings side by side in
  their states, a breathing red warning triangle, the detail under them, "<" back.
- Lane tag: the active agent's policy lane letter (P, C, D, ...) in a small ring under the status line.
- Transitions: every view change, and the ambient face coming or going, sweeps an arc around the rim in
  320 ms (two runs that stay as invisible runs at rest, so its end is a damage diff, not a full repaint).
- Plans face (new view NF_PLANS): tap either bottom corner of the home rim (where slice 2's plan arcs sit)
  to open it. One big gauge arc per plan, used fill in its tone, the next plan glowing, a legend
  ("CLAUDE 62% +8", banked signed) and "NEXT: KIMI". A tap anywhere goes back.
- Host: `nixfred.fleet` (dialFleet in nixfredWiring.ts): local clock, one lane letter per agent, the
  newest collision inside its hour, and this machine's load/battery/VRAM in permille. Sent on every
  attention change, on a collision, and once a minute with the plans. `nixfred.subs` rows gain `name`
  and `banked`. Stock firmware drops both as unknown frames.
- Verified: firmware builds; full test/run.sh passes on gus with the same local cc wrapper as slice 2
  (test_touch_ui, test_voice_ui, test_display_power harnesses extended); new test_nixfred_slice3.c
  (every animation step keeps its run count and a partial redraw equals a full one; nothing outside the
  glass; drift moves the face by exactly the drift). tsc clean; nixfredWiring and cable specs pass (414).
  nixfred/firmware-graphics-3-host-render.png is a HOST render of the firmware's drawing calls with
  generic names, not a photo of the glass.
- Not verified: the glass by eye, a live collision, lane or fleet frame on the dial, the dim stage and
  ambient timing on the device, the swipe-up dismiss with a real finger.
- Known flake, not from this slice: "journals every watch-mode answer send" in nixfredWiring.spec.ts
  failed once in four combined runs (two fire-and-forget journal appends, no attention change).

## Device firmware graphics, second slice, 2026-09-30 (branch nixfred/firmware-graphics-2)

Sits on nixfred/main 609968b2. Firmware `0.0.86-nixfred.2`, ESP-IDF v5.5.0, 1,664,672 B against an 8 MB
slot (80% free), DIRAM 44.8% used.

- Home overview: one arc per agent on the rim (top three quarters of the glass), busiest centred at
  12 o'clock, then alternating right and left. Permission red (thick), failed thin red, waiting yellow
  breathing, working an accent segment sweeping across its own arc over a dim track, done green, idle
  dim, offline dotted. A summary line under the face ("! 1/9": most urgent state's glyph, how many,
  fleet size), hidden while a recap owns that band. State comes from what the dial already holds
  (busy, notices, open question plus its permission flag, machine state).
- Done: on a finished turn the ring closes from the rim to a solid green dot (600 ms), then the face
  and recap slide up into place (500 ms). No diff-stat bar: no lines-added/removed data reaches the dial.
- Failed: `turn.error` now opens a failure screen (two 120 ms red rim flashes, then a steady thin red
  ring) instead of a plain toast, and that agent's rim arc holds thin red until it works again. Voice
  errors and machine-select errors use the same screen. Pairing codes and notes stay plain.
- Voice: a rim level ring 3 to 19 px thick following the microphone level while recording; a lapping
  arc while sending (around Focus's sparkles, which stay).
- Panic stop: `harness stop-all` sends `nixfred.panic {stopped}`; the dial closes three rings onto one
  red dot with "ALL STOPPED" and the count. Back with "<".
- Plans: the daemon sends `nixfred.subs` (per plan: weekly use in permille, tone code) after each
  subscriptions pass; the dial draws one arc per plan (max four) in the bottom quarter of the home rim.
  Host side: `dialPlans` and `toDial` in nixfredWiring.ts, `CableSession.nixfred` (refuses any type
  outside `nixfred.`), CableFleet fan-out. Stock firmware counts the frames unknown and drops them.
- Renderer: HT_RUNS 40 to 56 (creature faces use up to 39 runs; each rim arc is its own damage sector).
  One animation clock (`nf_period`) schedules frames only while something moves (8 fps rim, 30 ms for
  done, flash and panic, 42 ms voice); quiet and nap freeze the rim.
- Public repo: nixfred/firmware-graphics-host-render.png re-rendered with the neutral figure (it showed
  "FN" initials). Slice 2 renders: nixfred/firmware-graphics-2-host-render.png. Both are HOST renders
  of the firmware's drawing calls (test_nixfred_ring.c, test_nixfred_screens.c with NIXFRED_SHOT_DIR),
  not photos of the glass.
- Verified: firmware builds; full test/run.sh passes on gus with a local cc wrapper adding
  -D_DEFAULT_SOURCE and -Wno-{format-truncation,misleading-indentation,restrict,clobbered} (host GCC
  strictness, pre-existing); test_touch_ui, test_question_ui, test_voice_ui, test_machine_ui harnesses
  updated for slices 1 and 2 (touch_ui and question_ui were already broken by slice 1). tsc clean;
  nixfredWiring, cableHost, cableSession, cableFleet, fwPush specs pass (241). Flashed over USB; daemon
  logged `fw 0.0.86-nixfred.2`, no offer. Not verified: the glass by eye, a live panic stop or plans
  frame on the dial.

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
  nixfred/firmware-graphics-host-render.png is a HOST render of the firmware's own drawing
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
