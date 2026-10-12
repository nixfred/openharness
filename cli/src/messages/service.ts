/**
 * Agent Messages (docs/design/2026-10-10-agent-messages.md): harnesses in one tab message each other with `harness
 * send`, while the account has Agent Messages on (Settings ▸ Experimental, off by default). This is the whole service,
 * on the core's API, in the core's process or in its own (services/messages.ts, services/messagesProcess.ts):
 * - `send`: from `harness send` in an agent's pane, over this machine's socket. The pane names the sender.
 * - `deliver`, `status`, `who`: from the owner's other machines, over the paired relay.
 * - `history`: the windows' log of a tab.
 * - `started`: another machine's record of a harness it started here, for the agent client's limits and depth
 *   (agentClient/ledger.ts). It lets no one message anyone: only sharing a tab does.
 * Deliveries to this machine's agents are the mailbox's (mailbox.ts); a message for another machine's agent is
 * handed to that machine's daemon, which owns its delivery and is asked what became of it.
 *
 * Off costs nothing. It runs in the edge host on every computer, and only while this computer is signed in and has
 * Agent Messages on does it read the account's tabs (every 15 s), look at its deliveries (every 2 s) and at its notes,
 * its outbox and other machines' deliveries (every 5 s). Turned off, it withdraws the notes, holds what waits here out
 * of the hook's reach and fails it once it has waited HELD_OUTSIDE_MS, as while on, and then runs nothing until it is
 * turned on again: the core tells it when its copy of the account's switch changes (`settingsChanged`, from
 * core/experiments.ts `createAgentSettingsSync`), and a watch on the setting's file hears the same write
 * (settingWatch.ts); what this computer sent that waits for another machine is
 * handed over once it is on again. Signed out it runs nothing: there is no account to read tabs from, and signing in
 * starts a new core, which it reconnects to (`reconnected`). Its requests are answered either way, and read the switch
 * again as they come.
 */
import { createHash } from 'node:crypto'
import { hostname } from 'node:os'
import { basename, join } from 'node:path'
import type { CoreApi, ServiceRequests, TurnDelivery } from '../core/api.js'
import { env } from '../config/env.js'
import { agentSettingsPath, readAgentSettings } from '../lib/agentSettings.js'
import type { RegisteredSession } from '../lib/registry.js'
import { MessageDirectory, type Member } from './directory.js'
import { PaneInbox } from './inbox.js'
import { Mailbox, type MailboxAgent } from './mailbox.js'
import { type DeliveryStatus, LIMITS, LONG_TEXT, longAdvice, type Message, MessageError, messageId, note, parseMessage, type Recipient, rendered, type Teammate } from './model.js'
import { messagesRpc, type Rpc } from './rpc.js'
import { Ledger, ledgerPath, parseStarted } from '../agentClient/ledger.js'
import { watchSettingFile } from './settingWatch.js'
import { MessageStore, type LocalDelivery } from './store.js'

export interface MessagesOptions {
  /** Where its history and waiting deliveries are kept; an isolated fixture's own. */
  stateDir?: string
  /** The pane inboxes the messages hook reads (env.HARNESS_AGENT_MESSAGES_DIR); an isolated fixture's own. */
  inboxRoot?: string
  rpc?: Rpc
  /** The local socket's folder (`ADAPTER_DATA_DIR`) the other machines are reached through. */
  dataDir?: string
  /** Who started which harness (agentClient/ledger.ts), where another machine's `started` is kept; an isolated
   *  fixture's own. */
  ledgerFile?: string
  /** Something that decides whether a typed delivery may be written changed: the process tells the core. */
  changed?: () => void
  /** How it hears the setting's file change while Agent Messages are off (settingWatch.ts); a test's own. */
  watchSetting?: (path: string, changed: () => void) => () => void
  now?: () => number
}

export interface AgentMessages {
  requests: ServiceRequests
  /** Whether the core may write a typed delivery now: the mailbox's word, in line. */
  canWrite(deliveryId: string): boolean
  /** The service reached a core again, perhaps a new one: typed attempts in flight go back to the hook, and what
   *  runs follows whether this computer is signed in now. */
  reconnected?(): void
  /** The core's copy of the account's switch changed: it is read again, and it wakes if it is on now. */
  settingsChanged(): void
  start(): void
  stop(): void
}

/** How often the service looks at its notes, its outbox and other machines' deliveries. */
export const TICK_MS = 5_000
/** How often a message waiting on another machine is asked about. */
export const REMOTE_STATUS_MS = 15_000
/** How long another machine's names for its agents are kept. */
export const WHO_MS = 60_000
/** How old an inbox file nothing here waits on must be before a start sweeps it away. */
export const SWEEP_AFTER_MS = 10 * 60_000
/** How long a delivery no tab carries (Agent Messages turned off, or the tab left) is held, given to no one, before
 *  it fails. */
export const HELD_OUTSIDE_MS = 5 * 60_000
export const HELD_OFF_REASON = 'Agent Messages are off on its computer: it waits 5 minutes for them to be on again, then fails'
export const HELD_LEFT_REASON = 'it is not in a tab with the sender: it waits 5 minutes for that to change, then fails'
/** How long the Agent Messages setting, as this computer keeps it, is taken as read: the mailbox's pump asks
 *  every 2 s (mailbox.ts PUMP_MS), and a send or a hand-over asks too. */
