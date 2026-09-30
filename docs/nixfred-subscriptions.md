# Subscriptions (nixfred fork)

One screen for every AI plan on this computer: how much of the week you have used, how much you have
banked against an even pace, when it resets, when you are back on pace if you are over, and which plan
to reach for next.

The pace math and the provider sources are ported from **Burn Bar**
([github.com/nixfred/burnbar](https://github.com/nixfred/burnbar), MIT), the Omarchy bar plugin that
answers the same questions. Burn Bar does not have to be installed: the fork never calls it and never
reads its files. Omarchy is not needed either, and the collectors work on Linux and macOS.

## Where it shows

| Surface | How |
|---|---|
| Desktop app | Settings, Subscriptions: one card per plan, with a switch to turn each plan off |
| CLI | `harness subs` (plain lines), `harness subs --json`, `harness subs --force` (skip the cache) |
| Toggle | `harness subs set <claude\|codex\|grok\|kimi> <on\|off>` |
| HTTP | `GET /api/subscriptions` on the daemon's loopback port; `POST /api/nixfred {"action":"subs"}` and `{"action":"subs-set","id":"grok","enabled":"off"}` |
| Frames | a local `subscriptions` frame every poll, and `subscriptions` (compact) on every `attention` payload, for the bar and the device |

## Providers

| Plan | Source | Network | Judged by |
|---|---|---|---|
| Claude | Claude Code's own OAuth login: `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`), on macOS the keychain item `Claude Code-credentials` (read with `security find-generic-password -w`). `GET https://api.anthropic.com/api/oauth/usage` | yes, at most every 4 min | Weekly (7-day) |
| Codex | The newest `rate_limits` snapshot Codex writes into `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (or `$CODEX_HOME`) | no | Weekly (7-day) |
| Grok | The newest `billing: fetched credits config` line in `~/.grok/logs/unified.jsonl` (or `$GROK_HOME`). A snapshot: Grok writes it when Grok starts | no | Weekly, using Grok's own period start and end |
| Kimi | `KIMI_API_KEY` from the environment, else a `KIMI_API_KEY=` line in `~/.env`; `GET {KIMI_BASE_URL or https://api.kimi.com/coding/v1}/usages` | yes, at most every 4 min | Monthly (total); the 5-hour request window is shown as a session window |

A plan whose files or key are absent is **not detected** and costs nothing: no request is made. One
that is installed but not signed in is **not signed in**, with the remedy. A failed request keeps the
last good figure and says so. Credentials are read locally and read-only; a token only ever goes into
its own provider's HTTPS `Authorization` header and is never returned, logged or passed on a command
line. A `KIMI_BASE_URL` that is not HTTPS (other than localhost) is refused.

The local GPU is not a subscription and is not on this screen.

## The math

Budget means an even spend across the window. With `p` the share of the plan used, `L` the window
length and `r` the time left:

- elapsed `e = (L - r) / L`
- **banked** `= e - p`. Positive: that share of the plan was unspent at an even pace (green). Negative:
  you are ahead of the clock, over pace (amber, or red past 1.25x or when spent). The card also shows
  banked as time (`banked x L`).
- over pace means more than 5% past an even spend and by at least one percent of the plan
- **come-back timer** `reset - L x (1 - p)`: stop now and the even-pace line catches up then. A spent
  plan comes back only at its reset.
- room `(1 - p) / (1 - e)`: the same scale for a week and a month
- **next plan**: only a plan that is ahead is suggested, most room first (which becomes "use it or lose
  it" as a reset nears with budget unspent). One plan alone is never suggested; a snapshot (Grok) must
  be 10% ahead; a plan whose 5-hour session is 90% full is skipped; the last pick sticks unless another
  is clearly (15%) better.
- burn rate from the plan's own samples over the last two hours, the burndown line, and the
  "stop for today" clock follow Burn Bar's `pace_for` exactly.

`cli/src/nixfred/subscriptions/pace.spec.ts` ports Burn Bar's `tests/test_pace_math.py` and
`tests/test_guidance.cjs` case for case.

## Settings and files

| What | Where |
|---|---|
| Which plans are on | `subscriptions.json` in the daemon's data dir (`~/.harness/cli/data` by default); all on by default. The app's switches and `harness subs set` write it |
| Samples (for the rate and the burndown) | `subscription-samples.jsonl`, same dir; percentages and reset times only, pruned after 40 days |
| `HARNESS_SUBS_WATCH=0` | no background polling (the screen and `harness subs` still read on demand) |
| `HARNESS_SUBS_MS` | background poll interval, default 60000 |
| `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`, `KIMI_API_KEY`, `KIMI_BASE_URL` | where each provider lives |
