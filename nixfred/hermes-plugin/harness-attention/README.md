# harness-attention: a Hermes plugin skeleton for the Harness daemon

Lets a Hermes bot answer "who needs me?" from the OpenHarness daemon's local endpoint
`GET http://127.0.0.1:18473/api/attention`, and (on Hermes Desktop) watches that endpoint and raises a
notification when an agent starts waiting, needs permission, fails, or when two agents collide.

Written for Mike Gannotti's fleet to finish. Two halves, because Hermes has two plugin systems:

Sources read for the formats (2026-09-27):

- Agent plugin format (Python, `~/.hermes/plugins/<name>/`): https://hermes-agent.nousresearch.com/docs/developer-guide/plugins
- Desktop Plugin SDK (JavaScript ESM, `$HERMES_HOME/desktop-plugins/<id>/plugin.js`): https://hermes-agent.nousresearch.com/docs/developer-guide/desktop-plugin-sdk
- A shipped example with a refresh loop (hermes-newswire): https://hermes-agent.nousresearch.com/docs/plugins/hermes-newswire
- Plugin catalog and enabling plugins: https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins

## Layout

```
harness-attention/
  README.md
  attention.py            shared client + formatter; also a standalone CLI (no Hermes needed)
  agent/                  copy to ~/.hermes/plugins/harness-attention/
    plugin.yaml
    __init__.py
    schemas.py
    tools.py
    skills/harness-attention/SKILL.md
  desktop/                copy to ~/.hermes/desktop-plugins/harness-attention/
    plugin.js
```

## What each half does

Agent plugin (Python). Registers one tool, `harness_attention`, that the model can call, and a slash
command `/attention` a person can type in any session. Both read the daemon and return the same
summary: `<host>: <count> <most urgent state>`, one line per agent with its glyph, then collision
alerts. Bundles a skill so the bot knows to call the tool when asked "who needs me", "what is
waiting", "which agent failed". No third-party dependencies (stdlib `urllib`), so nothing to install.

Desktop plugin (JavaScript). A status-bar item showing the fleet summary, refreshed every 5 seconds
with `ctx.setInterval`, and `host.notify` plus `ctx.os.notify` the moment an agent enters waiting,
permission or failed, or a new collision alert appears. Transitions are deduped so a stuck state does
not nag.

## Install

```
cp -r agent  ~/.hermes/plugins/harness-attention
cp -r desktop ~/.hermes/desktop-plugins/harness-attention
hermes plugins doctor ~/.hermes/plugins/harness-attention --ci
```

Then enable it in `~/.hermes/config.yaml` under `plugins.enabled` (per the plugins guide) and reload
Hermes Desktop. The daemon must be running (`harness start`) on the same machine.

## Verified here

- `python3 attention.py` against a fake local server on 127.0.0.1:18473 prints the summary, the agent
  lines and the alert line; exit 0. With no server: one line saying the daemon is unreachable, exit 3.
- `python3 -m py_compile` on every .py file; `node --check` on plugin.js.
- The manifest fields, `register(ctx)` / `ctx.register_tool` / `ctx.register_command` /
  `ctx.register_skill` calls and the `handler(args, **kwargs) -> str` signature are taken verbatim
  from the developer guide above.
- Desktop: `export default { id, name, register(ctx) }`, `ctx.register({ id, area, title, render })`,
  `STATUSBAR_AREAS.right`, `ctx.setInterval`, `host.notify`, `ctx.os.notify` are the names the SDK
  page documents.

## Assumed, not verified (no Hermes install on this machine)

- That the desktop renderer allows a plain `fetch()` to 127.0.0.1. If the app's content policy blocks
  it, the documented alternative is a Python backend (`dashboard/plugin_api.py`, mounted at
  `/api/plugins/<id>/`) that proxies to the daemon, then `ctx.rest('/attention')` from plugin.js. The
  newswire plugin uses that shape; its `manifest.json` fields were not quoted in the docs, so that
  half is left as a comment in plugin.js rather than guessed.
- The exact import name for the status-bar area constant (`STATUSBAR_AREAS`) is documented but the
  module it is exported from is assumed to be `@hermes/plugin-sdk`.
- Periodic work inside the agent plugin: the guide says there is no scheduler; the desktop half does
  the polling instead. A background thread in `__init__.py` would also work and is left out on purpose.
- Posting into a chat from the agent side is not a documented capability; the tool result and the
  slash command are the two documented paths, and both are used.
