/**
 * Harness for agents (docs/design/2026-10-11-agent-client.md): the verbs an agent runs from its own pane to see,
 * read, wait for and close other harnesses. `harness new` and `harness send` are the other two; this file gives
 * `new` what it needs when an agent runs it (`agentOrigin`).
 *
 *     harness ps [--all] [--json]
 *     harness show <name> [--chars N] [--json]
 *     harness wait <name>[,<name>…] [--any] [--timeout 30m] [--json]
 *     harness close <name> [--now] [--json]
 *
 * Text by default, because agents read it as well as people do and it costs them a fraction of the tokens;
 * `--json` for programs. Everything is composed from requests the daemon already answers: `agents_list`,
 * `agent_recent`, a bounded `session_get` page, and `agent_close` (its `inspect` mode tells needs-input from idle).
 */
import { randomBytes } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { hostname } from 'node:os'
import { join } from 'node:path'
import { readAgentSettings } from '../lib/agentSettings.js'
import { MAX_FIRST_PROMPT_CHARS } from '../lib/engineLaunch.js'
import type { NewOrigin } from '../lib/newCommand.js'
import { engineName } from '../messages/model.js'
import { AgentClientError, openDaemon, whereFor, type Daemon, type Where } from './daemon.js'
import { Ledger, ledgerPath, type Pending, type Started } from './ledger.js'
import { messagesRpc, type Rpc } from '../messages/rpc.js'
import { asSaid, callerOf, clip, isAgent, lastTurn, matching, outsideCaller, rowsOf, stateOf, STOPPED_WITHIN_MS, type Caller, type Frame, type HistoryEvent, type Row, type State } from './model.js'

export interface ClientDeps {
  pane?: string | undefined
  /** The caller's environment: an agent outside Harness is told by what it sets there (`outsideCaller`). */
  env?: NodeJS.ProcessEnv
  where?: () => Where
  open?: (where: Where, machineId?: string) => Promise<Daemon>
  ledger?: (dataDir: string) => Ledger
  out?: (line: string) => void
  err?: (line: string) => void
  now?: () => number
  sleep?: (ms: number) => Promise<void>
  /** How often `wait` looks. */
  intervalMs?: number
  /** How a start is recorded on another machine (the messages service's `started`). */
  record?: Rpc
}

export const PS_USAGE = `Usage: harness ps [--all] [--json]

The harnesses on this machine: name, agent, state, who started it, when it was last active, and what it is about.
--all adds the ones stopped in the last week.`
export const SHOW_USAGE = `Usage: harness show <name> [--chars N] [--json]

A harness's state and its last turn: what it was asked and what it answered (the first N characters, 4000 by default).`
export const WAIT_USAGE = `Usage: harness wait <name>[,<name>…] [--any] [--timeout 30m] [--json]

Waits until each harness has stopped working, then prints its state. --any returns when the first one does.
Exit status: 0 idle or closed by you, 3 one needs the person (a question or a permission), 4 one stopped or is gone,
124 timed out.
--timeout takes 90s, 30m, 2h; 0 waits as long as it takes.`
export const CLOSE_USAGE = `Usage: harness close <name> [--now] [--json]

Saves the harness's screen and stops it. Its conversation is kept: the person can resume it.
It is refused while the harness is working, unless --now. An agent may close only harnesses it started.`

export const EXIT = { ok: 0, failed: 1, usage: 2, needsInput: 3, stopped: 4, timeout: 124 } as const

/** Set by `harness mcp` (mcp.ts) for the verbs it runs: their next steps are then named as its tools. */
export const VIA_MCP_ENV = 'HARNESS_VIA_MCP'
const TOOL_OF = { ps: 'harness_list', show: 'harness_read', wait: 'harness_wait', close: 'harness_close' } as const

/**
 * A next step as the caller can take it: the shell's `harness show x`, or the tool `harness mcp` offers for it. An MCP
 * client may have no shell at all (Claude Desktop), and its agent was told to run `harness show x` (2026-10-11, in a
 * clean VM). [option] is a flag and its MCP argument: `--chars 9000` / `chars: 9000`.
 */
export function step(env: NodeJS.ProcessEnv, verb: keyof typeof TOOL_OF, name = '', option?: { flag: string; arg: string }): string {
  if (env[VIA_MCP_ENV] !== '1') return ['harness', verb, name, option?.flag].filter(Boolean).join(' ')
  const args = [name && `${verb === 'wait' ? 'names' : 'name'}: "${name}"`, option?.arg].filter(Boolean)
  return `${TOOL_OF[verb]}${args.length ? ` (${args.join(', ')})` : ''}`
}

const DEFAULT_CHARS = 4_000
const DEFAULT_TIMEOUT_MS = 30 * 60_000
const DEFAULT_INTERVAL_MS = 3_000
/** How many harnesses `ps` asks what they are about; the rest list without it. */
const ABOUT_MAX = 40
/** A harness that never worked while waited on, with nothing in its transcript: nothing to wait for. */
const QUIET_LOOKS = 3
/** How long a new harness may take to start and have its task typed (a Codex start with its trust prompt is the
 *  slowest seen). Before it, a harness that is not working may simply not have begun. */
const STARTING_MS = 2 * 60_000

class UsageError extends Error {}

/** What an agent's `harness new` (and MCP's `harness_start`) says while the person has not let agents start agents: an
 *  account experiment, off by default (lib/agentSettings.ts), so it says where the person turns it on, as `harness send`
 *  does. */
export const AGENTS_START_AGENTS_OFF = 'Agents may not start harnesses: the person turns on "Agents can start other agents" in Harness Settings ▸ Experimental, or runs `harness settings agents-start-agents on`. Until then, do the work yourself.'

const ORPHAN = 'This pane\'s harness is no longer running, so nothing here may close or start harnesses. Only the person can.'

/**
 * A harness the caller asked for that has not started, as its machine says now: still on its way (`installing` while
 * Harness installs its engine), or never started (`failed`, with why). `harness new` answers before an install is done,
 * so an agent follows such a harness by its name with `ps` and `wait` until it starts by itself.
 */
export interface Asked { row: Pending; state: 'installing' | 'starting' | 'failed'; detail: string }

interface Opened {
  where: Where; daemon: Daemon; frames: Frame[]; caller: Caller | null; ledger: Ledger; machine: string
  /** The caller's harnesses asked for and not started (`Asked`). */
  asked: Asked[]
  /** Run from a pane Harness made whose harness it no longer knows (closed, forgotten): what is left of an agent,
   *  a background job it started, say. Never the person: it may look, not close or start. */
  orphan: boolean
  /** `frames` holds the stopped harnesses too. */
  stopped: boolean
}

function setup(deps: ClientDeps) {
  return {
    pane: 'pane' in deps ? deps.pane : process.env.TMUX_PANE,
    env: deps.env ?? process.env,
    where: deps.where ?? (() => whereFor('pane' in deps ? deps.pane : process.env.TMUX_PANE)),
    open: deps.open ?? ((where: Where, machineId?: string) => openDaemon(where, machineId)),
    ledger: deps.ledger ?? ((dataDir: string) => new Ledger(ledgerPath(dataDir))),
    out: deps.out ?? ((line: string) => console.log(line)),
    err: deps.err ?? ((line: string) => console.error(line)),
    now: deps.now ?? Date.now,
    sleep: deps.sleep ?? ((ms: number) => new Promise<void>((done) => setTimeout(done, ms))),
    intervalMs: deps.intervalMs ?? DEFAULT_INTERVAL_MS,
    record: deps.record ?? messagesRpc,
  }
}
type Setup = ReturnType<typeof setup>

