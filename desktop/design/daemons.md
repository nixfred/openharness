# Daemons on the desktop

The contract is [daemons/README.md](../../daemons/README.md): the roster, the
art rules, moods, blinks, voice, the zoo, habits and hatching. This page only
says where the desktop keeps each part and what it chose where the contract
leaves room. It replaces the local "terminal companion" (six species, canned
chat, a local blind box), which is gone.

## Where things live

| part | file |
|---|---|
| roster (generated, never edited) | `lib/daemons/roster.g.dart` |
| roster as Dart values | `lib/daemons/roster.dart` |
| renderer, nest, egg frames, banner, card | `lib/daemons/render.dart` (a port of `daemons/tools/render.mjs`) |
| zoo shape, rules, local draw | `lib/daemons/zoo.dart` |
| zoo state: account, guest, seed | `lib/daemons/zoo_controller.dart` |
| moods, blinks, frames, voice | `lib/daemons/daemon_face.dart` |
| first-egg habit signals | `lib/daemons/daemon_habits.dart` |
| Flutter status slot, voice line, notices | `lib/widgets/daemon_slot.dart` |
| hatch reveal | `lib/widgets/daemon_hatch.dart` |
| panel | `lib/widgets/daemon_panel.dart` |
| native status slot and voice line | `macos/Runner/SwarmTitlebar.swift` (`SwarmSymbolButton`, `SwarmVoiceLabel`) |

`test/daemons/render_frames_test.dart` checks every frame in
`daemons/frames.json` byte for byte. Change the roster, run
`node daemons/tools/generate.mjs`, and that test tells you whether the Dart
port still draws what the reference draws.

## The zoo

An account's zoo is read and changed exactly as the desk is: `GET /api/zoo`
and `POST /api/zoo/ops` through the local harnessd (its Unix socket, TCP as the
fallback), refreshed by the `zoo_changed` local frame only when its revision is
news. Writes are queued and retried; every op is idempotent. Habits, pair and
nickname show at once and are confirmed by the answer; eggs and draws are the
server's.

A guest keeps a local zoo (`daemons.zoo.v1.local` in the app's local store)
with the same shape and rules, drawn on the client. It is sent once with
`zoo.seed` the first time an account's zoo answers. A harnessd that predates
the zoo answers 404; the window then uses the local zoo too, and seeds it when
the account's zoo appears.

At sign-in the guest's zoo is queued first, ahead of any habit report, and
only when the account holds no daemon, egg or habit (the server refuses it
after that). Its answer is a baseline: the guest's eggs come back under server
ids and are not news.

Every zoo the window shows is compared with the one before it: a new egg id is
an arrival and a higher `bond` is a level-up, whether it came in this window's
own answer (`grants`, `levelUps`) or another window's change learned from
`zoo_changed`. A first read and a seed are baselines.

## Earning eggs and growing

Signed in, harnessd counts turns and reports them with `zoo.turn`; the desktop
never sends `zoo.turn` (the turns would count twice). A guest's turns are
counted by the app (a live `turn_started`, then a `turn_ended` without error or
interrupt, not a sub-agent, terminal or the pair harness) and applied to the
local zoo with the server's rules: 20 a local day, a turn egg every 40, week,
marathon, night and history eggs, held eggs when the nest is full, and xp for
the pair (levels 0–4 on `rules.bond.levels`, 1.0 at level 2, 2.0 at level 4).

The paired daemon draws at its `version`. A new egg sits in the status slot for
3 s with a line (`a week egg arrived. it waits in the nest.`), then the daemon
returns; its tooltip counts the eggs waiting and a click opens the panel on
the egg. A level-up is a slow blink and one line (`tim 1.0 released.`, or
`bond level 3.`). Before the first hatch the slot shows the waiting egg itself:
the first egg's ready face, or its kind's `look`. The panel shows the bond, xp
toward the next level, and how many counted turns until the next turn egg.

Nothing is drawn until the window knows whose zoo it is and the first read has
answered. A signed-in window waits for its profile (the old code keyed its
first reads by a temporary scope and flashed other progress at boot).

## First-egg habits

Each is reported once with `zoo.habit`.

| key | signal in this app |
|---|---|
| `turn` | a turn ends without error in a harness open in a pane here |
| `split` | a tab holds two or more different harnesses |
| `find` | something is opened from the Cmd-O finder |
| `elsewhere` | **not reported**: the app cannot tell which device started a harness; harnessd or the server has to |
| `machine` | another computer of the account is connected (signed in only) |
| `store` | a turn ends in a Store harness |
| `resume` | a paused harness is resumed from this window |
| `days` | the window is in front on three different local days (kept locally per account) |

The panel lists all eight with their shortcuts; Enter on one opens the place
to practise it.

## Status slot

Eight cells plus a one-cell gutter each side, far right of the status bar, in
the bar's font with ligatures off. The nest (`\_O_/`, `~\_O_/~`, `\_.._/`,
`\_o.o_/`) warms toward the terminal's yellow; a paired daemon draws in its
xterm colour, moved toward legible only where the background would swallow it.
The grue shows up only on a dark terminal.

Clicking a ready egg hatches it; nothing hatches on its own. Otherwise a click
boops the daemon and opens its panel. Hover is a look. Native updates carry the
face in `daemonState` and repaint only the slot; hover comes back as
`daemonLook`.

While a hatch reveal runs, the slot keeps the egg and neither the Flutter bar
nor native hears the hatchling's name, colour or face until the reveal has
finished (the card is up) or been closed.

## Voice

The daemon's one line replaces the status line's context for 5.2 s, in the
terminal's yellow, as tmux's message line does. It is held until 2 s after the
last key and while a dialog, picker or the reveal is open, and dropped if it
is still waiting after 10 s.

## The pair brain

When this computer's harnessd has a pair brain ([daemons/BRAIN.md](../../daemons/BRAIN.md))
it sends local frames, heard only from the loopback socket bound to this
computer's own harnessd (`AppNotifier.daemonFrames`); `daemon_*` frames are
sent only on that socket, never a relayed one (an older daemon forwards unknown
frames from a relayed socket to the cloud). `lib/daemons/daemon_brain.dart`
holds what was heard.

- `daemon_state` is merged into the face's inputs: its needs (same ids as the
  window's own questions, `machineId/agentId#requestId`), working and failing,
  across every machine. Without it the face works from this window alone.
- `daemon_say` replaces the roster line: with a brain, a need/done/fail/back
  line waits up to 2.5 s for it, and it is still held while you type or a
  dialog is open. Its actions draw after the line as `[y] run it`, clickable
  in the Flutter bar and natively, and ⌘⌥ plus the key answers from anywhere
  in the window. A line with answers stays up until answered, withdrawn
  (`daemon_unsay`) or its `ttlMs` (30 s by default).
- `daemon_act { requestId, id, choice }` goes out on a click or chord;
  a failed `daemon_act_result` becomes one line (`STALE_QUESTION`'s detail, or
  a worded code).
- `daemon_presence { active, awayMs, desk, pair? }` goes out when the brain is
  first heard and when the window loses or regains the front; `desk` is a
  random id kept per computer, and a guest adds its local zoo's pair.
- `daemon_brief` shows as a short list under the status line on return (10 s)
  and in the panel until the next one.

Not done: idle detection for presence (only blur and focus are reported).

## Performance

`SwarmScreen` reads only Reduce Motion from `MediaQuery`, so a resize no longer
rebuilds the workspace. Session rows are built once per tick and shared by the
toolbar, the badge, the native payload and the daemon. There is no idle timer:
timers only end a held face, run a blink, step work frames while agents work,
end a nap and clear a spoken line.
