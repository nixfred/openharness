# nixfred additions to OpenHarness

Everything in this directory runs beside the Harness daemon on an Omarchy machine and needs no
change to the upstream app to be useful. Each item names the PLAN.md phase it satisfies.

| Piece | What it is | Phase |
|---|---|---|
| `plugins/pi.harness-pulse/` | Omarchy bar widget: one animated ring per agent, fed by the daemon's `/api/attention` | 1.1 |
| `hooks/harness-breadcrumb.hook.ts` | Claude Code Stop hook: a searchable note per finished turn under `~/.claude/MEMORY/BREADCRUMBS` | 1.2 |
| `bin/harness-second-opinion` | Send the current diff to codex, grok or kimi for an independent review | 1.3 |
| `bin/harness-changelog-x` | After a merge: CHANGE.log line plus an X post draft in `~/.claude/X-QUEUE` (never posts) | 1.4 |
| `hooks/harness-blip-question.hook.ts`, `bin/harness-blip-answer` | Agent question to Fred's iMessage via Blip; answer typed back into the pane | 1.5 |
| `harness/omarchy-quickshell/` | Domain harness: build Omarchy bar plugins with qmllint and Test Drive screenshots in the viewer | 1.6 |
| `../desktop/lib/theme/omarchy_theme.dart` | Omarchy theme palette as a Flutter ColorScheme (untested here, no Flutter SDK) | 1.7 |
| `harness/larry-memory/` | Harness whose agent reads Larry's memory, read-only, and cites files | 5.1 (first step) |

## Install

Bar widget:

```
cp -r nixfred/plugins/pi.harness-pulse ~/.config/omarchy/plugins/
omarchy restart shell          # never omarchy refresh
```

Hooks: see `hooks/README.md` for the settings.json blocks. Tools: `ln -s "$PWD"/nixfred/bin/* ~/bin/`.

Harnesses:

```
harness dsh check nixfred/harness/omarchy-quickshell
harness dsh install nixfred/harness/omarchy-quickshell --link
harness dsh install nixfred/harness/larry-memory --link
```

The bar widget needs the fork's daemon (`/api/attention`, Phase 2.2). Against a stock daemon it shows
a filled hexagon and "Harness daemon not running" until the fork is installed.

## Rules baked in

python3 for plugin helpers, never bun. No `omarchy refresh`. Test in Test Drive, not the live desktop.
Blip only in Fred's own thread. Law 17: nothing scrolls, rings resize in place. No em dashes.

## harness/pai-skills

A third domain harness: any engine gets the PAI skills library under ~/.claude/skills, read-only, with the 9 Laws as working rules. Install like the others: `harness dsh install ./nixfred/harness/pai-skills --link`.

## The `harness` commands the fork adds

All of them talk to the running daemon over its loopback API (`POST /api/nixfred`), so they work wherever `harness status` works. Add `--json` for raw output.

| Command | What it does |
|---|---|
| `harness attention [--kanban]` | Every agent's state (working, waiting, permission, failed, done, idle, offline) with glyph and label; `--kanban` groups into needs-you / failed / done-unreviewed / working / idle |
| `harness adopt %N [engine]`, `unadopt`, `adopted` | Register a tmux pane the daemon did not create, so a running agent shows up without a restart |
| `harness gate init|install|uninstall|status|reload` | The destructive-action gate: policy file `~/.harness/cli/data/action-policy.json` (rules plus per-agent lanes), opt-in Claude PreToolUse hook |
| `harness spend status|set --agent-usd=N --day-usd=N|off|on` | Per-agent and per-day dollar/token caps; a paused agent's next turn is held and the web told why |
| `harness capabilities`, `harness placement [--gpu] [--min-vram=MB] [--interactive]` | GPU, load, power, thermal, lid, toolchains; whether this machine should take a job |
| `harness loops` | Loop policy, live leases, capability line (`/loop` submits defer on battery, lid, busy GPU, quiet hours) |
| `harness stop-all [--except=<agentId>]` | Panic stop: cancel every agent turn on this machine |
| `harness collisions`, `harness lock <repo> [branch]`, `unlock`, `locks`, `branches` | The drift alarm: two agents on one file, folder or branch inside an hour; branch locks per agent |
| `harness ci` | One pass of the CI-failure watcher (`gh pr checks` per agent branch); runs every 5 min on its own |
| `harness hermes [doctor-done]` | Hermes health per profile: state.db writers, memory budget, isolation, doctor-after-update stamp |
| `harness dispatch --machine=<id> --repo=<path> [--engine=claude] [--branch=x] "brief"`, `dispatches` | Hand a bounded job to a linked machine; the result comes back off the worker's `DISPATCH_RESULT:` line |
| `harness clip push --machine=<id> [--file=<path>] [text]` | Clipboard or file drop to a linked machine, sealed end to end; files land in `~/Downloads/harness-drop` |
| `harness checkpoint <agent> --brief=...`, `checkpoints`, `restore <dir> [cwd]` | Portable task checkpoints (brief, decisions, patch, tests) |
| `harness bundle <agent>` | Review bundle: redacted transcript excerpt, patch, diff stat, audit tail, sha256 manifest, tarball |
| `harness record start|stop <agent>`, `pin <agent> <label>`, `pins`, `asciicast` | tmux pane recording with pinned moments, exported as asciicast v2 |
| `harness audit [n]` | Tail of the append-only, secret-redacted journal (`data/audit.jsonl`) |

Environment switches: `HARNESS_HERMES_SESSIONS=0` (no paneless Hermes rows), `HARNESS_BRANCH_WATCH=0`, `HARNESS_CI_WATCH=0`, `HARNESS_CI_WATCH_MS`, `HARNESS_DROP_DIR`, `OTEL_EXPORTER_OTLP_ENDPOINT` (spans), `HARNESS_WINDOW_CLASS` (what the notification's Show action focuses).