/** This machine's name as Harness shows it (`machine-name` in the data folder), else the host's. */
export function machineNameOf(dataDir: string): string {
  try {
    const name = readFileSync(join(dataDir, 'machine-name'), 'utf8').trim()
    if (name) return name
  } catch { /* the host's name below */ }
  return hostname().replace(/\.local$/, '')
}

async function list(daemon: Daemon, includeStopped: boolean): Promise<Frame[]> {
  const reply = await daemon.request('agents_list', { includeStopped })
  if (reply.error) throw new AgentClientError(String(reply.error), 'Harness could not list its harnesses. Try again.')
  return Array.isArray(reply.agents) ? reply.agents as Frame[] : []
}

/**
 * The line to the caller's daemon, its harnesses, who is calling, and the ledger. Live ones (and offline ones) only,
 * unless asked: the list with every stopped harness took 128 ms against 10 ms on the owner's Mac (391 harnesses, 21
 * live), and a stopped harness keeps no pane, so the caller is never one.
 */
async function opened(s: Setup, includeStopped = false): Promise<Opened> {
  const where = s.where()
  const daemon = await s.open(where)
  try {
    const frames = await list(daemon, includeStopped)
    const inPane = callerOf(frames, s.pane, where.machineId)
    // Any status: the core marks every session inactive as it starts (core/main.ts), and a person's terminal is theirs
    // through it. A stopped harness keeps no pane (`toStoppedProject`), so an old pane number never matches one.
    const terminal = frames.some((f) => f.tmuxPane === s.pane && f.engine === 'terminal')
    const orphan = !!s.pane && !!where.harnessPane && !inPane && !terminal
    // Not a harness: an agent outside Harness when its shell says so, even in a terminal of Harness's own.
    const caller = inPane ?? (orphan ? null : outsideCaller(s.env, where.machineId))
    const ledger = s.ledger(where.dataDir)
    const asked = await askAfter(s, where, daemon, ledger, caller)
    return { where, daemon, frames, caller, orphan, stopped: includeStopped, ledger, machine: machineNameOf(where.dataDir), asked }
  } catch (error) { daemon.close(); throw error }
}

/** What a held creation waits for, in the machine's words (`held.detail`). */
const heldDetail = (status: Record<string, unknown>): string => {
  const held = status.held as { detail?: unknown } | undefined
  return typeof held?.detail === 'string' ? held.detail.replace(/[\x00-\x1f\x7f]/g, ' ').trim().slice(0, 500) : ''
}

/** How it stands, from a creation's status: null once there is nothing left to follow (made, cancelled, unknown). */
export function askedOf(row: Pending, status: Record<string, unknown>): Asked | null {
  if (status.state === 'pending') {
    const install = (status.held as { service?: unknown } | undefined)?.service === 'install'
    return { row, state: install ? 'installing' : 'starting', detail: heldDetail(status) }
  }
  if (status.state !== 'failed') return null
  const failure = (status.failure ?? {}) as { code?: unknown; detail?: unknown }
  const detail = typeof failure.detail === 'string' && failure.detail ? failure.detail : typeof failure.code === 'string' ? failure.code : ''
  return { row, state: 'failed', detail: detail.slice(0, 500) }
}

/**
 * Records a harness asked for and made since as started by who asked (`Started`, with its creation), here and, for one
 * on another machine, there too, as `harness new` does (`created`): there its limits and depth start from it.
 */
async function recordMade(s: Setup, where: Where, ledger: Ledger, row: Pending, agent: Frame): Promise<void> {
  const started: Started = { at: row.at, by: row.by, depth: row.depth,
    child: { machineId: row.creation.machineId, agentId: agent.id, name: agent.name || row.creation.name, creationId: row.creation.creationId } }
  if (ledger.parentOf(started.child)) return
  ledger.record(started)
  if (row.creation.machineId !== where.machineId) {
    await s.record({ port: where.port, dataDir: where.dataDir, machineId: row.creation.machineId }, { action: 'started', row: started }, 10_000).catch(() => {})
  }
}

/**
 * The pending lines (ledger.ts `Pending`) asked of their machines. One now made is recorded as started by who asked, as
 * `harness new` would have had it not answered first: anyone's on this machine, so a harness that started by itself
 * has its depth before it runs a verb of its own, and the caller's anywhere. The rest of the caller's are what it still
 * follows. A machine that cannot be asked keeps its line as starting: a second harness by that name is the risk here.
 */
async function askAfter(s: Setup, where: Where, daemon: Daemon, ledger: Ledger, caller: Caller | null): Promise<Asked[]> {
  const asked: Asked[] = []
  const mine = (row: Pending) => !!caller && row.by.machineId === caller.machineId && row.by.agentId === caller.agentId
  for (const row of ledger.pendingOf(null, s.now())) {
    const here = row.creation.machineId === where.machineId
    if (!here && !mine(row)) continue
    let line: Daemon | null = here ? daemon : null
    try {
      line ??= await s.open(where, row.creation.machineId)
      const status = await line.request('agent_create_status', { creationId: row.creation.creationId }, 8_000)
      const agent = (status.agent ?? {}) as Frame
      if (status.state === 'created' && typeof agent.id === 'string' && agent.id) { await recordMade(s, where, ledger, row, agent); continue }
      const now = mine(row) ? askedOf(row, status) : null
      if (now) asked.push(now)
    } catch { if (mine(row)) asked.push({ row, state: 'starting', detail: '' }) }
    finally { if (!here) line?.close() }
  }
  return asked
}

/** How a harness asked for is called: its name, else its creation's start. */
const askedName = (a: Asked): string => a.row.creation.name || a.row.creation.creationId.slice(0, 8)

/** What the caller asked for by [name] that has not started: the latest, by the name it was given or its creation's start. */
const askedNamed = (o: Opened, name: string): Asked | undefined => {
  const wanted = name.trim().toLowerCase()
  return o.asked.filter((a) => askedName(a).toLowerCase() === wanted || (wanted.length >= 6 && a.row.creation.creationId.toLowerCase().startsWith(wanted))).at(-1)
}

/** One line on a harness that has not started: what it waits for, or why it never will. */
function askedLine(env: NodeJS.ProcessEnv, a: Asked): string {
  const name = askedName(a), engine = engineName(a.row.creation.engine)
  if (a.state === 'failed') return `${name} never started: ${a.detail || 'its machine refused it'}.`
  const why = a.state === 'installing' ? `Harness is installing ${engine}` : `it is starting${a.detail ? ` (${a.detail.replace(/\.$/, '')})` : ''}`
  return `${name} has not started yet: ${why}. It starts by itself; wait for it with ${step(env, 'wait', name)}.`
}

interface Target { daemon: Daemon; frame: Frame; machineId: string; machine: string; yours: boolean; remote: boolean }

/**
 * The harness [name] means: one on this machine, else one the caller started on another machine. A live harness
 * is preferred over a stopped one of the same name.
 */