export const SETTING_FRESH_MS = 2_000
/** What `harness send` says while this computer has Agent Messages off: where the person turns them on again. */
export const MESSAGES_OFF_TEXT = 'Agent Messages are off. The person turns on "Agents in the same tab can message each other" in Settings ▸ Experimental, or runs `harness settings agent-messages on`.'

const PANE = /^%\d{1,9}$/
/** The most messages `harness send` alone gives an agent at once, unread ones first. */
const UNREAD_MAX = 20
/** Whether `wanted` is the whole of a name the engine cut short: Codex titles its terminal with the folder cut to fit
 *  ("claude-code-2026-10-1..."), and an agent that wrote the folder out in full was told no teammate had that name
 *  (a fresh Mac, 2026-10-12). Both arguments in lower case. */
const cutShort = (name: string, wanted: string): boolean => {
  const stem = name.replace(/\s*(?:\.{3}|…)$/u, '')
  return stem !== name && stem.length >= 3 && wanted.startsWith(stem)
}
const key = (m: Member): string => `${m.machineId}/${m.agentId}`

export function startAgentMessages(core: CoreApi, options: MessagesOptions = {}): AgentMessages {
  const now = options.now ?? Date.now
  const rpc = options.rpc ?? messagesRpc
  const self = (): string => core.daemon.machineId()
  const at = (machineId: string) => ({ port: core.daemon.port, machineId, dataDir: options.dataDir ?? core.dataDir })
  const store = new MessageStore(options.stateDir ?? join(core.dataDir, 'agent-messages'))
  // Who started which harness is the agent client's (limits, depth, who may close what), never a way to message: a
  // harness started by another reaches it only through a tab they share, like any teammate (owner, 2026-10-11, on
  // finding agents messaging each other with no tab turned on).
  const lineage = new Ledger(options.ledgerFile ?? ledgerPath(core.dataDir))
  const inbox = new PaneInbox(options.inboxRoot ?? env.HARNESS_AGENT_MESSAGES_DIR)
  /** Other machines' names for their agents, with when they were asked. */
  const who = new Map<string, { name: string; engine: string; project?: string; at: number }>()
  /** When each other machine was last asked for names, answering or not. */
  const asked = new Map<string, number>()
  /** When each sender sent, for the rate limit. */
  const sent = new Map<string, number[]>()
  let timer: ReturnType<typeof setInterval> | null = null
  let lastRemoteStatus = -Infinity
  /**
   * What runs (`wake`): everything while this computer is signed in and has Agent Messages on (`awake`); while they are
   * off, only the mailbox's look until what waited has settled, and the watch on the setting's file; signed out,
   * nothing. Null before it starts and once it stops.
   */
  let mode: 'awake' | 'off' | 'signedOut' | null = null
  const asleep = (): boolean => mode === 'off' || mode === 'signedOut'
  let running = false
  let unwatch: (() => void) | null = null
  const settingsFile = agentSettingsPath(options.dataDir ?? core.dataDir)

  // The account's experiment, kept by the core in the data folder (lib/agentSettings.ts) as it changes: a small file,
  // read again at most every SETTING_FRESH_MS, so a switch turned off takes effect at the next look; while off,
  // nothing looks, and the core's word (`settingsChanged`) or the file's watch wakes it (settingWatch.ts).
  let setting = { on: true, at: -Infinity }
  const readSetting = (): boolean => {
    setting = { on: readAgentSettings(options.dataDir ?? core.dataDir).agentMessages, at: now() }
    return setting.on
  }
  const messagingOn = (): boolean => {
    if (now() - setting.at >= SETTING_FRESH_MS) {
      const was = setting.on
      // Turned on or off since the last look: what runs follows, once whatever asked has its answer.
      if (readSetting() !== was) later()
    }
    return setting.on
  }
  let waking = false
  const later = (): void => {
    if (waking) return
    waking = true
    queueMicrotask(() => { waking = false; wake() })
  }

  const directory = new MessageDirectory({
    on: messagingOn,
    read: async () => {
      const response = await core.account.backend('GET', '/api/agent-messages')
      if (response.status !== 200 || response.body.success !== true) throw new Error('directory unavailable')
      return response.body.data
    },
    changed: () => { mailbox.refuseAll(); notesPump(); options.changed?.() },
    now,
  })

  const live = (): RegisteredSession[] => core.agents.live().filter((s) => s.engine !== ('terminal' as string))
  const localAgent = (agentId: string): RegisteredSession | undefined => live().find((s) => s.agentId === agentId)
  const machineName = (machineId: string): string => directory.machineName(machineId) ?? (machineId === self() ? hostname().replace(/\.local$/, '') : machineId.slice(0, 8))

  const mailbox: Mailbox = new Mailbox({
    store, inbox, now,
    agent: (agentId): MailboxAgent | null => {
      const session = localAgent(agentId)
      if (!session) return null
      // The hook delivers only to this conversation: a Codex sub-agent runs its hooks from its parent's pane, and
      // a pane number tmux gives out again is another's. A Claude Code sub-agent says so itself (`agent_id`).
      return { pane: session.tmuxPane, session: session.sessionId ?? '', available: session.active && core.agents.terminalAvailable(agentId) }
    },
    deliver: (agentId, text, deliveryId) => { core.turns.deliver(agentId, text, deliveryId); options.changed?.() },
    refused: (delivery) => { const v = verdict(delivery); return v && 'refused' in v ? v.refused : null },
    held: (delivery) => { const v = verdict(delivery); return v && 'held' in v ? v.held : null },
    forbidden: (delivery) => forbidden(delivery),
    // Off, no tab carries a message, whatever the tabs say: known without reading them.
    ready: () => directory.current() !== null || !directory.on(),
    asleep,
    text: (delivery, message) => {
      const roster = rosterOf(delivery.agentId)
      return roster && store.state.noted[delivery.agentId] !== roster.signature ? `${roster.text}\n\n${rendered(message)}` : rendered(message)
    },
    changed: (status, delivery) => localChanged(status, delivery),
    writable: () => options.changed?.(),
  })

  /**
   * Why a local delivery may never be made, whatever the tabs say, or null. Before 2026-10-11 a harness and one it
   * started messaged each other with no tab on, logged under `started`; only a tab carries a message, so what an
   * older version left waiting there is never delivered, even to two that share a tab now. Asked before
   * the directory is read too: the hook takes what waits in a pane's inbox without asking, and a directory that
   * cannot be read (signed out, the backend down) would otherwise leave it there to be taken.
   */
  function forbidden(delivery: LocalDelivery): string | null {
    return store.entry(delivery.messageId)?.message.tabId === 'started' ? 'it was sent outside any tab' : null
  }

  /** When the tabs stopped carrying each local delivery (`messageId agentId`), while they do not. */
  const outsideSince = new Map<string, number>()

  /**
   * Whether a local delivery may be made: null; held, given to no one, while no tab carries it (Agent Messages are
   * off here, or the two no longer share a tab), for HELD_OUTSIDE_MS; refused after that, or at once when it may never
   * be made. Only what may never be made is refused before the directory is read. A tab's switch turned off by a slip
   * of the mouse and on again a minute later failed the message waiting in it (owner, 2026-10-12): held, it goes on
   * once it is carried again.
   */
  function verdict(delivery: LocalDelivery): { refused: string } | { held: string } | null {
    const entry = store.entry(delivery.messageId)
    if (!entry) return { refused: 'the message is no longer kept' }
    const never = forbidden(delivery)
    if (never) return { refused: never }
    if (!directory.current() && directory.on()) return null
    const key = `${delivery.messageId} ${delivery.agentId}`
    const recipient = { machineId: self(), agentId: delivery.agentId }
    // Only a tab the two share carries a message, and none while Agent Messages are off here.
    if (directory.shared(entry.message.from, recipient)) { outsideSince.delete(key); return null }
    const off = !directory.on()
    const since = outsideSince.get(key) ?? now()
    if (now() - since < HELD_OUTSIDE_MS) {
      outsideSince.set(key, since)
      return { held: off ? HELD_OFF_REASON : HELD_LEFT_REASON }
    }
    outsideSince.delete(key)
    return { refused: off ? 'Agent Messages were turned off on its computer' : 'it is no longer in a tab with the sender' }
  }

  function localChanged(status: DeliveryStatus, delivery: LocalDelivery): void {
    const full = { ...status, machineId: self() }
    if (status.state === 'delivered') {
      const roster = rosterOf(delivery.agentId)
      // The note rode with this message: the agent has it.
      if (roster) { store.state.noted[delivery.agentId] = roster.signature; withdrawNote(delivery.agentId) }
    }
    if (store.status(full)) tellWindows(full.messageId)
    options.changed?.()
  }

  function tellWindows(id: string): void {
    const entry = store.entry(id)
    if (!entry) return
    core.clients.windows({ type: 'messages_changed', payload: {
      tabId: entry.message.tabId, messageId: id, at: entry.message.at,
      from: { machineId: entry.message.from.machineId, agentId: entry.message.from.agentId },
      to: entry.message.to.map((r) => {
        const status = entry.statuses.find((s) => s.machineId === r.machineId && s.agentId === r.agentId)
        return { machineId: r.machineId, agentId: r.agentId, state: status?.state ?? 'queued' }
      }),
    } })
  }

  // ── names and the roster note ────────────────────────────────────────────────────────────────────

  /** A teammate as the note and the roster show them: from this machine's registry, or another machine's word. */
  function teammate(member: Member): Teammate & { member: Member; known: boolean } {
    if (member.machineId === self()) {
      const session = localAgent(member.agentId)
      return { member, known: !!session, name: session ? core.agents.displayName(session) || member.agentId.slice(0, 8) : member.agentId.slice(0, 8),
        engine: session?.engine ?? 'agent', machine: machineName(member.machineId), ...(session?.cwd ? { where: basename(session.cwd) } : {}) }
    }
    const known = who.get(key(member))
    return { member, known: !!known, name: known?.name || member.agentId.slice(0, 8), engine: known?.engine ?? 'agent', machine: machineName(member.machineId),
      ...(known?.project ? { where: known.project } : {}) }
  }

  /**
   * Teammates each with a name it can be told apart by, from `me`'s side. A name is a session's title, and two can
   * share one: two Codex agents in a tab both titled themselves after the task one gave the other, so the roster
   * named the teammate as the agent itself (a fresh Mac, 2026-10-12). A name shared with anyone here, the sender
   * included, gets the start of its id, which `harness send` takes on its own.
   */
  function distinct(me: Member, members: Member[]): Array<ReturnType<typeof teammate>> {
    const mates = members.map(teammate)
    const counts = new Map<string, number>()
    for (const name of [teammate(me).name, ...mates.map((m) => m.name)]) counts.set(name.toLowerCase(), (counts.get(name.toLowerCase()) ?? 0) + 1)
    return mates.map((m) => (counts.get(m.name.toLowerCase()) ?? 0) > 1 ? { ...m, name: `${m.name} (${m.member.agentId.slice(0, 8)})` } : m)
  }

  /** This harness's own name as its teammates see it: with the start of its id when one of them shares it. */
  function ownName(me: Member, members: Member[]): string {
    const name = teammate(me).name
    return members.some((m) => teammate(m).name.toLowerCase() === name.toLowerCase()) ? `${name} (${me.agentId.slice(0, 8)})` : name
  }

  /**
   * Ask other machines for their agents' names, those not known or too old; a machine asked lately, answering or
   * not, is not asked again yet. The notes are looked at again only when a name changed: looked at on every
   * answer, a teammate no machine can name (a stopped harness here) asked again at once, without end.
   */
  async function learnNames(members: Member[], wait: boolean): Promise<void> {
    const byMachine = new Map<string, string[]>()
    for (const m of members) {
      if (m.machineId === self()) continue
      const known = who.get(key(m))
      if (known && now() - known.at < WHO_MS) continue
      if (now() - (asked.get(m.machineId) ?? -Infinity) < WHO_MS && !wait) continue
      byMachine.set(m.machineId, [...(byMachine.get(m.machineId) ?? []), m.agentId])
    }
    if (!byMachine.size) return
    let learned = false
    const asks = [...byMachine].map(async ([machineId, agentIds]) => {
      asked.set(machineId, now())
      try {
        const answer = await rpc(at(machineId), { action: 'who', agentIds }, 8_000)
        for (const a of Array.isArray(answer.agents) ? answer.agents as Record<string, unknown>[] : []) {
          if (typeof a.agentId !== 'string' || typeof a.name !== 'string') continue
          const before = who.get(`${machineId}/${a.agentId}`)
          const next = { name: a.name, engine: typeof a.engine === 'string' ? a.engine : 'agent',
            ...(typeof a.project === 'string' ? { project: a.project } : {}), at: now() }
          if (!before || before.name !== next.name || before.engine !== next.engine || before.project !== next.project) learned = true
          who.set(`${machineId}/${a.agentId}`, next)
        }
      } catch { /* that machine is away: its agents keep the names they had */ }
    })
    const done = Promise.all(asks).then(() => { if (learned) notesPump() })
    if (wait) await done
  }

  /** The note a local agent should have read, or null when it shares no tab with a teammate, or Agent Messages are
   *  off here. */
  function rosterOf(agentId: string): { text: string; signature: string } | null {
    const me = { machineId: self(), agentId }
    const peers = directory.peers(me)
    if (!peers.length) return null
    const mates = distinct(me, peers)
    const text = note(directory.tabsOf(me), mates)
    return { text, signature: createHash('sha256').update(text).digest('hex').slice(0, 12) }
  }

  /**
   * Another of the owner's machines started a harness here for one of its agents (`harness new @this-machine`): kept
   * in this machine's record too, so the new harness's depth and this machine's limits count it.
   */
  function started(payload: Record<string, unknown>): Record<string, unknown> {
    const row = parseStarted(JSON.stringify(payload.row ?? null))
    if (!row || row.child.machineId !== self() || row.by.machineId === self()) throw new MessageError('INVALID_RECORD', 'That is not a harness another machine started here.')
    if (!core.agents.live().some((s) => s.agentId === row.child.agentId)) throw new MessageError('UNKNOWN_HARNESS', 'No such harness on this machine.')
    lineage.append(row)
    return { recorded: true }
  }

  function withdrawNote(agentId: string): void {
    const pending = store.state.notes[agentId]
    if (!pending) return
    inbox.withdraw(pending.pane, pending.key)
    delete store.state.notes[agentId]
    saveQuietly()
  }

  /** Give each local agent the roster note it has not read: through its hook only, never typed. Off, take each back. */
  function notesPump(): void {
    if (!directory.current() && directory.on()) return
    const unknown: Member[] = []
    const alive = new Set(live().map((s) => s.agentId))
    // A note for a harness that is gone or stopped is withdrawn: its pane number may be another's next.
    for (const agentId of Object.keys(store.state.notes)) if (!alive.has(agentId)) withdrawNote(agentId)
    for (const session of live()) {
      const pending = store.state.notes[session.agentId]
      if (pending && inbox.claimed(pending.pane, pending.key)) {
        store.state.noted[session.agentId] = pending.signature
        delete store.state.notes[session.agentId]
        saveQuietly()
      }
      const roster = rosterOf(session.agentId)
      if (!roster) { withdrawNote(session.agentId); continue }
      // Only another machine can name its agents: a teammate here with no harness is stopped, and has no name to ask.
      unknown.push(...directory.peers({ machineId: self(), agentId: session.agentId }).filter((m) => m.machineId !== self() && !teammate(m).known))
      if (store.state.noted[session.agentId] === roster.signature) { withdrawNote(session.agentId); continue }
      const current = store.state.notes[session.agentId]
      if (current?.signature === roster.signature && current.pane === session.tmuxPane && inbox.waiting(current.pane, current.key)) continue
      withdrawNote(session.agentId)
      const noteKey = `0note-${roster.signature}`
      try {
        inbox.put(session.tmuxPane, noteKey, { session: session.sessionId ?? '', text: roster.text })
        store.state.notes[session.agentId] = { pane: session.tmuxPane, key: noteKey, signature: roster.signature }
        saveQuietly()
      } catch { /* the next look puts it */ }
    }
    if (unknown.length) void learnNames(unknown, false)
  }

  // ── sending ──────────────────────────────────────────────────────────────────────────────────────

  async function send(payload: Record<string, unknown>): Promise<Record<string, unknown>> {
    const pane = typeof payload.pane === 'string' ? payload.pane : ''
    if (!PANE.test(pane)) throw new MessageError('NOT_A_HARNESS', 'Run harness send from a harness pane.')
    const session = live().find((s) => s.tmuxPane === pane)
    if (!session) throw new MessageError('NOT_A_HARNESS', 'This pane is not a harness Harness knows. Run harness send from an agent\'s pane.')
    // Off is the person's word, answered before the tabs are read: a backend that cannot be reached is not the reason.
    if (!directory.on()) throw new MessageError('MESSAGES_OFF', MESSAGES_OFF_TEXT)
    if (!await directory.refresh()) throw new MessageError('DIRECTORY_UNAVAILABLE', 'Harness could not read who is in which tab. Try again in a moment.')
    const me = { machineId: self(), agentId: session.agentId }
    const peers = directory.peers(me)
    await learnNames(peers, true)
    const mates = distinct(me, peers)
    const names = (Array.isArray(payload.to) ? payload.to : typeof payload.to === 'string' ? payload.to.split(',') : [])
      .map((n) => String(n).trim()).filter(Boolean)
    const text = typeof payload.text === 'string' ? payload.text : ''
    // No recipient and no text: who is here, the rules, and this agent's last messages. An agent whose context
    // was compacted asks this to learn again what it was told: seen on a real team, one rebuilt it from its team
    // history in five commands.
    if (!names.length && !text) return { roster: rosterOf(session.agentId)?.text ?? 'No teammates in this tab yet.', recent: recentFor(me) }
    // Alone in its tab, or in none: a name it gives can be no one's, and the person is the one who can change that.
    if (!peers.length) throw new MessageError('NO_TEAMMATES', 'No other harness is in this tab. The person puts harnesses in one tab for them to message each other.')
    if (!names.length) throw new MessageError('USAGE', 'Name who to message: harness send <name> "text"')
    if (!text.trim()) throw new MessageError('USAGE', 'Write the message: harness send <name> "text"')
    if (text.length > LIMITS.text) throw new MessageError('TOO_LONG', `A message holds at most ${LIMITS.text} characters.`)
    const recipients: Recipient[] = []
    for (const name of names) {
      const wanted = name.toLowerCase()
      const exact = mates.filter((m) => m.name.toLowerCase() === wanted)
      const prefix = exact.length ? exact : mates.filter((m) => m.name.toLowerCase().startsWith(wanted) || cutShort(m.name.toLowerCase(), wanted))
      // Or the start of its id: a name is the session's title until someone names it, and a title can hold a comma,
      // which the recipient list splits on.
      const found = prefix.length || wanted.length < 6 ? prefix : mates.filter((m) => m.member.agentId.toLowerCase().startsWith(wanted))
      const list = mates.map((m) => m.name).join(', ') || 'nobody yet'
      if (!found.length) throw new MessageError('UNKNOWN_RECIPIENT', `No teammate named "${name}" in this tab. Teammates: ${list}.`)
      if (found.length > 1) throw new MessageError('AMBIGUOUS_RECIPIENT', `"${name}" could be ${found.map((m) => m.name).join(' or ')}. Use more of the name.`)
      if (!recipients.some((r) => r.machineId === found[0].member.machineId && r.agentId === found[0].member.agentId)) {
        recipients.push({ ...found[0].member, name: found[0].name })
      }
    }
    if (recipients.length > LIMITS.recipients) throw new MessageError('TOO_MANY_RECIPIENTS', `A message goes to at most ${LIMITS.recipients} teammates.`)
    // The first recipient's tab names the message's log. The directory and the setting can change while other
    // machines are asked for names: Agent Messages turned off, or the tab left, meanwhile leaves none, and nothing is
    // sent.
    const tab = directory.shared(me, recipients[0])
    if (!tab && !directory.on()) throw new MessageError('MESSAGES_OFF', `${MESSAGES_OFF_TEXT} Nothing was sent.`)
    if (!tab) throw new MessageError('NOT_IN_TAB', `${recipients[0].name} is no longer in a tab with you. Nothing was sent.`)
    const times = (sent.get(session.agentId) ?? []).filter((t) => now() - t < LIMITS.window)
    if (times.length >= LIMITS.perSender) {
      core.clients.windows({ type: 'messages_changed', payload: { limited: { machineId: self(), agentId: session.agentId } } })
      throw new MessageError('RATE_LIMITED', `This harness sent ${LIMITS.perSender} messages in 10 minutes. Wait, or work on without its teammates for now.`)
    }
    if (store.state.local.filter((d) => d.state === 'queued').length >= LIMITS.waiting) {
      throw new MessageError('MAILBOX_FULL', 'Too many messages are waiting on this machine. Try again once some are delivered.')
    }
    sent.set(session.agentId, [...times, now()])
    const message: Message = {
      id: messageId(), tabId: tab.id, to: recipients, text, at: now(), ...(payload.fyi === true ? { fyi: true as const } : {}),
      from: { ...me, name: ownName(me, peers), engine: session.engine, machine: machineName(self()) },
    }
    store.record(message)
    for (const r of recipients) store.status({ messageId: message.id, machineId: r.machineId, agentId: r.agentId, state: 'queued', at: now() })
    for (const r of recipients.filter((r) => r.machineId === self())) mailbox.accept(message, r.agentId)
    for (const machineId of new Set(recipients.filter((r) => r.machineId !== self()).map((r) => r.machineId))) {
      store.state.outbox.push({ messageId: message.id, machineId, nextTryAt: now(), tries: 0 })
    }
    saveQuietly()
    await handOver(message.id)
    tellWindows(message.id)
    const entry = store.entry(message.id)!
    return {
      id: message.id, tab: tab.name,
      recipients: recipients.map((r) => {
        const status = entry.statuses.find((s) => s.machineId === r.machineId && s.agentId === r.agentId)
        return { name: r.name, state: status?.state ?? 'queued', ...(status?.via ? { via: status.via } : {}), ...(status?.reason ? { reason: status.reason } : {}) }
      }),
      ...(text.length > LONG_TEXT ? { advice: longAdvice(text.length) } : {}),
    }
  }

  /**
   * What `harness send` alone gives an agent besides the roster: every message still waiting for it, which it has
   * now read, then its last few. An agent whose engine started before Agent Messages never runs the hook and, always
   * working, is never typed to: it read its messages this way, but only the last five, each still "queued", and a
   * restart would have given it all of them again (a Codex lead, 2026-10-12).
   */
  function recentFor(me: Member, count = 5): Array<Record<string, unknown>> {
    const mine = (m: Member) => m.machineId === me.machineId && m.agentId === me.agentId
    const involving = store.state.history.filter((e) => mine(e.message.from) || e.message.to.some(mine))
    const waiting = involving.filter((e) => !mine(e.message.from) && e.statuses.find((s) => mine(s))?.state === 'queued').slice(-UNREAD_MAX)
    const read = new Set(mailbox.read(me.agentId, waiting.map((e) => e.message.id)))
    const shown = [...new Set([...waiting, ...involving.slice(-count)])].sort((a, b) => a.message.at - b.message.at)
    return shown.map((e) => {
      const sent = mine(e.message.from)
      const status = sent ? e.statuses.find((s) => s.state !== 'delivered') ?? e.statuses[0] : e.statuses.find((s) => mine(s))
      return { id: e.message.id, at: e.message.at, ...(sent ? { to: e.message.to.map((r) => r.name) } : { from: e.message.from.name }),
        text: e.message.text, state: read.has(e.message.id) ? 'delivered' : status?.state ?? 'queued', ...(read.has(e.message.id) ? { unread: true } : {}) }
    })
  }

  /** Hand what waits in the outbox to its machines: now for one message, or every one that is due. */
  async function handOver(onlyId?: string): Promise<void> {
    const due = store.state.outbox.filter((o) => (onlyId ? o.messageId === onlyId : now() >= o.nextTryAt))
    await Promise.all(due.map(async (outgoing) => {
      const entry = store.entry(outgoing.messageId)
      if (!entry) { store.state.outbox = store.state.outbox.filter((o) => o !== outgoing); return }
      try {
        const answer = await rpc(at(outgoing.machineId), { action: 'deliver', message: entry.message }, 10_000)
        store.state.outbox = store.state.outbox.filter((o) => o !== outgoing)
        applyRemote(outgoing.machineId, answer.statuses)
      } catch (error) {
        outgoing.tries += 1
        outgoing.nextTryAt = now() + Math.min(5 * 60_000, 5_000 * 2 ** Math.min(outgoing.tries, 6))
        outgoing.reason = error instanceof MessageError && error.code === 'NO_PEER_LINK' ? 'that machine is not paired with this one' : 'that machine is away: it is handed over once it is back'
        for (const r of entry.message.to.filter((r) => r.machineId === outgoing.machineId)) {
          if (store.status({ messageId: entry.message.id, machineId: r.machineId, agentId: r.agentId, state: 'queued', reason: outgoing.reason, at: now() })) tellWindows(entry.message.id)
        }
      }
    }))
    if (due.length) saveQuietly()
  }

  /**
   * What another machine said became of its agents' deliveries. Every way one arrives is kept: a message an agent
   * read with `harness send` came back as a bare "delivered" to the machine that sent it, so its sender never saw
   * that it was read (two machines, 2026-10-12).
   */
  function applyRemote(machineId: string, statuses: unknown): void {
    for (const s of Array.isArray(statuses) ? statuses as Record<string, unknown>[] : []) {
      if (typeof s.messageId !== 'string' || typeof s.agentId !== 'string' || !['queued', 'delivered', 'failed'].includes(String(s.state))) continue
      const status: DeliveryStatus = { messageId: s.messageId, machineId, agentId: s.agentId, state: s.state as DeliveryStatus['state'],
        ...(s.via === 'hook' || s.via === 'prompt' || s.via === 'read' ? { via: s.via } : {}), ...(typeof s.reason === 'string' ? { reason: s.reason } : {}), at: now() }
      if (store.status(status)) tellWindows(status.messageId)
    }
  }

  /** Ask other machines what became of this machine's messages still waiting there. */
  async function remoteStatus(): Promise<void> {
    const waiting = new Map<string, string[]>()
    for (const entry of store.state.history) {
      if (entry.message.from.machineId !== self()) continue
      for (const s of entry.statuses) {
        if (s.machineId === self() || s.state !== 'queued' || store.state.outbox.some((o) => o.messageId === entry.message.id && o.machineId === s.machineId)) continue
        waiting.set(s.machineId, [...new Set([...(waiting.get(s.machineId) ?? []), entry.message.id])])
      }
    }
    await Promise.all([...waiting].map(async ([machineId, ids]) => {
      try { applyRemote(machineId, (await rpc(at(machineId), { action: 'status', ids: ids.slice(-200) }, 10_000)).statuses) } catch { /* asked again later */ }
    }))
    if (waiting.size) saveQuietly()
  }

  // ── another machine's requests ───────────────────────────────────────────────────────────────────

  async function deliver(payload: Record<string, unknown>): Promise<Record<string, unknown>> {
    const message = parseMessage(payload.message)
    if (!message) throw new MessageError('INVALID_MESSAGE', 'That is not a message.')
    // This machine's own harnesses send through `send`, which names them by their pane: never as another's.
    if (message.from.machineId === self()) throw new MessageError('NOT_FROM_THERE', 'A message from this machine is sent here, not handed over.')
    // Off here, it fails below whatever the tabs say: they are not read for it.
    if (directory.on() && !await directory.refresh()) throw new MessageError('DIRECTORY_UNAVAILABLE', 'Harness could not read who is in which tab. It is handed over again later.')
    if (store.state.local.filter((d) => d.state === 'queued').length >= LIMITS.waiting) {
      throw new MessageError('MAILBOX_FULL', 'Too many messages are waiting on that machine. It is handed over again later.')
    }
    const known = store.entry(message.id)
    if (!known) store.record(message)
    const statuses: DeliveryStatus[] = []
    for (const r of message.to.filter((r) => r.machineId === self())) {
      if (!known && !store.state.local.some((d) => d.messageId === message.id && d.agentId === r.agentId)) {
        // Off here, a hand-over fails at once, as one to an agent outside the sender's tabs does: only what already
        // waits here is held through a switch turned off and on again.
        if (!directory.shared(message.from, r)) {
          store.status({ messageId: message.id, machineId: self(), agentId: r.agentId, state: 'failed', reason: directory.on() ? 'it is not in a tab with the sender' : 'Agent Messages are off on its computer', at: now() })
        } else {
          store.status({ messageId: message.id, machineId: self(), agentId: r.agentId, state: 'queued', at: now() })
          mailbox.accept(message, r.agentId)
        }
      }
      const s = store.entry(message.id)!.statuses.find((x) => x.machineId === self() && x.agentId === r.agentId)
      if (s) statuses.push(s)
    }
    saveQuietly()
    tellWindows(message.id)
    return { statuses }
  }

  function statusOf(payload: Record<string, unknown>): Record<string, unknown> {
    const ids = Array.isArray(payload.ids) ? payload.ids.filter((id): id is string => typeof id === 'string').slice(0, 200) : []
    return { statuses: ids.flatMap((id) => store.entry(id)?.statuses.filter((s) => s.machineId === self()) ?? []) }
  }

  function whoAre(payload: Record<string, unknown>): Record<string, unknown> {
    const ids = Array.isArray(payload.agentIds) ? payload.agentIds.filter((id): id is string => typeof id === 'string').slice(0, 64) : []
    return { agents: ids.flatMap((agentId) => {
      const session = localAgent(agentId)
      return session ? [{ agentId, name: core.agents.displayName(session) || agentId.slice(0, 8), engine: session.engine, ...(session.cwd ? { project: basename(session.cwd) } : {}) }] : []
    }) }
  }

  function history(payload: Record<string, unknown>): Record<string, unknown> {
    const tabId = typeof payload.tabId === 'string' ? payload.tabId : null
    const limit = typeof payload.limit === 'number' && payload.limit > 0 ? Math.min(payload.limit, LIMITS.history) : 200
    const entries = store.state.history.filter((e) => !tabId || e.message.tabId === tabId)
    return { messages: entries.slice(-limit).map((e) => ({ ...e.message, statuses: e.statuses })) }
  }

  /**
   * Inbox files nothing here is waiting to deliver, from a service that stopped or a daemon long gone (the inboxes
   * are every daemon's on this computer): removed once they are old enough not to be another live daemon's
   * delivery in the making, which that daemon puts back anyway.
   */
  function sweep(): void {
    const ours = new Set([
      ...store.state.local.filter((d) => d.state === 'queued' && d.pane).map((d) => `${d.pane}/${d.key}`),
      ...Object.values(store.state.notes).map((n) => `${n.pane}/${n.key}`),
    ])
    for (const entry of inbox.entries()) {
      if (!ours.has(`${entry.pane}/${entry.key}`) && now() - entry.at > SWEEP_AFTER_MS) inbox.withdraw(entry.pane, entry.key)
    }
  }

  function saveQuietly(): void {
    try { store.save() } catch { /* kept in memory; the next change saves again */ }
  }

  const stopHearing = core.turns.onDelivery((event: TurnDelivery) => mailbox.observe(event))
  // Asleep, a changed desk is read when it wakes, not now.
  const stopNotices = core.account.onNotice((notice) => { if (notice.type === 'desk_changed' && !asleep()) void directory.refresh(true) })

  // Started only as it wakes, when it is stopped: never twice.
  const startTick = (): void => {
    timer = setInterval(() => {
      notesPump()
      void handOver()
      if (now() - lastRemoteStatus >= REMOTE_STATUS_MS) { lastRemoteStatus = now(); void remoteStatus() }
    }, TICK_MS)
    timer.unref?.()
  }
  const stopTick = (): void => {
    if (timer) clearInterval(timer)
    timer = null
  }

  /**
   * Run what this computer calls for now: everything while it is signed in with Agent Messages on; while they are off,
   * the notes withdrawn, what waits held and then failed by the mailbox's look, which stops once nothing waits, and
   * a watch on the setting's file to wake it; signed out, nothing. Every computer runs this service: one with it off,
   * or never signed in, paid a read of the account's tabs every 15 s and three timers for messages it could never
   * carry (2026-10-12).
   */
  function wake(): void {
    if (!running) return
    const next = !core.account.signedIn() ? 'signedOut' : readSetting() ? 'awake' : 'off'
    if (next === mode) return
    mode = next
    if (next === 'awake') {
      unwatch?.()
      unwatch = null
      directory.start()
      mailbox.resume()
      startTick()
      return
    }
    directory.stop()
    stopTick()
    if (next === 'signedOut') {
      unwatch?.()
      unwatch = null
      mailbox.pause()
      return
    }
    // Never watching yet: it was awake, signed out or not running, and none of those watches.
    unwatch = (options.watchSetting ?? watchSettingFile)(settingsFile, later)
    mailbox.refuseAll()
    notesPump()
    // The mailbox looks on only while something here waits to be held and then failed; it stops itself after.
    if (mailbox.waiting()) mailbox.resume()
    else mailbox.pause()
  }

  return {
    requests: {
      agent_messages: (payload, asker) => Promise.resolve().then(async () => {
        if (!asker.owner) throw new MessageError('OWNER_REQUIRED', 'Agent Messages answer only the owner.')
        // A pane is only this machine's to name; a hand-over, its status and its names are another machine's
        // daemon's to ask, over the relay, never a process here's.
        const fromHere = ['send'].includes(String(payload.action))
        if (['send', 'deliver', 'status', 'who', 'started'].includes(String(payload.action)) && asker.local !== fromHere) {
          throw new MessageError(fromHere ? 'LOCAL_ONLY' : 'REMOTE_ONLY', fromHere ? 'harness send runs in a pane on this machine.' : 'Only another of your machines hands messages over.')
        }
        switch (payload.action) {
          case 'send': return send(payload)
          case 'deliver': return deliver(payload)
          case 'status': return statusOf(payload)
          case 'who': return whoAre(payload)
          case 'started': return started(payload)
          case 'history': return history(payload)
          default: throw new MessageError('UNKNOWN_ACTION', 'Unknown Agent Messages request.')
        }
      }).catch((error: unknown) => (error instanceof MessageError
        ? { error: error.code, detail: error.message }
        : { error: 'MESSAGES_UNAVAILABLE', detail: 'Agent Messages are unavailable right now. Nothing was sent.' })),
    },
    canWrite: (deliveryId) => mailbox.canWrite(deliveryId),
    reconnected: () => {
      mailbox.takeBackAttempts()
      wake()
    },
    settingsChanged: later,
    start: () => {
      running = true
      mailbox.start()
      sweep()
      wake()
    },
    stop: () => {
      running = false
      mode = null
      unwatch?.()
      unwatch = null
      stopTick()
      stopHearing()
      stopNotices()
      mailbox.stop()
      directory.stop()
    },
  }
}
