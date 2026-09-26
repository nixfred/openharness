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
| roster and banner face as Dart values | `lib/daemons/roster.dart` |
| renderer, status cell, nest, egg frames, banner, card | `lib/daemons/render.dart` (a port of `daemons/tools/render.mjs` and `card.mjs`) |
| line templates and their slots | `lib/daemons/daemon_lines.dart` |
| Motion, Quiet and the panel's last tab, kept per computer | `lib/daemons/daemon_settings.dart` (`daemons.settings.v1`) |
| zoo shape, rules, local draw | `lib/daemons/zoo.dart` |
| zoo state: account, guest, seed | `lib/daemons/zoo_controller.dart` |
| moods, blinks, work steps, tally, voice | `lib/daemons/daemon_face.dart` |
| the pair brain's frames, shown and armed, confirms, talk and `pair` requests | `lib/daemons/daemon_brain.dart` |
| lessons (list, show, skip, revert; taught only by the live line's key) | `lib/daemons/daemon_lessons.dart` |
| `pair.jsonc`: where it is, the file written when missing, what a rules confirmation turns on | `lib/daemons/pair_rules_file.dart` |
| the first-day consent screen | `lib/widgets/daemon_consent.dart` |
| first-egg habit signals | `lib/daemons/daemon_habits.dart` |
| colours, Flutter status slot, voice line and its keys, a line's detail disclosure, card text, notices, the brief notice | `lib/widgets/daemon_slot.dart` |
| hatch reveal, the consent after it, the level-up morph | `lib/widgets/daemon_hatch.dart` |
| panel and its tabs | `lib/widgets/daemon_panel.dart`, the pair brain's sections in `daemon_panel_pair.dart` |
| native status slot and voice line | `macos/Runner/SwarmTitlebar.swift` (`SwarmSymbolButton`, `SwarmVoiceLabel`) |

`test/daemons/render_frames_test.dart` checks every sprite, portrait, status
cell, card, nest and banner in `daemons/frames.json` byte for byte. Change the
roster, run `node daemons/tools/generate.mjs`, and that test tells you whether
the Dart port still draws what the reference draws.
`test/daemon_review_render_test.dart` draws the slot, the reveal and the panel
in real fonts and, with `HARNESS_DAEMON_CAPTURE_DIR` set, writes them as PNGs.

## The zoo

An account's zoo is read and changed exactly as the desk is: `GET /api/zoo`
and `POST /api/zoo/ops` through the local harnessd (its Unix socket, TCP as the
fallback), refreshed by the `zoo_changed` local frame only when its revision is
news. Writes are queued and retried; every op is idempotent. Habits, pair and
nickname show at once and are confirmed by the answer; eggs and draws are the
server's.

A guest keeps a local zoo (`daemons.zoo.v1.local` in the app's local store)
with the same shape and rules (economy v2, `backend/src/lib/zoo.ts`), drawn on
the client: regulars first and secrets only from eggs whose `weights.secret`
is above 0 (drop 1: night and easter), the pity counting only those eggs and
guaranteeing the secret at `secretGuaranteeAt`; only released drops draw; a
duplicate merges into the one you have (`+duplicateXp`, `dupes`, a shiny one
makes yours shiny, never pairs); a guest's daemons are `origin: local` and
carry no serial; easter words are kept as their sha256; a zoo stored with two
records of one daemon reads as one. The autonomy dial is zoo state too
(`zoo.autonomy`, `watch` when never set), and so is the first-day consent
(`zoo.consent { watching }`, kept as `consent { watching, at }`; null until
answered; a yes puts the dial at `watch`). The zoo is sent once with
`zoo.seed` the first time an account's zoo answers; the server keeps the
account's own dial and consent. A harnessd that predates
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
marathon, night and history eggs, held eggs when the nest is full (past 64,
`overflowXp` for the pair), and xp for the pair (levels 0–4 on
`rules.bond.levels`, 1.0 at level 2, 2.0 at level 4). A turn that finishes
after the window has been away or idle for `earn.night.awayMinutes` is an
away turn, which is what night eggs count (22:00 to 06:59, named by the day
the night began). The app does not measure a guest's turn minutes, so long
turns count once.

The paired daemon draws at its `version`. A new egg sits in the status slot for
3 s (an ack blink, no line), then the daemon returns and `+1 egg` stays beside
it until the egg is opened; the tooltip shows one egg look and a count
(`\_O_/ x2 waiting`). A level-up is a slow blink, no line. Before the first
hatch the slot shows the waiting egg itself: the first egg's ready face, or
its kind's `look` (the setup egg is `\_$_/`). The panel shows the bond, xp
toward the next level, and meters: counted turns toward the next turn egg,
today's count against the daily cap, and habits toward the setup egg until it
comes.

Nothing is drawn until the window knows whose zoo it is and the first read has
answered. A signed-in window waits for its profile (the old code keyed its
first reads by a temporary scope and flashed other progress at boot).

## First-egg habits

Each is reported once with `zoo.habit`. The first egg comes at
`firstEgg.need` habits with every `firstEgg.require` among them (today: a
finished turn and any two more), the setup egg at `setupEgg.need` (6). The
nest is render.mjs `nestStage` (ported, checked against `frames.nests`):
without the required habit at most need - 1 count. Every count, threshold
and the checklist's words (`finish a turn in a harness, and any 2 more`, the
required habit marked `needed`) come from the roster, never from the code.

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

The panel lists all eight with their shortcuts, the six this computer can do
first (`all of it can happen on this computer.`), then, under `with another
computer or device (never needed):`, `elsewhere` and `machine`, dimmed. No
copy implies a second computer is needed to hatch. Enter on one opens the
place to practise it.

## Status slot

Eight cells plus a one-cell gutter each side, far right of the status bar, in
the bar's font with ligatures off. The face sends its ten cells as drawn
(`statusCell` centred on the version's base sprite, so a borrowed baton or a
nap's `z` grows to the right and the face never shifts). A status cell is
always exactly ten cells (render.mjs fills and cuts to `statusCells + 2`): a
six-cell 1.0 sprite with a baton runs into the right gutter and ends there.

**Colour.** The slot is drawn in the status line's own text colour, whatever
the daemon: daemon colours fail contrast on a green tmux bar and on the yellow
message line. Daemon colours appear only on the terminal background (panel,
reveal, zoo, card): a dark theme takes the xterm colour (moved toward legible
below 3:1); a light theme takes the roster's `color.light` when it has one,
else the colour darkened until it reaches 4.5:1. The grue brings its own pitch
black wherever it is drawn: in the panel, the reveal, the zoo, the card, and on
a light theme as a black eight-cell patch behind its eyes in the slot.
Every terminal scheme the app ships today is dark, so the light rules wait for
a light scheme; `debugDaemonTerminalTheme` draws them now for the review
captures and `test/daemons/daemon_colors_test.dart` (Solarized Light).

**Shiny.** A `*` in the slot's left gutter; the roster's `shiny.hex` (every
daemon has one now; else the colour brighter and more saturated) on the
terminal background: panel, zoo, card and reveal; the card reads
`SHINY <RARITY>`.

**Tally.** Dim, left of the cells: `+3` turns finished since you looked,
cleared by a hover, opening the panel, or coming back to the window (after
4 s in front); `+1 egg` while eggs wait, until they are opened. With a pair
brain the `+n` is its `daemon_state.done.count` (every machine; the tooltip
names the last few) and a look sends `daemon_presence { doneSeen: true }`;
without one the window counts what it sees (a turn in the pane in front of you
is already seen). Native lays out again only when the tally's width changes.

Clicking a ready egg hatches it; nothing hatches on its own. Otherwise a click
boops the daemon and opens its panel. Hover is a look. Native updates carry the
face in `daemonState` (`glyph`, `cell`, `tally`, `foreground`, `tallyColor`,
`patch`, voice, `voiceArmed`) and repaint only the slot and the line; hover comes back as `daemonLook`.

While a hatch reveal runs, the slot keeps the egg and neither the Flutter bar
nor native hears the hatchling's name, colour or face until the reveal has
finished (the card is up) or been closed.

## Motion

While agents work, the work frame steps once per real agent event
(`AppNotifier.agentPulse`: a turn or tool starting or ending, output
arriving; not a heartbeat), at most twice a second: a burst is one step, and a
baton that stops means an agent that stopped. The portrait's parts step with
it. There is no free-running loop. The return wave (1.3 s) and blinks are the
only timed motion. Reduce Motion, a background window and the **Motion**
setting (the panel's `[ motion ]`, kept per computer) stop all of it; the face
still changes with the mood.

## Voice

Silent by default. **Only a harness waiting on you and a failure take over the
status line**, in the terminal's yellow for 5.2 s, as tmux's message line
does. A reply to something you did (a boop, the first words after a hatch, why
an answer failed) speaks at once, dim, in the status line's own ink. Finished
turns, new eggs, level-ups and returns are never a line: they are the tally, a
blink, the wave and the brief.

A line nobody asked for:

- at most one every two minutes; an answer you give lets the next through;
- never about the pane in front of you (dropped if you switch to it, and the
  brain hears the focused harness in `daemon_presence`);
- waits for Enter, a pane switch or 8 s without a key, never 2 s after the
  last one, and for any dialog, picker or the reveal; dropped after 20 s;
- none at all while the **Quiet** setting is on (the panel's `[ quiet ]`, kept
  until you turn it off); a nap still lasts 15 minutes and lets a need through.

**Templates.** Roster lines may hold slots (`rules.lineSlots`). The window
fills them when it speaks: `{who}` is `engine@machine` of the harness the line
is about, `{q}` its question (one line, at most 48 characters), `{n}` the count
that matters for the mood (working harnesses, waiting questions, idle ones,
failures, the tally), `{summary}` what this window saw while you were away
(`2 done, 1 waiting 40m`). `{recap}` is filled only when a recap is known; the
window does not have the daemon's turn recaps. A slot that cannot be filled
takes its clause with it (sentences, then `, ` `; ` `: ` ` - ` and runs of
spaces); what is left of a sentence that lost a slot must still hold a
filled slot, so a label (`E37:`) or voice v3's tag (`(bell)`, `woof`,
`[exit 1]`) is never a line on its own; a line with nothing left becomes a
neutral one (`a harness needs you.`). Never a literal `{who}`, never a
made-up fact. The panel's idle line
may show the roster's `examples`; every other line is filled from real values.

## The pair brain

When this computer's harnessd has a pair brain ([daemons/BRAIN.md](../../daemons/BRAIN.md),
frame shapes in `cli/src/pair/protocol.ts`) it sends local frames, heard only
from the loopback socket bound to this computer's own harnessd
(`AppNotifier.daemonFrames`: `daemon_*`, `pair_result`); `daemon_*` and
`pair` frames are sent only on that socket, never a relayed one.
`lib/daemons/daemon_brain.dart` holds what was heard.

- `daemon_state` (`pair`, `needs` with each dialog as `detail`, `working` as
  a count, `failing`, `machines` with their status, `done { count, last }`,
  `asks` with their harness and detail, `acted`, `autonomy`,
  `autonomyRequested`, `confirms`) is merged into the face's inputs: its
  needs (same ids as the window's own questions,
  `machineId/agentId#requestId`), work and failures across every machine;
  `asks` and `confirms` make the face `need` (it asks you something);
  `done.count` is the `+n`; the dial is the badge. `pair: null` keeps the
  roster's lines (a harnessd with no consent yet pairs nothing).
- **Shown, then armed** (BRAIN.md, "Security" 1). A key counts only on a
  line this connection was sent and acknowledged as drawn with `daemon_shown
  { id }` at least 400 ms before. The window sends it once per id, only
  after the line and everything a key on it would act on (its `detail`) are
  on screen, and arms the keys 450 ms later (the daemon's 400 ms and a
  margin for the frame's trip). Until then a key is drawn faint and does
  nothing, in Flutter and natively (`voiceArmed`), ⌘⌥ plus the key passes
  through, and `DaemonBrain.act`/`confirm` send nothing. `[g]` opens at any
  time (the window's own). A `NOT_SHOWN` or `TOO_SOON` answer (a new
  connection) acknowledges the line again and re-arms it. The status line
  acknowledges a keyed line after its first frame, or once its detail
  disclosure has drawn; the brief, each keyed item once drawn; the panel, a
  row only once it and its detail are wholly inside the panel's view. A
  line is new by its id, not its words.
- **Keys first.** A `daemon_say` is shown exactly as sent (`[y/n/g] api@office
  Bash: npm test`), for what is left of its `ttlMs` (5.2 s) since it arrived:
  its keys work only while the line shows, on the brain's clock. The offered
  keys in the leading bracket are the buttons, in Flutter and natively (the
  native label draws the line as sent and hit-tests those cells), and ⌘⌥
  plus the key answers from anywhere in the window, once armed. `[g]` opens
  the harness here (`revealAgentFromAlert`), which is the window's to do; y,
  n and s go out as `daemon_act`, a confirmation's y and n as
  `daemon_confirm`. A second `daemon_say` with the same id replaces the line
  in place with the time the brain says is left.
- **The detail.** A line with keys and a `detail` opens a disclosure under
  the status line (`DaemonDetailNotice`): `[-] api@office · exactly what a
  key does` (or `the lesson, in full`, `what a yes turns on`, `<tim> asks`),
  then the whole command, diff, prompt or lesson, never cut (it scrolls past
  fourteen rows), then the keys named (`y Yes · n No · g open`). `[-]` folds
  it; it goes with the line. Every approval surface shows the harness by
  name and machine and the exact command: the disclosure, each row in the
  panel, a brief's waiting item.
- **The pair speaking.** A `from: 'pair'` line is the pair harness's words,
  not the daemon's facts: drawn after IRC's `<tim>` nick (bold), dim, and a
  `say` from the pair never carries a key, whatever it sends. Its proposals
  (`ask`, `from: 'pair'`) keep their keys, their harness and their detail.
- **Moods.** `need` and `fail` take over the status line in the message
  yellow like the window's own alerts (at most one line nobody asked for every
  two minutes, never about the pane in front of you, never mid-thought).
  `ask` (a proposal, a lesson) is yellow, draws `need`, and shows at once, even
  mid-thought or behind a dialog: its keys are short-lived. `auto` (a rule or
  the pair acted) holds `done` with an ack blink and says it dimly, counted as
  a line nobody asked for; it is also in "what tim did". `say` (the pair
  answering you, or a setting that changed) is a dim reply and draws idle. `done` and `back` are never a
  line: the tally and the brief carry them.
- **What waits for you** (the now tab) keeps what the line could not: every
  confirmation in `daemon_state.confirms`, every proposal in
  `daemon_state.asks` (a proposal's keys work for its ten minutes; one
  proposal, one key, no batches), and every need, with its keys, harness and
  dialog while its line shows and `[g]` after (the brain drops a need's keys
  with its line: a late `y` must never land on the next dialog). A focused
  row answers y, n, s or g from the keyboard once armed.
- **Confirmations** (`pair/gate.ts`). A raise of the dial above `suggest`, or
  a pair.jsonc with rules, the model or a learning opt-in on, waits for the
  person's yes at a window: a `daemon_say` with `confirm { kind, nonce }` and
  a row in `daemon_state.confirms`. The panel shows it under the level it
  raises (settings) and in what waits for you (now): its line, a list of what
  a pair.jsonc turns on (each rule, the model, `learn.borrow`,
  `learn.export`, `learn.agentsMd`, read from the file in its detail), then
  the detail in full. y is `daemon_confirm { requestId, kind, nonce, accept:
  true }`, n keeps it as it is; `daemon_confirm_result` errors are worded
  (`STALE_CONFIRM`: no longer waiting).
- **Talk.** The panel's talk box, and the keymap's **Talk to daemon**
  (`app.daemon_talk`, ⌘⌥T: ⌘⌥Space is macOS's Finder search, and ⌘⌥ plus
  y, n, s or g answers lines), send `daemon_talk { requestId, text }`. The
  panel says the pair harness is waking, starting (a new conversation),
  resuming or reached, or why not (`daemon_talk_result`), keeps the last few
  turns (its answers as `<tim> ...`), and says what a talk costs (the
  result's `cost`). A `retryAfterMs` (six a minute, sixty an hour) disables
  the box and counts down (`again in 30s`). **Open the conversation**
  focuses the `autonomous/pair` harness's pane (the agent the talk reached,
  else the one this machine lists).
- **Autonomy.** The settings tab's dial: watch (the default), suggest, act on
  key ("your key approves one waiting answer at a time; it may drive
  harnesses it started"), act within rules, one line each, posted as
  `zoo.autonomy { level }` (a guest's is kept locally and sent as
  `daemon_presence.autonomy`). `(*)` marks the level the daemon acts at
  (`daemon_state.autonomy`), `(~) ... waits for your yes` a raise it asks
  about (`autonomyRequested`). The floor is stated in full: nothing deleted,
  restarted, forked or bypassed; no push, force, rm -rf, sudo, deploy,
  publish, drop or merge approved; a key a one-time yes, only on a read,
  test, build or in-project edit. `[ rules: ~/.config/harness/pair.jsonc ]`
  writes a commented file meaning "nothing on" (model, learn and rules off)
  when there is none and opens it the way `keybindings.jsonc` is opened.
  Above `suggest` a badge (`[act on key]`) shows beside the name in the panel
  and in the slot's tooltip (`autonomy: act on key`); a raise waiting for a
  yes is in the tooltip too. Until the person consents the dial is disabled:
  the daemon holds `watch`.
- **Consent** (`zoo.consent`). Nothing is watched until the person says yes:
  after the first hatch (any hatch while nobody has answered) the reveal's
  `[ next ]` shows what the daemon sees (README, "What your daemon sees": what
  it reads, never your keystrokes, terminals or files; what it writes,
  nothing to your projects until you allow it, lessons only with your yes;
  where it runs; at watch it only tells you), with `[ Let tim watch ]`
  (`watching: true`, the dial at `watch`) and `[ Not now ]` (`watching:
  false`). Only after a yes, as its own step: "Let tim suggest answers?"
  (`zoo.autonomy suggest`) or keep it at watch. Unanswered, the now tab shows
  the screen; after a no, one line and `[ review what tim sees ]`; settings
  says what was answered and when, with `[ stop watching ]`. A guest says it
  in `daemon_presence.consent`.
- **The brief** (`daemon_brief`, at most five items) shows under the status
  line on return, each item as sent, keys first; it stays up while its keys
  work (a minute) when an item has any, else 10 s, and is in the panel until
  the next one. A keyed item shows its dialog (`detail`) in full under it,
  and a `lesson` item (a lesson's `[s]`) the lesson's text; its keys arm
  once drawn.
- **Lessons** ([daemons/LEARNING.md](../../daemons/LEARNING.md), "Security"):
  a proposal is a `daemon_say` `ask` with `[y/n/s]`, its id
  `lesson:<id>:<nonce>` and the lesson's whole text as its `detail`. Teaching
  is the person's alone: only a key on that live line, sent with its id
  whole (the nonce), once the line and its whole text were drawn and armed.
  The lessons tab shows the proposed lesson in full with its keys; every
  other pending lesson has show and skip and says how to teach it (its `[y]`
  when it is proposed, or `harness pair lessons approve <id>` at a terminal);
  the window never approves through the `pair` request (it would be
  `NONCE_REQUIRED`). `daemon_act_result`'s `learned` or `skipped` is said and
  the list read again; `PERSON_ONLY` and `INSIDE_HARNESS` are worded.
  Approved lessons revert (`lessons revert`, not person-only).
- **What tim did** (the now tab): `daemon_state.acted` (a rule, the pair or
  another machine, what and when), then the lessons it taught with their
  date and `[ revert ]`. An answer typed into a harness cannot be taken back,
  and it says so.
- **Presence** (`daemon_presence`): `active` and `awayMs` when the window
  loses or regains the front, and when it goes idle in front (no key or
  pointer for five minutes: `active: false` with how long; the next input is
  `active: true` with the whole absence), so harnessd knows away turns and
  briefs a return; a focus-only frame whenever the pane in front changes,
  `focusAgentId: null` when there is none (the brain never speaks about what
  you are looking at); `doneSeen` on a look; a guest adds its local zoo's
  `pair`, `autonomy` and `consent` (whether the person said yes).
- Machines `asleep`, `unreachable`, `unlinked`, `old` or `off`, and open
  harnesses on a machine this window cannot reach, are said calmly in the
  panel (`studio is asleep. its harnesses wait.`) and never make the face
  `fail`; only a failed start or a harness whose last turn failed does.

## The reveal

The egg wobbles until harnessd answers, then tells the rarity at the crack: a
rare's shell glows cyan, a legendary's pop throws yellow `*'.` sparks, and a
secret's stage goes black before the crack (light ink on it, on any theme).
A duplicate (`hatched[].duplicate`) has no reveal of a new name: after the pop
it shows yours, `vim x2 · +150 xp`, `another vim. +150 xp.` (and `yours is
shiny now.` for a shiny one), then, if it grew, `vim grew: bond 2 · 1.0` at
its new version; no new card. A new daemon's card carries the server's serial
(`#0042`); a guest's has none. The
0.1 **portrait** appears as `#` in the faint colour for 1200 ms, fills with its
colour and blinks; the name types in, in the shared face from
`daemons/banner.json` (`renderBanner`) at a line height of 1.15 so its rows
never touch; then the rarity stamp, `fork() returned 0.`, and the card. From
the person's fourth hatch on, any key skips to the card; Escape closes at any
point; Reduce Motion goes straight to the card.

While nobody has answered the first-day consent, the card (or a duplicate's
merge) ends in `[ next ]`, which shows the consent screen, then the suggest
step (see "The pair brain", Consent); Escape leaves it unanswered, and the
now tab asks again. A duplicate that levels its daemon up shows the grew line,
then the portrait turns from the old version into the new in three frames
(160 ms each; of the cells that differ, a quarter more each frame in
ordered-dither order, on one canvas so nothing jumps), then holds the new
version with the changelog line (`tim 1.0: split-window -h: a second pane;
learned your agents by name`: tim's log is the lookbook's; a daemon without
one says the bond and xp it reached). Reduce Motion goes straight to the held
frame.

## The panel

Before the first hatch: the nest and its habits (above). After, four tabs
like tmux's window list, `1:now*  2:zoo  3:lessons  4:settings`, the one
showing starred and highlighted; 1–4 or a click switch, the last one is kept
per computer (`daemons.settings.v1` `tab`), Escape closes, arrows and j/k
move (the row scrolls into view), Enter acts. The title is the paired
daemon's name, with the autonomy badge above `suggest`.

- **now**: the face and its line (yellow only when something needs you or
  failed), a calm line for each machine not there, waiting eggs, the consent
  screen until it is answered, then with a pair brain: what waits for you,
  the brief, what tim did, and the talk (its cost note under the box).
- **zoo**: the viewed daemon's live portrait (or `[ card ]`, with `[ copy ]`
  as a fenced code block), identity (`#01/09 tim 2.0 · common · paired`),
  bond, family, lore, `[ pair ]` and `[ rename ]`; the box back: `#01`..`#09`
  and `#S`, each owned daemon as its sprite at its version in its colour with
  `x2` for duplicates, each empty slot `[ ? ]` (a secret `[ ! ]`); the meters
  toward the next earned egg; the waiting eggs, one look per kind with a
  count.
- **lessons**: the proposed lesson in full with its keys, then pending and
  learned lessons.
- **settings**: `[ quiet ]`, `[ motion ]`, `[ nap ]`, the dial with pending
  confirmations, the floor, the rules file and its confirmation, consent.

The talk box takes focus only from Talk to daemon (which opens the now tab);
typing 1–4 or j there is words.

## The finder

The roster ships only `rules.easterHashes` (sha256 of each lowercased word).
Typing `xyzzy`, the one classic the window knows by heart, in Cmd-O answers
with a result row, `Nothing happens.`, that Return never takes; any query whose
hash is an easter hash is sent as `zoo.easter { word }` once from this
window.

## Performance

`SwarmScreen` reads only Reduce Motion from `MediaQuery`, so a resize no longer
rebuilds the workspace. Session rows are built once per tick and shared by the
toolbar, the badge, the native payload and the daemon. There is no idle timer
and no animation loop: work frames step on agent events, and timers only end a
held face, run a blink or the return wave, end a nap, hold a line until you
pause, and clear a spoken line. Agent events reach the face through their own
notifier, so an event never rebuilds the workspace.