async function target(s: Setup, o: Opened, name: string): Promise<Target> {
  const named = (frames: Frame[]) => frames.filter(isAgent).map((f) => ({ ...f, name: f.name || f.id.slice(0, 8) }))
  const yoursOn = (machineId: string, agentId: string): boolean => {
    const parent = o.ledger.parentOf({ machineId, agentId })
    return !!o.caller && !!parent && parent.by.agentId === o.caller.agentId && parent.by.machineId === o.caller.machineId
  }
  // Asked for by exactly this name and not started: it, before a harness whose name merely starts so.
  const pending = askedNamed(o, name)
  const exactly = (f: Frame) => f.name?.toLowerCase() === name.trim().toLowerCase() || f.id.toLowerCase() === name.trim().toLowerCase()
  if (pending && !named(o.frames).some(exactly)) throw new AgentClientError(pending.state === 'failed' ? 'NEVER_STARTED' : 'NOT_STARTED', askedLine(s.env, pending))
  let found = matching(name, named(o.frames))
  // No live one by that name: the stopped ones too, read once.
  if (!found.length && !o.stopped) {
    o.frames = await list(o.daemon, true)
    o.stopped = true
    found = matching(name, named(o.frames))
  }
  if (found.some((f) => f.status !== 'stopped')) found = found.filter((f) => f.status !== 'stopped')
  if (found.length === 1) {
    const frame = found[0]
    return { daemon: o.daemon, frame, machineId: o.where.machineId, machine: o.machine, yours: yoursOn(o.where.machineId, frame.id), remote: false }
  }
  if (found.length > 1) {
    throw new AgentClientError('AMBIGUOUS', `"${name}" could be ${found.slice(0, 6).map((f) => `${f.name} (${f.id.slice(0, 8)}, ${stateOf(f)})`).join(', ')}. Use more of the name, or the id.`)
  }
  // One the caller started, by the name it was started with (an unnamed harness takes its session's title once it
  // has one), here or on another machine.
  const mine = o.caller ? o.ledger.childrenOf(o.caller) : []
  const elsewhere = matching(name, mine.map((row) => ({ name: row.child.name || row.child.agentId.slice(0, 8), id: row.child.agentId, row })))
  const here = elsewhere.length === 1 && elsewhere[0].row.child.machineId === o.where.machineId
    ? named(o.frames).find((f) => f.id === elsewhere[0].row.child.agentId) : undefined
  if (here) return { daemon: o.daemon, frame: here, machineId: o.where.machineId, machine: o.machine, yours: true, remote: false }
  if (elsewhere.length === 1 && elsewhere[0].row.child.machineId !== o.where.machineId) {
    const { row } = elsewhere[0]
    const daemon = await s.open(o.where, row.child.machineId)
    const frame = named(await list(daemon, true)).find((f) => f.id === row.child.agentId)
    if (!frame) { daemon.close(); throw new AgentClientError('GONE', `${elsewhere[0].name} is no longer on its machine.`) }
    return { daemon, frame, machineId: row.child.machineId, machine: row.child.machineId.slice(0, 8), yours: true, remote: true }
  }
  const asked = askedNamed(o, name)
  if (asked) throw new AgentClientError(asked.state === 'failed' ? 'NEVER_STARTED' : 'NOT_STARTED', askedLine(s.env, asked))
  throw new AgentClientError('UNKNOWN_HARNESS', `No harness named "${name}" on this machine. \`${step(s.env, 'ps')}\` lists them.`)
}

type Screen = 'working' | 'needs-input' | 'idle' | 'draft'

/** What the screen says now (the windows' read, `agent_close` `inspect`); null when it cannot be read. `draft`:
 *  text waits in its box, the person's or a message being typed, so the agent is about to work. */
async function inspect(t: { daemon: Daemon; frame: Frame }): Promise<Screen | null> {
  const reply = await t.daemon.request('agent_close', {
    agentId: t.frame.id, sessionId: t.frame.sessionId ?? '', createdAt: t.frame.createdAt ?? '', mode: 'inspect',
  }).catch(() => ({} as Record<string, unknown>))
  switch (reply.activity) {
    case 'working': return 'working'
    case 'needs_input': return 'needs-input'
    case 'idle': return 'idle'
    case 'draft': return 'draft'
    default: return null
  }
}

/** The last turn, from the end of the transcript, a page at a time: never the whole file (the attach OOM). */
async function readLastTurn(t: { daemon: Daemon; frame: Frame }, pages = 4) {
  if (!t.frame.sessionId) return null
  let before: string | undefined
  let events: HistoryEvent[] = []
  for (let i = 0; i < pages; i++) {
    const page = await t.daemon.request('session_get', { sessionId: t.frame.sessionId, limit: 80, ...(before ? { before } : {}) })
    if (page.error) return null
    events = [...(Array.isArray(page.events) ? page.events as HistoryEvent[] : []), ...events]
    const turn = lastTurn(events)
    if (turn || page.hasMore !== true || typeof page.oldestCursor !== 'string') return turn
    before = page.oldestCursor
  }
  return lastTurn(events)
}

function words(argv: readonly string[], known: Record<string, 'flag' | 'value'>): { names: string[]; flags: Map<string, string | true> } {
  const names: string[] = [], flags = new Map<string, string | true>()
  for (let i = 0; i < argv.length; i++) {
    const word = argv[i]
    if (word === '--help' || word === '-h') throw new UsageError('')
    if (word.startsWith('--')) {
      const [key, inline] = word.split('=', 2)
      const kind = known[key]
      if (!kind) throw new UsageError(`Unknown option ${key}.`)
      if (kind === 'flag') flags.set(key, true)
      else {
        const value = inline ?? argv[++i]
        if (value === undefined) throw new UsageError(`${key} needs a value.`)
        flags.set(key, value)
      }
    } else names.push(word)
  }
  return { names, flags }
}

export function parseDuration(value: string): number {
  const m = /^(\d+)(s|m|h)?$/.exec(value.trim())
  if (!m) throw new UsageError(`"${value}" is not a time: use 90s, 30m or 2h.`)
  return Number(m[1]) * (m[2] === 'h' ? 3_600_000 : m[2] === 's' ? 1_000 : 60_000)
}

const ago = (iso: string | null, now: number): string => {
  if (!iso) return '-'
  const s = Math.max(0, Math.round((now - Date.parse(iso)) / 1000))
  return s < 60 ? `${s}s` : s < 3600 ? `${Math.round(s / 60)}m` : s < 86_400 ? `${Math.round(s / 3600)}h` : `${Math.round(s / 86_400)}d`
}

const home = process.env.HOME ?? ''
const tilde = (path: string | null): string => (!path ? '-' : home && path.startsWith(home) ? `~${path.slice(home.length)}` : path)

async function run(usage: string, deps: ClientDeps, json: (argv: readonly string[]) => boolean, argv: readonly string[],
  body: (s: Setup) => Promise<number>): Promise<number> {
  const s = setup(deps)
  try { return await body(s) } catch (error) {
    if (error instanceof UsageError) {
      if (error.message) s.err(error.message)
      ;(error.message ? s.err : s.out)(usage)
      return error.message ? EXIT.usage : EXIT.ok
    }
    const code = error instanceof AgentClientError ? error.code : 'FAILED'
    const message = error instanceof Error ? error.message : String(error)
    if (json(argv)) s.out(JSON.stringify({ error: code, detail: message }))
    else s.err(message)
    return EXIT.failed
  }
}
const wantsJson = (argv: readonly string[]): boolean => argv.includes('--json')

