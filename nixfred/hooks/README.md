# Harness hooks for Claude Code

Two bun scripts. Copy them to `~/.claude/hooks/` (or run them from this checkout) and register them in `~/.claude/settings.json`. Do not let a tool edit settings.json for you; add the blocks by hand and reload.

## harness-breadcrumb.hook.ts (Stop)

Writes `~/.claude/MEMORY/BREADCRUMBS/YYYY-MM-DD/HHMMSS-<repo>.md` with frontmatter (what, repo, machine, engine, cwd, session_id, tags) plus a daily INDEX.md. PLAN.md Phase 1.2.

```json
"Stop": [
  { "matcher": "", "hooks": [ { "type": "command", "command": "bun /home/pi/Projects/openharness.nixfred/nixfred/hooks/harness-breadcrumb.hook.ts" } ] }
]
```

## harness-blip-question.hook.ts (Notification, and PostToolUse on AskUserQuestion)

Sends the question to Fred's own iMessage thread via Blip (`imsg-send --self --yes`), prefixed `[harness <host>]`. Only fires when `~/.config/blip/bridge.conf` exists. PLAN.md Phase 1.5.

```json
"Notification": [
  { "matcher": "", "hooks": [ { "type": "command", "command": "bun /home/pi/Projects/openharness.nixfred/nixfred/hooks/harness-blip-question.hook.ts" } ] }
],
"PostToolUse": [
  { "matcher": "AskUserQuestion", "hooks": [ { "type": "command", "command": "bun /home/pi/Projects/openharness.nixfred/nixfred/hooks/harness-blip-question.hook.ts" } ] }
]
```

Answer from the phone side by hand for now:

```
nixfred/bin/harness-blip-answer %12 "yes, go ahead"
```

That runs `tmux send-keys -t %12 -l "<text>"` then Enter. A watcher that reads `imsg watch --json` and routes replies automatically is a later step; it needs the agent to pane mapping from the daemon's `/api/attention`.

Rules: Blip tests only in the self thread. Both hooks exit 0 no matter what.
