# Watch mode: Harness for agents running in Orca

Stock Harness tracks only the terminals it created. A Claude Code or Codex session you start
anywhere else shows up only as an "external conversation", and the app's **Move Here** quits the
original terminal to bring it over.

Watch mode is for people who keep their agents where they are, for example in
[Orca](https://github.com/stablyai/orca) by stablyai, the desktop app for running many coding
agents side by side. With watch mode on, every live Claude or Codex session on this computer is a
row in the Harness app and on the Harness device, the same as an agent Harness started. It carries
the same states: working, waiting on you, needs permission, done and failed. The row is marked
external. Harness never moves it, restarts it or kills it.

When the session runs in an Orca terminal, you can also answer its questions and permission prompts
from the device or the app. The answer is typed into that Orca terminal with Orca's own CLI.

Watch mode is **off by default**.

## Commands

```bash
harness orca              # status: the switch, whether the orca CLI was found, every external row
harness orca on           # watch external sessions and deliver answers into Orca
harness orca answers off  # keep watching, but never type anything into an Orca terminal
harness orca answers on
harness orca off          # stop watching; every external row goes offline
harness orca answer <agent-id> <number|label>   # answer an open question from this terminal
```

The switch lives in `orca-watch.json` in the daemon's data directory. The environment overrides it:

| Variable | Effect |
| --- | --- |
| `HARNESS_ORCA_WATCH=0` / `=1` | force watch mode off or on, whatever the file says |
| `HARNESS_ORCA_ANSWERS=0` / `=1` | force answer delivery off or on (only while watching) |
| `HARNESS_ORCA_IDLE_CAPTURE_MS` | how often a working external session's screen may be read with no dialog announced (default 8000, `0` = never) |
| `HARNESS_ORCA_BIN` | path to the `orca` binary, if it is not on `PATH` or in `~/bin` |

## How it works

1. **Hooks.** `harness start` already installs `notify.mjs` for Claude's SessionStart,
   UserPromptSubmit, Stop, StopFailure and SessionEnd, and this fork adds Notification. In stock
   Harness the script exits at once when there is no tmux pane. In watch mode it posts the event to
   `/api/hook/external` instead, with the same per-machine hook credential as every other hook.
   With watch mode off, nothing is posted.
2. **Orca ids.** Inside an Orca terminal the script adds `ORCA_TERMINAL_HANDLE`, and the worktree,
   tab and pane ids when they are set. It sends nothing else from the environment. In particular,
   Orca's own `ORCA_AGENT_HOOK_TOKEN` never leaves the hook.
3. **Rows.** The daemon validates the event and registers a memory-only external row, which is never
   written to `registry.json`. The row gets the session's transcript only when the file lies under
   the engine's own home, the rule every other row follows. The transcript is tailed like any other
   agent's, so turns and recaps reach the app and the device live. The row is not saved as a stopped
   agent, so the app cannot later "resume" it into a Harness pane. That would be a move.
4. **Attention.** UserPromptSubmit means working. A Notification of type `permission_prompt` means
   needs permission, and `elicitation_dialog` means waiting on you. Stop means done, StopFailure means
   failed, and SessionEnd means offline. A session that just goes away (terminal closed) goes offline
   when its engine process is gone. The check uses the process start time, so a reused pid cannot
   keep a dead row alive. Rows carry `external: true` in the attention feed, and the agent frame has
   an `external` block with the Orca terminal and worktree.
5. **Questions.** The stock question watcher reads the terminal screen to find a dialog. For an Orca
   row it reads with `orca terminal read --screen`. One read costs about a second, measured on a
   laptop. So the screen is read fresh only while a Notification has said a dialog is open, and
   otherwise at most once every 8 seconds. The watcher runs only while a device or a Harness window
   can answer.
6. **Answers.** An answer from the device, the app or `harness orca answer` goes through the stock
   answer controller. That controller re-reads the screen and refuses an answer to a dialog that has
   changed. For an Orca row, each key is sent with `orca terminal send`, as argv and never through a
   shell. Rows with a tmux pane keep the stock tmux path, unchanged. Ctrl-C and Ctrl-D are refused
   for external rows. The Orca path is wired only to the answer controller, so nothing else
   (a new prompt, a stop, a restart) can type into an Orca terminal.
7. **Audit.** Every send is written to the audit journal (`harness audit`) as `kind: "answer"`,
   whether or not it was delivered. The line records the key or text, the Orca terminal and
   allow or deny.

## Limits

- **Codex:** rows and states come from its hooks and rollout. Codex has no Notification hook, so its
  dialogs are found only by the throttled screen read.
- **Outside Orca** (a plain terminal window), a session is watch-only. There is no terminal Harness
  can type into, and an answer is refused and logged.
- The desktop app shows an external row as an agent whose terminal is not available. It does not
  yet draw an "external" badge, although the `external` field is on the frame.

## Credits

Orca is made by [stablyai](https://github.com/stablyai/orca). Watch mode drives only Orca's public
CLI (`orca terminal read`, `orca terminal send`), and nothing in Orca is modified.