// ── ps ─────────────────────────────────────────────────────────────────────────────────────────────

export function formatRows(rows: Row[], caller: Caller | null, now: number): string {
  if (!rows.length) return 'No harnesses on this machine.'
  const width = Math.min(32, Math.max(4, ...rows.map((r) => r.name.length)))
  const head = `${'NAME'.padEnd(width)}  ${'AGENT'.padEnd(11)}  ${'STATE'.padEnd(11)}  ${'STARTED BY'.padEnd(12)}  ${'ACTIVE'.padEnd(6)}  FOLDER`
  const lines = rows.map((r) => {
    const name = clip(r.name, width).padEnd(width)
    const line = `${name}  ${clip(r.agent, 11).padEnd(11)}  ${r.state.padEnd(11)}  ${clip(r.self ? `${r.startedBy} (you)` : r.startedBy, 12).padEnd(12)}  ${ago(r.lastActive, now).padEnd(6)}  ${tilde(r.folder)}${r.branch ? ` (${r.branch})` : ''}`
    const about = r.about ?? (r.asks?.length ? `asked: ${r.asks[0]}` : '')
    return about ? `${line}\n${' '.repeat(2)}${clip(about.replace(/\s+/g, ' '), 200)}` : line
  })
  const you = !caller ? null : caller.outside ? `You are ${caller.name}, outside Harness.` : `You are "${caller.name}" (${caller.agentId.slice(0, 8)}).`
  return [you, head, ...lines].filter((l) => l !== null).join('\n')
}

export function psCommand(argv: readonly string[], deps: ClientDeps = {}): Promise<number> {
  return run(PS_USAGE, deps, wantsJson, argv, async (s) => {
    const { names, flags } = words(argv, { '--all': 'flag', '--json': 'flag' })
    if (names.length) throw new UsageError(`harness ps takes no names. To read one: harness show ${names[0]}`)
    const o = await opened(s, flags.has('--all'))
    try {
      const rows = rowsOf(o.frames, { machineId: o.where.machineId, machine: o.machine, caller: o.caller, ledger: o.ledger, now: s.now(), all: flags.has('--all') })
      // What each is about: the summaries the daemon keeps (no transcript read), for the live ones.
      await Promise.all(rows.filter((r) => r.state !== 'stopped').slice(0, ABOUT_MAX).map(async (row) => {
        const recent = await o.daemon.request('agent_recent', { agentId: row.id, n: 3 }, 3_000).catch(() => null)
        if (!recent || recent.error) return
        const asks = (Array.isArray(recent.asks) ? recent.asks as unknown[] : []).filter((a): a is string => typeof a === 'string' && !!a.trim()).slice(0, 2)
        const about = (Array.isArray(recent.events) ? recent.events as Array<Record<string, unknown>> : [])
          .map((e) => (typeof e.recap === 'string' && e.recap ? e.recap : typeof e.text === 'string' ? e.text : '').replace(/\s+/g, ' ').trim())
          .filter(Boolean).slice(0, 3).map((t) => clip(t, 140))
        if (asks.length) row.asks = asks.map((a) => clip(asSaid(a).replace(/\s+/g, ' ').trim(), 200))
        if (about.length) row.about = about.join(' / ')
      }))
      // Asked for and not started yet: listed by the name it was given, and what it waits for.
      rows.unshift(...o.asked.map((a): Row => ({
        name: askedName(a), id: a.row.creation.creationId, agent: engineName(a.row.creation.engine),
        machine: a.row.creation.machineId === o.where.machineId ? o.machine : a.row.creation.machineId.slice(0, 8), state: a.state,
        folder: null, branch: null, startedBy: 'you', yours: true, self: false, lastActive: new Date(a.row.at).toISOString(), about: askedLine(s.env, a),
      })))
      const note = o.caller ? openNote(s.env, rows) : null
      s.out(flags.has('--json') ? JSON.stringify({ you: o.caller ? o.caller.name : null, machine: o.machine, harnesses: rows }, null, 1)
        : [formatRows(rows, o.caller, s.now()), note].filter(Boolean).join('\n'))
      return EXIT.ok
    } finally { o.daemon.close() }
  })
}

/** What `show` ends with for an idle harness of the caller's. */
export const closeHint = (env: NodeJS.ProcessEnv, frame: Frame): string =>
  `Close it once you have what you need: ${step(env, 'close', addressOf({ machineId: '', agentId: frame.id, name: frame.name ?? '', engine: '' }))}`

/** What `ps` ends with for an agent with harnesses of its own open: how many, and how many sit idle. */
export function openNote(env: NodeJS.ProcessEnv, rows: readonly Row[]): string | null {
  const open = rows.filter((r) => r.yours && r.state !== 'stopped' && r.state !== 'failed')
  if (!open.length) return null
  const idle = open.filter((r) => r.state === 'idle').length
  return `You have ${open.length} harness${open.length === 1 ? '' : 'es'} of your own open${idle ? `, ${idle} idle` : ''}. `
    + `Close each once you have its answer: ${step(env, 'close', '<name>')}.`
}

// ── show ───────────────────────────────────────────────────────────────────────────────────────────

export function showCommand(argv: readonly string[], deps: ClientDeps = {}): Promise<number> {
  return run(SHOW_USAGE, deps, wantsJson, argv, async (s) => {
    const { names, flags } = words(argv, { '--chars': 'value', '--json': 'flag' })
    if (names.length !== 1) throw new UsageError(names.length ? 'Name one harness.' : 'Name the harness to show.')
    const chars = flags.has('--chars') ? Number(flags.get('--chars')) : DEFAULT_CHARS
    if (!Number.isInteger(chars) || chars < 1) throw new UsageError('--chars takes a whole number.')
    const o = await opened(s)
    let t: Target | null = null
    try {
      t = await target(s, o, names[0])
      const listed = stateOf(t.frame)
      const screen = listed === 'stopped' || listed === 'offline' ? null : await inspect(t)
      const state: State = screen === 'draft' ? 'idle' : screen ?? listed
      const turn = await readLastTurn(t)
      const parent = o.ledger.parentOf({ machineId: t.machineId, agentId: t.frame.id })
      const startedBy = t.yours ? 'you' : parent ? parent.by.name : 'person'
      const answer = turn?.answer ?? ''
      const result = {
        name: t.frame.name, id: t.frame.id, agent: engineName(t.frame.engine ?? ''), machine: t.machine, state, startedBy,
        folder: t.frame.project?.cwd ?? null, branch: t.frame.project?.branch ?? null,
        ask: turn?.ask ?? null, answer: clip(answer, chars), truncated: answer.length > chars, tools: turn?.tools ?? 0,
      }
      if (flags.has('--json')) s.out(JSON.stringify(result, null, 1))
      else {
        s.out(`${result.name} · ${result.agent} · ${result.machine} · ${state} · started by ${startedBy}`)
        s.out(`folder: ${tilde(result.folder)}${result.branch ? ` (${result.branch})` : ''}`)
        if (!turn) s.out('No turn yet.')
        else {
          s.out(`asked: ${clip(result.ask ?? '', 600)}`)
          s.out(`answer${result.tools ? ` (after ${result.tools} tool calls)` : ''}:`)
          s.out(result.answer || '(no text)')
          if (result.truncated) s.out(`… ${answer.length - chars} more characters: ${step(s.env, 'show', result.name, { flag: `--chars ${answer.length}`, arg: `chars: ${answer.length}` })}`)
        }
        if (state === 'needs-input') s.out(`It is waiting for the person (a question or a permission). Only the person answers it.`)
        // Idle and the caller's: a harness left open after its answer is read sits there for nobody (owner, October 12).
        if (state === 'idle' && t.yours) s.out(closeHint(s.env, t.frame))
      }
      return EXIT.ok
    } finally { if (t?.remote) t.daemon.close(); o.daemon.close() }
  })
}

