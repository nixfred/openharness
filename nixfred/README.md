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