// ── wait ───────────────────────────────────────────────────────────────────────────────────────────

/** How far another machine's clock may be off from this one's, for what happened before or after a close. */
const CLOCK_SLACK_MS = 60_000

/** `closed`: stopped or gone because the caller closed it (`harness close`, the ledger's `Closed` line). */
type Settled = 'idle' | 'needs-input' | 'stopped' | 'gone' | 'closed' | 'timeout' | 'failed'

export function waitCommand(argv: readonly string[], deps: ClientDeps = {}): Promise<number> {
  return run(WAIT_USAGE, deps, wantsJson, argv, async (s) => {
    const { names, flags } = words(argv, { '--any': 'flag', '--timeout': 'value', '--json': 'flag' })
    const wanted = names.flatMap((n) => n.split(',')).map((n) => n.trim()).filter(Boolean)
    if (!wanted.length) throw new UsageError('Name the harness to wait for.')
    const timeoutMs = flags.has('--timeout') ? parseDuration(String(flags.get('--timeout'))) : DEFAULT_TIMEOUT_MS
    const o = await opened(s)
    const targets: Target[] = []
    /** Harnesses asked for that have not started (`Asked`): followed by their creation until they start, then waited on
     *  as any other. `harness new` answers an agent before an engine's install is done, and the harness starts by itself. */
    const following: Asked[] = []
    const gave = new Map<Asked, Settled>()
    try {
      for (const name of wanted) {
        let t: Target
        try { t = await target(s, o, name) } catch (error) {
          const asked = error instanceof AgentClientError && (error.code === 'NOT_STARTED' || error.code === 'NEVER_STARTED') ? askedNamed(o, name) : undefined
          if (!asked) throw error
          if (!following.includes(asked)) following.push(asked)
          if (asked.state === 'failed') gave.set(asked, 'failed')
          continue
        }
        if (!targets.some((x) => x.machineId === t.machineId && x.frame.id === t.frame.id)) targets.push(t)
      }
      /** Asks a creation how it stands: made, it joins the harnesses waited on, recorded as the caller's. */
      const follow = async (a: Asked): Promise<void> => {
        const here = a.row.creation.machineId === o.where.machineId
        const line = here ? o.daemon : await s.open(o.where, a.row.creation.machineId)
        let kept = false
        try {
          const status = await line.request('agent_create_status', { creationId: a.row.creation.creationId }, 8_000)
          const frame = (status.agent ?? {}) as Frame
          if (status.state === 'created' && typeof frame.id === 'string' && frame.id) {
            await recordMade(s, o.where, o.ledger, a.row, frame)
            targets.push({ daemon: line, frame: { ...frame, name: frame.name || a.row.creation.name }, machineId: a.row.creation.machineId,
              machine: here ? o.machine : a.row.creation.machineId.slice(0, 8), yours: true, remote: !here })
            following.splice(following.indexOf(a), 1)
            kept = true
            return
          }
          const now = askedOf(a.row, status)
          if (!now) gave.set(a, 'gone')
          else { a.state = now.state; a.detail = now.detail; if (now.state === 'failed') gave.set(a, 'failed') }
        } finally { if (!here && !kept) line.close() }
      }
      const deadline = timeoutMs > 0 ? s.now() + timeoutMs : Infinity
      const settled = new Map<Target, Settled>()
      const sawWorking = new Set<Target>()
      /** Idle looks in a row, on the same turn. */
      const idle = new Map<Target, { turn: string; looks: number }>()
      // Ended because the caller closed it: what it asked for, not a failure. A real Codex lead closed its harness and
      // then waited on it, as it had queued, and was answered "Failed (exit 4) · stopped · it was stopped". Not when its
      // conversation went on after that close (the person reopened it), or a minute past it on another machine's clock.
      const ended = (t: Target, state: 'stopped' | 'gone'): Settled => {
        const closedAt = o.caller ? o.ledger.closedBy(o.caller, { machineId: t.machineId, agentId: t.frame.id }) : null
        const active = Date.parse(t.frame.updatedAt ?? '')
        return closedAt !== null && !(active > closedAt + CLOCK_SLACK_MS) ? 'closed' : state
      }
      const look = async (t: Target, frames: Frame[]): Promise<Settled | null> => {
        const frame = frames.find((f) => f.id === t.frame.id)
        // Not live: stopped, or gone. Asked of the full list only then.
        if (!frame) return ended(t, (await list(t.daemon, true)).some((f) => f.id === t.frame.id) ? 'stopped' : 'gone')
        t.frame = frame
        if (frame.status === 'stopped') return ended(t, 'stopped')
        // The daemon says it is working: no need to read its screen.
        const screen = frame.activity?.state === 'working' ? 'working' : await inspect(t)
        if (screen === 'working') { sawWorking.add(t); idle.delete(t); return null }
        if (screen === 'needs-input') return 'needs-input'
        if (screen === 'draft' || (screen === null && stateOf(frame) !== 'idle')) { idle.delete(t); return null }
        // Idle, on two looks in a row with the same last turn: a message sent just before is typed within a look,
        // and the turn it starts shows as working. One idle look returned before it, on the turn before (#1180).
        const turn = await readLastTurn(t, 1)
        const key = turn ? `${turn.ask}\u0000${turn.tools}\u0000${turn.answer.length}` : ''
        const before = idle.get(t)
        const looks = before && before.turn === key ? before.looks + 1 : 1
        idle.set(t, { turn: key, looks })
        if (sawWorking.has(t)) return looks >= 2 ? 'idle' : null
        if (turn) return looks >= 2 && turn.answered ? 'idle' : null
        // Nothing asked of it at all, past its start: a harness started without a task has nothing to finish. A harness
        // just started with a task is idle for a moment before the task is typed.
        const age = frame.createdAt ? s.now() - Date.parse(frame.createdAt) : Infinity
        return age > STARTING_MS && looks >= QUIET_LOOKS ? 'idle' : null
      }
      for (;;) {
        for (const a of [...following]) {
          if (gave.has(a)) continue
          // Its machine out of reach for a moment (a timeout, a relay): asked again next round, as `ps` keeps it starting.
          await follow(a).catch((error) => {
            if (error instanceof AgentClientError) return
            throw error
          })
        }
        // One list per machine a round, however many harnesses are waited on there.
        const lists = new Map<Daemon, Promise<Frame[]>>()
        for (const t of targets) {
          if (settled.has(t)) continue
          const result = await (async () => {
            if (!lists.has(t.daemon)) lists.set(t.daemon, list(t.daemon, false))
            return look(t, await lists.get(t.daemon)!)
          })().catch((error) => {
            if (error instanceof AgentClientError && error.code === 'TIMEOUT') return null
            throw error
          })
          if (result) settled.set(t, result)
        }
        const total = targets.length + following.length
        const count = settled.size + gave.size
        const done = flags.has('--any') ? count > 0 : count === total
        if (done) break
        if (s.now() >= deadline) {
          for (const t of targets) if (!settled.has(t)) settled.set(t, 'timeout')
          for (const a of following) if (!gave.has(a)) gave.set(a, 'timeout')
          break
        }
        await s.sleep(Math.min(s.intervalMs, Math.max(0, deadline - s.now())))
      }
      const results: Array<{ name: string; id: string; state: Settled | 'installing' | 'starting'; detail?: string }> = [
        ...targets.filter((t) => settled.has(t)).map((t) => ({ name: t.frame.name ?? t.frame.id.slice(0, 8), id: t.frame.id, state: settled.get(t)! })),
        // Not started yet when the wait ended: said as what it waits for, which is what the agent waits on.
        ...following.filter((a) => gave.has(a)).map((a) => {
          const given = gave.get(a)!
          return { name: askedName(a), id: a.row.creation.creationId, state: given === 'timeout' && a.state !== 'failed' ? a.state : given, detail: a.detail }
        }),
      ]
      if (flags.has('--json')) s.out(JSON.stringify({ harnesses: results }, null, 1))
      else for (const r of results) {
        if (r.state === 'closed') { s.out(`${r.name}: closed (you closed it)`); continue }
        const next = r.state === 'idle' ? `read it: ${step(s.env, 'show', r.name)}`
          : r.state === 'needs-input' ? 'it waits for the person (a question or a permission); only the person answers it'
          : r.state === 'timeout' ? `still working; wait again or read it: ${step(s.env, 'show', r.name)}`
          : r.state === 'installing' || r.state === 'starting' ? `${askedLine(s.env, following.find((a) => a.row.creation.creationId === r.id)!)}`
          : r.state === 'failed' ? `it never started: ${r.detail || 'its machine refused it'}`
          // Harness closes one another agent started once it has sat idle half an hour (services/agentCleanup.ts): its
          // answer is still there to read.
          : r.state === 'stopped' ? `it was stopped; its answer is kept: ${step(s.env, 'show', r.name)}` : 'it is gone'
        s.out(`${r.name}: ${r.state} · ${next}`)
      }
      const states = results.map((r) => r.state)
      return states.some((x) => x === 'timeout' || x === 'installing' || x === 'starting') ? EXIT.timeout : states.includes('needs-input') ? EXIT.needsInput
        : states.some((x) => x === 'stopped' || x === 'gone' || x === 'failed') ? EXIT.stopped : EXIT.ok
    } finally {
      for (const t of targets) if (t.remote) t.daemon.close()
      o.daemon.close()
    }
  })
}

// ── close ──────────────────────────────────────────────────────────────────────────────────────────

export function closeCommand(argv: readonly string[], deps: ClientDeps = {}): Promise<number> {
  return run(CLOSE_USAGE, deps, wantsJson, argv, async (s) => {
    const { names, flags } = words(argv, { '--now': 'flag', '--json': 'flag' })
    if (names.length !== 1) throw new UsageError(names.length ? 'Close one harness at a time.' : 'Name the harness to close.')
    const o = await opened(s)
    let t: Target | null = null
    try {
      try { t = await target(s, o, names[0]) } catch (error) {
        // Asked for and not started: closing it is not starting it. Cancelled by its creation, which its machine takes only
        // before the launch is claimed (lib/agentCreationReceipt.ts `cancelIntent`).
        const asked = error instanceof AgentClientError && error.code === 'NOT_STARTED' ? askedNamed(o, names[0]) : undefined
        if (!asked) throw error
        const name = askedName(asked), here = asked.row.creation.machineId === o.where.machineId
        const line = here ? o.daemon : await s.open(o.where, asked.row.creation.machineId)
        try {
          const reply = await line.request('agent_create_cancel', { creationId: asked.row.creation.creationId }, 20_000)
          const refused = askedOf(asked.row, reply)
          if (reply.state === 'created' || reply.state === 'unconfirmed') {
            throw new AgentClientError('STARTING', `${name} is starting now, so it was not cancelled. Close it once it has: ${step(s.env, 'close', name)}.`)
          }
          if (refused?.state === 'failed') throw new AgentClientError('NEVER_STARTED', `${name} never started: ${refused.detail || 'its machine refused it'}. Nothing to close.`)
          if (reply.state !== 'cancelled') {
            throw new AgentClientError(typeof reply.error === 'string' ? reply.error : 'NOT_CANCELLED', `${name} could not be cancelled${typeof reply.error === 'string' ? ` (${reply.error})` : ''}. Check it with ${step(s.env, 'ps')}.`)
          }
        } finally { if (!here) line.close() }
        s.out(flags.has('--json') ? JSON.stringify({ name, id: asked.row.creation.creationId, cancelled: true }) : `Cancelled ${name} before it started.`)
        return EXIT.ok
      }
      const name = t.frame.name ?? t.frame.id.slice(0, 8)
      if (o.orphan) throw new AgentClientError('NOT_YOURS', ORPHAN)
      if (o.caller && o.caller.agentId === t.frame.id && t.machineId === o.where.machineId) {
        throw new AgentClientError('NOT_YOURS', 'That is your own harness. The person closes it.')
      }
      // An agent closes only what it started; the person, at a terminal, closes anything.
      if (o.caller && !t.yours) throw new AgentClientError('NOT_YOURS', `You did not start ${name}, so you may not close it. Only the person can.`)
      const reply = await t.daemon.request('agent_close', {
        agentId: t.frame.id, sessionId: t.frame.sessionId ?? '', createdAt: t.frame.createdAt ?? '', mode: flags.has('--now') ? 'now' : 'idle',
      }, 60_000)
      if (reply.error === 'SESSION_NOT_IDLE') {
        throw new AgentClientError('WORKING', `${name} is ${reply.activity === 'needs_input' ? 'waiting for the person' : 'working'}. Wait for it (${step(s.env, 'wait', name)}), or close it anyway with ${s.env[VIA_MCP_ENV] === '1' ? 'now: true' : '--now'}.`)
      }
      if (reply.error === 'AGENT_CHANGED') throw new AgentClientError('AGENT_CHANGED', `${name} changed while closing. Check it with ${step(s.env, 'show', name)}, then try again.`)
      // Its machine cannot read which conversation it is in just now, and closing it would lose that conversation. The
      // machine's own reason ("the native control descriptor type is unavailable") means nothing to the agent asking.
      if (reply.error === 'IDENTITY_UNAVAILABLE') {
        throw new AgentClientError('IDENTITY_UNAVAILABLE', `${name} was not closed: Harness cannot tell which conversation it is in right now, and closing it would lose that conversation. Try again in a moment.`)
      }
      if (reply.error) throw new AgentClientError(String(reply.error), typeof reply.detail === 'string' && reply.detail ? reply.detail : `Could not close ${name}.`)
      // Recorded for `wait`, which then says the caller closed it rather than that it stopped. The close is done either way.
      if (o.caller) {
        try { o.ledger.append({ at: s.now(), by: { machineId: o.caller.machineId, agentId: o.caller.agentId }, closed: { machineId: t.machineId, agentId: t.frame.id } }) }
        catch { /* `wait` then says it stopped */ }
      }
      // Closed while still starting, before its machine could read its conversation: there is none to keep.
      const kept = reply.withoutConversation !== true
      s.out(flags.has('--json') ? JSON.stringify({ name, id: t.frame.id, closed: true, ...(kept ? {} : { conversationKept: false }) })
        : kept ? `Closed ${name}. Its conversation is kept.` : `Closed ${name}. It was still starting, so no conversation was kept.`)
      return EXIT.ok
    } finally { if (t?.remote) t.daemon.close(); o.daemon.close() }
  })
}

// ── new, run by an agent ───────────────────────────────────────────────────────────────────────────

/**
 * Limits on starting harnesses (the design's "Limits"): runaway spawning is the risk, and every harness started is
 * the person's tokens. Four at once and one level down (owner, October 12: "be very careful about when to start a new
 * agent so we don't waste user token"): a harness another agent started does its work itself. They were eight and two.
 */
export const SPAWN_LIMITS = { livePerHarness: 4, livePerMachine: 40, depth: 1, perWindow: 20, windowMs: 10 * 60_000 } as const

/** Said to a harness another agent started when it runs `harness new`. */
export const DEPTH_REFUSAL = 'A harness another agent started may not start harnesses itself. Do the work yourself, or say in your answer what else is needed.'

/** How long a harness the caller started by a name stops it starting another by that name: a retry, not new work. */
export const DUPLICATE_WITHIN_MS = 10 * 60_000

/** A harness by machine and id, as the limits count the live ones. */
const memberKey = (machineId: string, agentId: string): string => `${machineId}/${agentId}`

/**
 * Why [caller] may not start another harness now, or null. [live] holds the live harnesses the limits count: this
 * machine's, and the caller's on the other machines it reached.
 */
export function spawnRefusal(caller: Caller, live: ReadonlySet<string>, ledger: Ledger, localMachineId: string, now: number, waiting: readonly Pending[] = []): string | null {
  // Its depth by the record, or by the core's row when the record has no line for it: rotated away, a write that failed,
  // or a start from another machine or from outside Harness, recorded only where the starter ran.
  if (Math.max(ledger.depthOf(caller), caller.startedByAgent ? 1 : 0) >= SPAWN_LIMITS.depth) return DEPTH_REFUSAL
  // Harnesses asked for and not started yet ([waiting]) count as running: each starts by itself once its engine is
  // installed, and an agent asking for more meanwhile would otherwise pass every limit until they all started at once.
  const mine = ledger.childrenOf(caller)
  const liveMine = new Set(mine.filter((row) => live.has(memberKey(row.child.machineId, row.child.agentId))).map((row) => memberKey(row.child.machineId, row.child.agentId)))
  const running = liveMine.size + waiting.length
  if (running >= SPAWN_LIMITS.livePerHarness) {
    return `You have ${running} harnesses running${waiting.length ? ' or starting' : ''}. Close one you are done with first (harness close <name>).`
  }
  const machineWide = new Set(ledger.all().filter((row) => row.child.machineId === localMachineId && live.has(memberKey(localMachineId, row.child.agentId))).map((row) => row.child.agentId))
  if (machineWide.size + waiting.filter((row) => row.creation.machineId === localMachineId).length >= SPAWN_LIMITS.livePerMachine) {
    return `Agents have ${machineWide.size} harnesses running on this machine, the most allowed. Close some first.`
  }
  if (mine.filter((row) => now - row.at < SPAWN_LIMITS.windowMs).length + waiting.filter((row) => now - row.at < SPAWN_LIMITS.windowMs).length >= SPAWN_LIMITS.perWindow) {
    return `You started ${SPAWN_LIMITS.perWindow} harnesses in 10 minutes. Wait, or work with the ones you have.`
  }
  return null
}

/** How long a harness started on another machine counts toward the limits when that machine cannot be asked. */
const UNREACHABLE_LIVE_MS = 24 * 60 * 60_000

/**
 * The live harnesses the limits count: this machine's, and those the caller started on other machines, asked of
 * each (a harness closed there frees its place: counted for a day whatever became of it, eight of them on another
 * machine refused every start for that day, and `close` did not help; the review of #1180). A machine that cannot be
 * asked has its last day's starts counted.
 */
async function liveFor(s: Setup, o: Opened, caller: Caller): Promise<Set<string>> {
  const live = new Set(o.frames.filter((f) => f.status === 'active').map((f) => memberKey(o.where.machineId, f.id)))
  const away = new Map<string, Started[]>()
  for (const row of o.ledger.childrenOf(caller)) {
    if (row.child.machineId === o.where.machineId || s.now() - row.at > STOPPED_WITHIN_MS) continue
    away.set(row.child.machineId, [...(away.get(row.child.machineId) ?? []), row])
  }
  await Promise.all([...away].map(async ([machineId, rows]) => {
    try {
      const daemon = await s.open(o.where, machineId)
      try {
        const reply = await daemon.request('agents_list', {}, 8_000)
        for (const f of Array.isArray(reply.agents) ? reply.agents as Frame[] : []) if (f.status === 'active') live.add(memberKey(machineId, f.id))
      } finally { daemon.close() }
    } catch {
      for (const row of rows) if (s.now() - row.at < UNREACHABLE_LIVE_MS) live.add(memberKey(machineId, row.child.agentId))
    }
  }))
  return live
}

/** How a next step names a harness: its name when that is a plain word or two, else its id's start. An unnamed
 *  harness is called by its session title, which is a sentence ("so we have built harness web,") that `wait`'s list
 *  of names splits at the comma. */
export function addressOf(caller: Caller): string {
  return /^[\w.-]+( [\w.-]+)?$/.test(caller.name) && caller.name.length <= 40 ? (caller.name.includes(' ') ? `"${caller.name}"` : caller.name) : caller.agentId.slice(0, 8)
}

/** A start refused before anything is asked of the machine. */
const refusing = (code: string, message: string): NewOrigin => ({
  check: async () => { throw new AgentClientError(code, message) }, prompt: (text) => text, created: async () => null, next: () => '',
})

/**
 * When an agent runs `harness new`, from its pane or from outside Harness: its limits, the header on its task, and the
 * record of it. Null for the person. A pane Harness made whose harness cannot be told is refused, never taken for the
 * person: a daemon that did not answer used to mean no limits, no header and no record (the review of #1180).
 */
export async function agentOrigin(deps: ClientDeps = {}, record: Rpc = messagesRpc): Promise<NewOrigin | null> {
  const s = setup(deps)
  const agentOutside = !!outsideCaller(s.env, '')
  if (!s.pane && !agentOutside) return null
  let o: Opened
  try { o = await opened(s) } catch (error) {
    // Out of reach is said as it is (a sandbox, or nothing running): "try again in a moment" was tried again in the
    // same sandbox.
    if (error instanceof AgentClientError && error.code === 'DAEMON_UNREACHABLE') return refusing(error.code, error.message)
    return s.where().harnessPane || agentOutside ? refusing('UNKNOWN_CALLER', 'Harness could not tell who is starting this. Try again in a moment.') : null
  }
  o.daemon.close()
  if (o.orphan) return refusing('NOT_YOURS', ORPHAN)
  const caller = o.caller
  if (!caller) return null
  // The person's say: the account's experiment, as the machine the agent runs on keeps it (Settings ▸ Experimental,
  // `harness settings`).
  if (!readAgentSettings(o.where.dataDir).agentsStartAgents) return refusing('TURNED_OFF', AGENTS_START_AGENTS_OFF)
  return {
    // A harness in a pane here: the new one is opened beside it in the windows. An agent outside Harness has no pane.
    ...(caller.outside ? {} : { parentAgentId: caller.agentId }),
    check: async () => {
      const refusal = spawnRefusal(caller, await liveFor(s, o, caller), o.ledger, o.where.machineId, s.now(),
        o.asked.filter((a) => a.state !== 'failed').map((a) => a.row))
      if (refusal) throw new AgentClientError('SPAWN_LIMIT', refusal)
    },
    existing: async (name, asking) => {
      if (!name?.trim()) return null
      const wanted = name.trim().toLowerCase()
      // The same name for the same agent on the same machine: a retry. Another machine or agent is other work.
      // A store harness (owner/name) is asked for by its id and recorded by the engine it runs on: the machine decides.
      const same = (machineId: string, engine?: string) => machineId === asking.machineId && (!engine || asking.engine.includes('/') || engine === asking.engine)
      // Still on its way: an agent whose call to `harness new` timed out (an MCP client's minute) and asked again got a
      // second harness for the same work once both launches went ahead.
      const asked = o.asked.filter((a) => a.state !== 'failed' && a.row.creation.name.toLowerCase() === wanted
        && same(a.row.creation.machineId, a.row.creation.engine)).at(-1)
      if (asked) {
        const called = asked.row.creation.name
        return { name: called, machineId: asked.row.creation.machineId, state: 'starting',
          note: `"${called}" is already starting: ${asked.state === 'installing' ? `Harness is installing ${engineName(asked.row.creation.engine)}` : asked.detail.replace(/\.$/, '') || 'it has not started yet'}. `
            + `It starts by itself; wait for it with ${step(s.env, 'wait', called)}. Do not start it again.` }
      }
      // Started by the caller a few minutes ago and running: the same retry, a little later.
      const engineOf = (row: Started) => row.child.machineId === o.where.machineId ? o.frames.find((f) => f.id === row.child.agentId)?.engine : undefined
      const recent = o.ledger.childrenOf(caller).filter((row) => s.now() - row.at < DUPLICATE_WITHIN_MS && row.child.name.toLowerCase() === wanted
        && same(row.child.machineId, engineOf(row)))
      if (!recent.length) return null
      const live = await liveFor(s, o, caller)
      const running = recent.findLast((row) => live.has(memberKey(row.child.machineId, row.child.agentId)))
      if (!running) return null
      // Under a minute is "just now": rounded up to a minute, a harness started two seconds earlier was "1 min ago".
      const called = running.child.name, age = s.now() - running.at
      const when = age < 60_000 ? 'just now' : `${Math.round(age / 60_000)} min ago`
      return { name: called, machineId: running.child.machineId, agentId: running.child.agentId, state: 'running',
        note: `"${called}" is already running: you started it ${when}. Wait for it with ${step(s.env, 'wait', called)} `
          + `or read it with ${step(s.env, 'show', called)}. Do not start it again; to start a new one by that name, close it first (${step(s.env, 'close', called)}).` }
    },
    pending: (machineId, creation) => {
      o.ledger.append({ at: s.now(), by: { machineId: caller.machineId, agentId: caller.agentId, name: caller.name, engine: caller.engine },
        creation: { machineId, ...creation }, depth: o.ledger.depthOf(caller) + 1 })
    },
    prompt: (text, machineId) => {
      // Said once, at the top: the task is from an agent, not the person (a teammate's tmux paste read as the
      // owner's). It reads the answer itself (`show`): an invitation to reply had the first eval's agent send its
      // whole report back as a message as well, which would land in the middle of the starter's own turn. Nor is the
      // new harness told to message it: being started by it gives no way to, only sharing a tab does (owner,
      // 2026-10-11: "Agent Messages off means off").
      const here = machineId === o.where.machineId
      const header = caller.outside
        ? `[from ${caller.name} outside Harness · ${o.machine}, the agent that started you. It reads your answer itself.]\n\n`
        : `[from ${caller.name} · ${engineName(caller.engine)} · ${o.machine}, the harness that started you. It reads your answer itself.]\n\n`
      if (header.length + text.length <= MAX_FIRST_PROMPT_CHARS) return header + text
      // A first message holds 2,000 characters (engineLaunch.ts), and a task an agent hands on is often longer: the
      // first eval's prompts were refused whole. The task goes in a file the new harness is told to read.
      if (!here) throw new AgentClientError('PROMPT_TOO_LONG', `A task for another machine holds at most ${MAX_FIRST_PROMPT_CHARS - header.length} characters. Shorten it.`)
      const dir = join(o.where.dataDir, 'agent-client', 'tasks')
      mkdirSync(dir, { recursive: true })
      const file = join(dir, `${new Date(s.now()).toISOString().slice(0, 10)}-${randomBytes(4).toString('hex')}.md`)
      writeFileSync(file, text, { mode: 0o600 })
      const lead = `Your task is longer than a first message holds. All of it is in ${file}: read the whole file before you start. It begins:\n\n`
      const room = MAX_FIRST_PROMPT_CHARS - header.length - lead.length - 1
      return `${header}${lead}${clip(text, room)}`
    },
    created: async (machineId, agent, creationId) => {
      const id = typeof agent.id === 'string' ? agent.id : ''
      if (!id) return null
      const name = typeof agent.name === 'string' ? agent.name : ''
      const row: Started = {
        at: s.now(),
        by: { machineId: caller.machineId, agentId: caller.agentId, name: caller.name, engine: caller.engine },
        child: { machineId, agentId: id, name, ...(creationId ? { creationId } : {}) },
        depth: o.ledger.depthOf(caller) + 1,
      }
      o.ledger.record(row)
      if (machineId === o.where.machineId) return null
      // The other machine keeps the line too: there the new harness's limits and depth start from it. Without it a
      // harness started on another machine was one the person started there, and a chain hopping between machines had
      // no depth at all (the review of #1180).
      try {
        await record({ port: o.where.port, dataDir: o.where.dataDir, machineId }, { action: 'started', row }, 10_000)
        return null
      } catch {
        return `${name || 'The harness'} runs on a machine whose Harness did not record who started it: there, its limits start from zero.`
      }
    },
    next: (agent) => {
      const at = addressOf({ machineId: '', agentId: String(agent.id ?? ''), name: String(agent.name ?? ''), engine: '' })
      return `Read it: ${step(s.env, 'show', at)} · wait for it: ${step(s.env, 'wait', at)}`
    },
  }
}
