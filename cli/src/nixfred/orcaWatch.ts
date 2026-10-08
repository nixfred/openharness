/**
 * Watch mode for live agent sessions this daemon did not start, with an answer path into herdr and Orca.
 *
 * Stock Harness tracks only the panes it created. A Claude or Codex session running anywhere else
 * (an Orca terminal, a plain terminal window) still fires the machine's hooks, but the hook script
 * returned before posting anything, because there was no tmux pane to bind. Watch mode keeps those
 * events: each becomes a roster row the app and the USB device show like any other agent, marked
 * external, never moved and never killed.
 *
 * Answers: when the row came from a herdr pane (the hook forwards HERDR_PANE_ID, the workspace and tab
 * ids, and the herdr socket and binary paths) an answer given on the device or in the app is typed into
 * that pane with `herdr pane send-text` / `send-keys`; from an Orca terminal (ORCA_TERMINAL_HANDLE and
 * the worktree id, never Orca's hook token) it is typed with the `orca` CLI. Which one is chosen by the
 * innermost host in the engine's parent chain (`selectExternalHost`). A row with a tmux pane keeps the
 * stock tmux path. Nothing is ever sent except as the result of an explicit answer or prompt, and every
 * send is written to the audit journal.
 *
 * Off by default. `harness orca on` turns it on; `harness orca off` and HARNESS_ORCA_WATCH=0 turn it off.
 * Orca is by stablyai (https://github.com/stablyai/orca) and herdr is herdr.dev; this module only drives
 * their public CLIs.
 *
 * Pure apart from the injected exec and the small switch file, so it is tested without Orca present.
 */
import { execFile } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, readlinkSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { terminalLogicalKey } from '../lib/terminalBackendCoordinator.js'
import type { AttentionState } from '../lib/attention.js'

export type ExternalEngine = 'claude' | 'codex'
export type ExternalEventName = 'SessionStart' | 'UserPromptSubmit' | 'Stop' | 'StopFailure' | 'SessionEnd' | 'Notification'

export interface OrcaRef {
  /** Runtime-issued terminal handle (`term_...`), the only thing `orca terminal send` needs. */
  terminal: string
  worktree?: string
  tab?: string
  pane?: string
}

/** A herdr pane (herdr 0.9+). `pane` is what `herdr pane send-text|send-keys|read` take. */
export interface HerdrRef {
  pane: string
  workspace?: string
  tab?: string
  /** The herdr API socket the agent's own server listens on (HERDR_SOCKET_PATH). Absolute. */
  socket?: string
  /** The herdr binary that server runs (HERDR_BIN_PATH). Absolute, and named `herdr`. */
  bin?: string
}

/** Which multiplexer or IDE holds an external row, innermost first; null when none can be driven. */
export type ExternalHostKind = 'herdr' | 'orca' | 'tmux'

export interface ExternalHookEvent {
  engine: ExternalEngine
  event: ExternalEventName
  sessionId: string
  cwd: string | null
  title: string | null
  transcriptPath: string | null
  codexHome: string | null
  model: string | null
  prompt: string
  message: string
  notificationType: string
  callerPid: number | null
  orca: OrcaRef | null
  herdr: HerdrRef | null
}

const ENGINES = new Set<ExternalEngine>(['claude', 'codex'])
const EVENTS = new Set<ExternalEventName>(['SessionStart', 'UserPromptSubmit', 'Stop', 'StopFailure', 'SessionEnd', 'Notification'])
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const ORCA_HANDLE_RE = /^term_[0-9a-f-]{8,64}$/i
/** herdr workspace ids (`w4F`) and tab/pane ids (`w4F:t1`, `w4F:p1`). Shared with orcaReveal.ts. */
export const HERDR_ID_RE = /^[A-Za-z0-9]{1,16}(:[A-Za-z0-9]{1,16})?$/
export const HERDR_PANE_RE = /^[A-Za-z0-9]{1,16}:[A-Za-z0-9]{1,16}$/
const TEXT_CLIP = 160

// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f]/g
// eslint-disable-next-line no-control-regex
const PROMPT_CONTROL_RE = /[\u0000-\u0008\u000b-\u001f\u007f]/g

function str(v: unknown, max: number): string | null {
  if (typeof v !== 'string' || !v) return null
  return v.length > max ? null : v
}
function clean(v: unknown, max = TEXT_CLIP): string {
  return typeof v === 'string' ? v.replace(CONTROL_RE, '').slice(0, max) : ''
}
function absPath(v: unknown): string | null {
  const s = str(v, 4096)
  return s && s.startsWith('/') && !s.includes('\u0000') ? s : null
}
function opaqueId(v: unknown): string | undefined {
  const s = str(v, 512)
  return s && !new RegExp(CONTROL_RE.source).test(s) ? s : undefined
}
/** An absolute path with no control characters and no `..` segment. */
function safeAbsPath(v: unknown): string | undefined {
  const s = str(v, 1024)
  if (!s || !s.startsWith('/') || new RegExp(CONTROL_RE.source).test(s) || s.split('/').includes('..')) return undefined
  return s
}

/**
 * The herdr ids a hook or a process environment carries, validated: strict ids, absolute paths, a binary
 * that is called `herdr`. Anything else in the environment (tokens included) is never read. Null when
 * there is no usable pane id.
 */
export function parseHerdrRef(raw: unknown): HerdrRef | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const o = raw as Record<string, unknown>
  if (typeof o.pane !== 'string' || !HERDR_PANE_RE.test(o.pane)) return null
  const ref: HerdrRef = { pane: o.pane }
  if (typeof o.workspace === 'string' && HERDR_ID_RE.test(o.workspace) && !o.workspace.includes(':')) ref.workspace = o.workspace
  if (typeof o.tab === 'string' && HERDR_PANE_RE.test(o.tab)) ref.tab = o.tab
  const socket = safeAbsPath(o.socket); if (socket) ref.socket = socket
  const bin = safeAbsPath(o.bin); if (bin && bin.split('/').pop() === 'herdr') ref.bin = bin
  return ref
}

/** The same, read from a process environment (`HERDR_PANE_ID`, `HERDR_WORKSPACE_ID`, ...). */
export function herdrRefFromEnv(vars: Map<string, string> | Record<string, string | undefined>): HerdrRef | null {
  const get = (k: string): string | undefined => (vars instanceof Map ? vars.get(k) : vars[k])
  return parseHerdrRef({ pane: get('HERDR_PANE_ID'), workspace: get('HERDR_WORKSPACE_ID'), tab: get('HERDR_TAB_ID'), socket: get('HERDR_SOCKET_PATH'), bin: get('HERDR_BIN_PATH') })
}

/** Validate a body from `notify.mjs`'s external branch. Keeps only known fields; never keeps a token. */
export function parseExternalHook(raw: unknown): { ok: true; event: ExternalHookEvent } | { ok: false; reason: string } {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { ok: false, reason: 'body' }
  const b = raw as Record<string, unknown>
  if (!ENGINES.has(b.engine as ExternalEngine)) return { ok: false, reason: 'engine' }
  if (!EVENTS.has(b.event as ExternalEventName)) return { ok: false, reason: 'event' }
  if (typeof b.sessionId !== 'string' || !UUID_RE.test(b.sessionId)) return { ok: false, reason: 'session_id' }
  if (b.cwd !== undefined && b.cwd !== null && !absPath(b.cwd)) return { ok: false, reason: 'cwd' }
  let orca: OrcaRef | null = null
  if (b.orca && typeof b.orca === 'object') {
    const o = b.orca as Record<string, unknown>
    if (typeof o.terminal === 'string' && ORCA_HANDLE_RE.test(o.terminal)) {
      orca = { terminal: o.terminal }
      const worktree = opaqueId(o.worktree); if (worktree) orca.worktree = worktree
      const tab = opaqueId(o.tab); if (tab) orca.tab = tab
      const pane = opaqueId(o.pane); if (pane) orca.pane = pane
    }
  }
  const herdr = parseHerdrRef(b.herdr)
  const pid = typeof b.callerPid === 'number' && Number.isSafeInteger(b.callerPid) && b.callerPid > 1 ? b.callerPid : null
  return {
    ok: true,
    event: {
      engine: b.engine as ExternalEngine,
      event: b.event as ExternalEventName,
      sessionId: b.sessionId.toLowerCase(),
      cwd: absPath(b.cwd),
      title: clean(b.title, 200) || null,
      transcriptPath: absPath(b.transcriptPath),
      codexHome: absPath(b.codexHome),
      model: clean(b.model, 120) || null,
      prompt: clean(b.prompt),
      message: clean(b.message),
      notificationType: clean(b.notificationType, 40),
      callerPid: pid,
      orca,
      herdr,
    },
  }
}

/**
 * What a hook says about the row's attention. Null means "no change". Claude's Notification carries
 * a notification_type on current builds; older ones only have the message, so both are read.
 */
export function attentionForExternalEvent(e: ExternalHookEvent): { state: AttentionState; detail: string } | null {
  switch (e.event) {
    case 'SessionStart': return { state: 'idle', detail: 'watching' }
    case 'UserPromptSubmit': return { state: 'working', detail: e.prompt }
    case 'Stop': return { state: 'done', detail: '' }
    case 'StopFailure': return { state: 'failed', detail: 'engine ended the turn with an error' }
    case 'SessionEnd': return { state: 'offline', detail: '' }
    case 'Notification': {
      if (e.notificationType === 'permission_prompt' || /needs your permission/i.test(e.message)) return { state: 'permission', detail: e.message }
      if (e.notificationType === 'elicitation_dialog') return { state: 'waiting', detail: e.message }
      return null
    }
  }
}

/** Whether a Notification means a dialog is on screen right now (so the screen is worth reading fresh). */
export function notificationOpensDialog(e: ExternalHookEvent): boolean {
  const a = e.event === 'Notification' ? attentionForExternalEvent(e) : null
  return a?.state === 'permission' || a?.state === 'waiting'
}

// ── the switch ──────────────────────────────────────────────────────────────────────────────────

export interface OrcaWatchConfig {
  /** Register external sessions as roster rows. */
  enabled: boolean
  /** Deliver answers into Orca terminals. Only meaningful while enabled. */
  answers: boolean
  /** How often a working external row's screen may be read with no dialog hinted. 0 = never. */
  idleCaptureMs: number
  source: 'env' | 'file' | 'default'
}

export const ORCA_WATCH_FILE = 'orca-watch.json'
const DEFAULT_IDLE_CAPTURE_MS = 8_000

type Env = Record<string, string | undefined>
const flag = (v: string | undefined): boolean | null => (v === '1' || v === 'true' || v === 'on' ? true : v === '0' || v === 'false' || v === 'off' ? false : null)

export function readOrcaWatchConfig(dataDir: string, env: Env = process.env): OrcaWatchConfig {
  type SwitchFile = { enabled?: unknown; answers?: unknown }
  let file: SwitchFile | null = null
  try {
    const p = join(dataDir, ORCA_WATCH_FILE)
    if (existsSync(p)) {
      const parsed = JSON.parse(readFileSync(p, 'utf8')) as unknown
      if (parsed && typeof parsed === 'object') file = parsed as SwitchFile
    }
  } catch { file = null }
  const idle = Number(env.HARNESS_ORCA_IDLE_CAPTURE_MS)
  const idleCaptureMs = Number.isFinite(idle) && idle >= 0 ? idle : DEFAULT_IDLE_CAPTURE_MS
  const envOn = flag(env.HARNESS_ORCA_WATCH)
  const envAnswers = flag(env.HARNESS_ORCA_ANSWERS)
  const fileOn = file?.enabled === true
  const enabled = envOn ?? fileOn
  const answers = enabled && (envAnswers ?? (file ? file.answers !== false : envOn === true))
  const source = envOn !== null || envAnswers !== null ? 'env' : file ? 'file' : 'default'
  return { enabled, answers, idleCaptureMs, source }
}

export type OrcaSwitch = 'on' | 'off' | 'answers-on' | 'answers-off'

/** Persist a switch change (atomic rename) and return the effective config, env overrides included. */
export function applyOrcaWatchSwitch(dataDir: string, change: OrcaSwitch, env: Env = process.env): OrcaWatchConfig {
  const current = readOrcaWatchConfig(dataDir, {})
  const next = { enabled: current.enabled, answers: current.answers }
  if (change === 'on') { next.enabled = true; next.answers = true }
  if (change === 'off') { next.enabled = false; next.answers = false }
  if (change === 'answers-on') next.answers = true
  if (change === 'answers-off') next.answers = false
  mkdirSync(dataDir, { recursive: true })
  const p = join(dataDir, ORCA_WATCH_FILE)
  writeFileSync(`${p}.tmp`, JSON.stringify(next) + '\n', { mode: 0o600 })
  renameSync(`${p}.tmp`, p)
  return readOrcaWatchConfig(dataDir, env)
}

// ── the orca CLI ─────────────────────────────────────────────────────────────────────────────────

export type OrcaExec = (bin: string, args: string[], timeoutMs: number) => Promise<string>

export const defaultOrcaExec: OrcaExec = (bin, args, timeoutMs) => new Promise((resolve, reject) => {
  // argv, never a shell: answer text reaches orca as one literal argument.
  execFile(bin, args, { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => (err ? reject(err) : resolve(stdout)))
})

/** Where the `orca` binary is: HARNESS_ORCA_BIN, else PATH, else the usual per-user install spots. */
export function findOrcaBin(env: Env = process.env, exists: (p: string) => boolean = existsSync): string | null {
  if (env.HARNESS_ORCA_BIN) return exists(env.HARNESS_ORCA_BIN) ? env.HARNESS_ORCA_BIN : null
  const dirs = (env.PATH ?? '').split(':').filter(Boolean)
  if (env.HOME) dirs.push(join(env.HOME, 'bin'), join(env.HOME, '.local', 'bin'))
  dirs.push('/usr/local/bin', '/usr/bin')
  for (const d of dirs) { const p = join(d, 'orca'); if (exists(p)) return p }
  return null
}

export class OrcaCli {
  constructor(private readonly deps: { bin: string | null; exec?: OrcaExec; timeoutMs?: number }) {}

  get available(): boolean { return !!this.deps.bin }

  private async run(args: string[]): Promise<Record<string, unknown> | null> {
    if (!this.deps.bin) return null
    try {
      const out = await (this.deps.exec ?? defaultOrcaExec)(this.deps.bin, args, this.deps.timeoutMs ?? 5_000)
      const parsed = JSON.parse(out) as Record<string, unknown>
      return parsed && parsed.ok === true ? parsed : null
    } catch { return null }
  }

  /** The rendered screen (not the stacked stream), lines joined with newlines. */
  async readScreen(handle: string): Promise<string | null> {
    const r = await this.run(['terminal', 'read', '--terminal', handle, '--screen', '--json'])
    const tail = ((r?.result as { terminal?: { tail?: unknown } } | undefined)?.terminal?.tail)
    return Array.isArray(tail) ? tail.map((l) => (typeof l === 'string' ? l : '')).join('\n') : null
  }

  /** Write raw bytes into the terminal. No --enter: Enter is its own key, sent by the answer driver. */
  async send(handle: string, bytes: string): Promise<boolean> {
    const r = await this.run(['terminal', 'send', '--terminal', handle, '--text', bytes, '--json'])
    return (r?.result as { send?: { accepted?: unknown } } | undefined)?.send?.accepted === true
  }
}

const KEY_BYTES: Record<string, string> = {
  enter: '\r', escape: '\x1b', tab: '\t', backtab: '\x1b[Z', up: '\x1b[A', down: '\x1b[B', right: '\x1b[C', left: '\x1b[D',
  home: '\x1b[H', end: '\x1b[F', backspace: '\x7f', delete: '\x1b[3~', pageup: '\x1b[5~', pagedown: '\x1b[6~', space: ' ',
  'ctrl-u': '\x15', 'ctrl-w': '\x17',
}

/**
 * The answer driver's key names (tmux's: Enter, Down, BTab, 1...) as bytes for `orca terminal send`.
 * C-c and C-d are refused: watch mode never stops or ends a session it does not own.
 */
export function orcaKeyBytes(key: string): string | null {
  const logical = terminalLogicalKey(key)
  if (!logical || logical === 'ctrl-c' || logical === 'ctrl-d') return null
  if (/^[0-9]$/.test(logical)) return logical
  return KEY_BYTES[logical] ?? null
}

// ── the herdr CLI ────────────────────────────────────────────────────────────────────────────────

/**
 * The answer driver's key names (tmux's: Enter, Down, BTab, 1...) as herdr 0.9 `send-keys` names. herdr
 * parses keys with its keybinding grammar (config/keybinds.rs parse_key_combo): enter, esc, tab,
 * shift+tab, up/down/left/right, backspace, space, single characters and ctrl+<char>. It has no home,
 * end, delete or page keys, so those are refused rather than typed as text (send-text would paste them).
 * C-c and C-d are refused as for Orca: watch mode never stops or ends a session it does not own.
 */
const HERDR_KEYS: Record<string, string> = {
  enter: 'enter', escape: 'esc', tab: 'tab', backtab: 'shift+tab', up: 'up', down: 'down', left: 'left', right: 'right',
  backspace: 'backspace', space: 'space', 'ctrl-u': 'ctrl+u', 'ctrl-w': 'ctrl+w',
}
export function herdrKeyName(key: string): string | null {
  const logical = terminalLogicalKey(key)
  if (!logical || logical === 'ctrl-c' || logical === 'ctrl-d') return null
  if (/^[0-9]$/.test(logical)) return logical
  return HERDR_KEYS[logical] ?? null
}

/** One live herdr pane as `herdr pane get|list` report it (only the fields watch mode reads). */
export interface HerdrPaneInfo {
  pane: string
  workspace: string | null
  tab: string | null
  agent: string | null
  agentSession: string | null
}

export type HerdrExec = (bin: string, args: string[], env: NodeJS.ProcessEnv, timeoutMs: number) => Promise<string>

export const defaultHerdrExec: HerdrExec = (bin, args, env, timeoutMs) => new Promise((resolve, reject) => {
  // argv, never a shell: answer and prompt text reach herdr as one literal argument.
  execFile(bin, args, { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024, env }, (err, stdout) => (err ? reject(err) : resolve(String(stdout))))
})

function paneInfo(raw: unknown): HerdrPaneInfo | null {
  if (!raw || typeof raw !== 'object') return null
  const p = raw as Record<string, unknown>
  if (typeof p.pane_id !== 'string' || !HERDR_PANE_RE.test(p.pane_id)) return null
  const session = p.agent_session && typeof p.agent_session === 'object' ? (p.agent_session as Record<string, unknown>).value : null
  return {
    pane: p.pane_id,
    workspace: typeof p.workspace_id === 'string' ? p.workspace_id : null,
    tab: typeof p.tab_id === 'string' ? p.tab_id : null,
    agent: typeof p.agent === 'string' ? p.agent : null,
    agentSession: typeof session === 'string' ? session.toLowerCase() : null,
  }
}

/**
 * herdr's public CLI, always against the agent's OWN server: HERDR_SOCKET_PATH and the binary come from
 * the row (the agent's environment), never from the daemon's environment, whose HERDR_* would name
 * whatever herdr the daemon happened to be started from.
 */
export class HerdrCli {
  constructor(private readonly deps: { bin?: string | null; exec?: HerdrExec; timeoutMs?: number; env?: Env } = {}) {}

  /** The binary for a row: its own HERDR_BIN_PATH, else the daemon's `herdr` (HARNESS_HERDR_BIN, PATH). */
  binFor(ref: HerdrRef): string | null {
    if (ref.bin) return ref.bin
    if (this.deps.bin !== undefined) return this.deps.bin
    return findHerdrBin(this.deps.env ?? process.env)
  }

  private envFor(ref: HerdrRef): NodeJS.ProcessEnv {
    const base = Object.fromEntries(Object.entries(this.deps.env ?? process.env).filter(([k]) => !k.startsWith('HERDR_')))
    return ref.socket ? { ...base, HERDR_SOCKET_PATH: ref.socket } : base
  }

  private async run(ref: HerdrRef, args: string[]): Promise<string | null> {
    const bin = this.binFor(ref)
    if (!bin) return null
    try { return await (this.deps.exec ?? defaultHerdrExec)(bin, args, this.envFor(ref), this.deps.timeoutMs ?? 5_000) } catch { return null }
  }

  private async json(ref: HerdrRef, args: string[]): Promise<Record<string, unknown> | null> {
    const out = await this.run(ref, args)
    if (out === null) return null
    try {
      const parsed = JSON.parse(out) as { result?: unknown; error?: unknown }
      return parsed && !parsed.error && parsed.result && typeof parsed.result === 'object' ? parsed.result as Record<string, unknown> : null
    } catch { return null }
  }

  async paneGet(ref: HerdrRef): Promise<HerdrPaneInfo | null> {
    if (!HERDR_PANE_RE.test(ref.pane)) return null
    return paneInfo((await this.json(ref, ['pane', 'get', ref.pane]))?.pane)
  }

  async paneList(ref: Pick<HerdrRef, 'socket' | 'bin'>): Promise<HerdrPaneInfo[] | null> {
    const r = await this.json({ pane: 'x:x', ...ref }, ['pane', 'list'])
    if (!r || !Array.isArray(r.panes)) return null
    return r.panes.map(paneInfo).filter((p): p is HerdrPaneInfo => !!p)
  }

  /** Workspace and tab labels, for row names. */
  async labels(ref: Pick<HerdrRef, 'socket' | 'bin'>): Promise<{ workspaces: Map<string, string>; tabs: Map<string, string>; panes: HerdrPaneInfo[] } | null> {
    const at = { pane: 'x:x', ...ref }
    const [ws, tabs, panes] = await Promise.all([this.json(at, ['workspace', 'list']), this.json(at, ['tab', 'list']), this.paneList(ref)])
    if (!ws || !Array.isArray(ws.workspaces) || !panes) return null
    const label = (v: unknown): string | null => (typeof v === 'string' ? v.replace(CONTROL_RE, '').trim().slice(0, 60) || null : null)
    const workspaces = new Map<string, string>()
    for (const w of ws.workspaces as Array<Record<string, unknown>>) { const l = label(w.label); if (typeof w.workspace_id === 'string' && l) workspaces.set(w.workspace_id, l) }
    const tabMap = new Map<string, string>()
    for (const t of (Array.isArray(tabs?.tabs) ? tabs!.tabs : []) as Array<Record<string, unknown>>) { const l = label(t.label); if (typeof t.tab_id === 'string' && l) tabMap.set(t.tab_id, l) }
    return { workspaces, tabs: tabMap, panes }
  }

  /** The pane's text: the visible screen, or the last `lines` lines of scrollback when asked for history. */
  async read(ref: HerdrRef, lines?: number): Promise<string | null> {
    const args = lines && lines > 0
      ? ['pane', 'read', ref.pane, '--source', 'recent', '--lines', String(Math.min(1000, Math.floor(lines))), '--format', 'text']
      : ['pane', 'read', ref.pane, '--source', 'visible', '--format', 'text']
    const out = await this.run(ref, args)
    return out === null ? null : out.replace(/\n+$/, '')
  }

  /** Literal text (herdr bracket-pastes it when the pane asked for bracketed paste). No Enter. */
  async sendText(ref: HerdrRef, text: string): Promise<boolean> {
    return (await this.run(ref, ['pane', 'send-text', ref.pane, text])) !== null
  }

  /** One key by its herdr name (see herdrKeyName). */
  async sendKey(ref: HerdrRef, herdrKey: string): Promise<boolean> {
    return (await this.run(ref, ['pane', 'send-keys', ref.pane, herdrKey])) !== null
  }
}

/**
 * The row name herdr gives a session: its workspace label ("Blip:gus:herdr", "flea"), and when that
 * workspace holds more than one agent pane, the tab label too (or the pane id when the tab is only numbered).
 * The pane is found by session first (a moved pane keeps its session), then by the row's pane id.
 * Null when herdr has no label for it, so the stock name applies.
 */
export function herdrRowName(sessionId: string, ref: HerdrRef, labels: { workspaces: Map<string, string>; tabs: Map<string, string>; panes: HerdrPaneInfo[] }): string | null {
  const live = labels.panes.find((p) => p.agentSession === sessionId.toLowerCase()) ?? labels.panes.find((p) => p.pane === ref.pane)
  const ws = live?.workspace ?? ref.workspace
  const wsLabel = ws ? labels.workspaces.get(ws) : undefined
  if (!wsLabel) return null
  const agents = labels.panes.filter((p) => p.workspace === ws && (p.agent || p.agentSession))
  if (agents.length <= 1) return wsLabel
  const tab = live?.tab ?? ref.tab
  const tabLabel = tab ? labels.tabs.get(tab) : undefined
  if (tabLabel && !/^\d+$/.test(tabLabel)) return `${wsLabel} · ${tabLabel}`
  return `${wsLabel} · ${(live?.pane ?? ref.pane).split(':')[1]}`
}

/** Where a `herdr` binary is when the row did not say: HARNESS_HERDR_BIN, else PATH, else the usual spots. */
export function findHerdrBin(env: Env = process.env, exists: (p: string) => boolean = existsSync): string | null {
  if (env.HARNESS_HERDR_BIN) return exists(env.HARNESS_HERDR_BIN) ? env.HARNESS_HERDR_BIN : null
  const dirs = (env.PATH ?? '').split(':').filter(Boolean)
  if (env.HOME) dirs.push(join(env.HOME, '.local', 'bin'), join(env.HOME, 'bin'))
  dirs.push('/usr/local/bin', '/usr/bin')
  for (const d of dirs) { const p = join(d, 'herdr'); if (exists(p)) return p }
  return null
}

/**
 * Which host an external row's keys go to. The innermost multiplexer or IDE in the engine's parent chain
 * (orcaReveal.ts innermostHost) decides, because environment variables are inherited and cannot say
 * which one is nearest: a herdr started from an Orca terminal carries ORCA_* into every pane.
 *   - innermost herdr -> herdr, only if the row has a herdr pane; innermost Orca -> Orca, only with a handle.
 *   - innermost tmux -> nothing: a tmux in between has no pane id here, and typing into the outer host
 *     would land in whatever tmux pane is active.
 *   - unknown (no parent chain) -> whichever ref exists, herdr first (Fred's host since 2026-10-08).
 */
export function selectExternalHost(ext: { orca?: OrcaRef | null; herdr?: HerdrRef | null; inner?: ExternalHostKind | null } | null | undefined): 'herdr' | 'orca' | null {
  if (!ext) return null
  const inner = ext.inner ?? null
  if (inner === 'herdr') return ext.herdr ? 'herdr' : null
  if (inner === 'orca') return ext.orca ? 'orca' : null
  if (inner === 'tmux') return null
  return ext.herdr ? 'herdr' : ext.orca ? 'orca' : null
}

// ── capture gate ─────────────────────────────────────────────────────────────────────────────────

/**
 * One Orca screen read costs about a second of wall time and half a second of CPU (measured on gus),
 * and the question watcher polls every 1.5s. So a watcher read is fresh only while a Notification hook
 * has said a dialog is open; otherwise at most once per `idleCaptureMs`, replaying the last screen in
 * between. Replaying rather than returning null matters: the watcher reads null as "the dialog left".
 */
export class ExternalCaptureGate {
  private readonly hints = new Map<string, number>()
  private readonly last = new Map<string, { at: number; text: string | null }>()
  constructor(private readonly opts: { idleCaptureMs: number; hintTtlMs?: number; now?: () => number }) {}

  private now(): number { return (this.opts.now ?? Date.now)() }

  hint(sessionId: string): void { this.hints.set(sessionId, this.now()) }
  clear(sessionId: string): void { this.hints.delete(sessionId) }
  forget(sessionId: string): void { this.hints.delete(sessionId); this.last.delete(sessionId) }
  setIdleCaptureMs(ms: number): void { this.opts.idleCaptureMs = ms }

  hinted(sessionId: string): boolean {
    const at = this.hints.get(sessionId)
    if (at === undefined) return false
    if (this.now() - at > (this.opts.hintTtlMs ?? 10 * 60_000)) { this.hints.delete(sessionId); return false }
    return true
  }

  async capture(sessionId: string, read: () => Promise<string | null>): Promise<string | null> {
    const prev = this.last.get(sessionId)
    const fresh = this.hinted(sessionId)
      || (this.opts.idleCaptureMs > 0 && (!prev || this.now() - prev.at >= this.opts.idleCaptureMs))
    if (!fresh) return prev?.text ?? null
    const text = await read()
    this.last.set(sessionId, { at: this.now(), text })
    return text
  }
}

// ── routing ──────────────────────────────────────────────────────────────────────────────────────

/** What a row knows about where it runs: the Orca terminal, the herdr pane, and the innermost host. */
export interface ExternalRef {
  orca: OrcaRef | null
  herdr?: HerdrRef | null
  /** The innermost multiplexer/IDE in the engine's parent chain when the row was registered. */
  inner?: ExternalHostKind | null
}

export interface RoutableRow {
  agentId: string
  sessionId: string
  hosted?: string
  engine?: string
  external?: ExternalRef | null
}

export interface AnswerDeps {
  capture: (target: string, historyLines?: number) => Promise<string | null>
  sendText: (target: string, text: string) => Promise<boolean>
  sendKey: (target: string, key: string) => Promise<boolean>
  acquireControl?: (sessionId: string, opts?: { forAnswer?: boolean }) => (() => void) | null
}

export interface SendAudit {
  agentId: string
  sessionId: string
  route: 'orca' | 'herdr' | 'none'
  what: 'key' | 'text' | 'prompt'
  value: string
  ok: boolean
  /** The Orca terminal handle or the herdr pane id the bytes went to (or would have). */
  terminal?: string
  /** Why nothing was sent: answers_off, key_refused, pane_gone, pane_mismatch, no_host, send_failed. */
  reason?: string
}

type ExternalRow = RoutableRow & { external: ExternalRef }

/**
 * Splits terminal I/O between herdr panes and Orca terminals (external rows) and the daemon's own tmux
 * path (everything else, untouched). `answerDeps` is handed ONLY to the answer controller, `controlWrite`
 * only to upstream's question controls and `prompt` only to the session input's external branch, so the
 * only ways bytes reach an external terminal are an explicit answer or an explicit prompt.
 */
export class ExternalTerminalRouter {
  readonly gate: ExternalCaptureGate
  readonly answerDeps: AnswerDeps
  private readonly herdr: HerdrCli

  constructor(private readonly deps: {
    resolve: (target: string) => RoutableRow | undefined
    orca: OrcaCli
    herdr?: HerdrCli
    answersEnabled: () => boolean
    gate: ExternalCaptureGate
    fallback: AnswerDeps
    audit: (entry: SendAudit) => void
  }) {
    this.gate = deps.gate
    this.herdr = deps.herdr ?? new HerdrCli()
    this.answerDeps = {
      capture: (target, lines) => this.capture(target, lines, false),
      sendText: (target, text) => this.send(target, 'text', text),
      sendKey: (target, key) => this.send(target, 'key', key),
      acquireControl: (sessionId, opts) => {
        const row = this.external(sessionId)
        // An external terminal has no lease to pin; the controller's own one-answer-at-a-time rule applies.
        if (row) return () => {}
        return deps.fallback.acquireControl ? deps.fallback.acquireControl(sessionId, opts) : () => {}
      },
    }
  }

  /** The row, when it is one of ours (external); undefined for every pane-backed row. */
  external(target: string): ExternalRow | undefined {
    const row = this.deps.resolve(target)
    return row && row.hosted === 'external' && row.external ? row as ExternalRow : undefined
  }

  /** The host an external row's keys go to right now (selectExternalHost), or null for watch only. */
  hostOf(target: string): 'herdr' | 'orca' | null {
    return selectExternalHost(this.external(target)?.external)
  }

  /**
   * For upstream's native question steps (core/main.ts question controls, #1040): the engine's own navigation
   * decides each key and text, and for an external row they are typed into its herdr pane or Orca terminal
   * (audited, and refused with no host or answers off). Undefined for every pane-backed row: the stock write applies.
   */
  controlWrite(target: string): { text: (text: string) => Promise<boolean>; key: (key: string) => Promise<boolean> } | undefined {
    if (!this.external(target)) return undefined
    return { text: (text) => this.send(target, 'text', text), key: (key) => this.send(target, 'key', key) }
  }

  /** For the question watcher: external rows go through the gate. */
  watcherCapture(target: string, lines?: number): Promise<string | null> { return this.capture(target, lines, true) }

  /**
   * The live herdr pane of a row, checked before anything is read from or typed into it: herdr must report
   * this session in that pane (agent_session), or, when herdr reports no session at all, the same engine.
   * A pane that moved (herdr pane move) is found again by its session across the agent's own server.
   */
  private async herdrPane(row: ExternalRow): Promise<{ ref: HerdrRef } | { reason: 'pane_gone' | 'pane_mismatch' }> {
    const ref = row.external.herdr!
    const info = await this.herdr.paneGet(ref)
    if (info && info.agentSession === row.sessionId.toLowerCase()) return { ref }
    if (info && !info.agentSession && !!row.engine && info.agent === row.engine) return { ref }
    const found = (await this.herdr.paneList(ref))?.find((p) => p.agentSession === row.sessionId.toLowerCase())
    if (found) {
      const moved: HerdrRef = { ...ref, pane: found.pane, ...(found.workspace ? { workspace: found.workspace } : {}), ...(found.tab ? { tab: found.tab } : {}) }
      row.external.herdr = moved
      return { ref: moved }
    }
    return { reason: info ? 'pane_mismatch' : 'pane_gone' }
  }

  private async capture(target: string, lines: number | undefined, gated: boolean): Promise<string | null> {
    const row = this.external(target)
    if (!row) return this.deps.fallback.capture(target, lines)
    const host = selectExternalHost(row.external)
    let read: (() => Promise<string | null>) | null = null
    if (host === 'orca') { const handle = row.external.orca!.terminal; read = () => this.deps.orca.readScreen(handle) }
    if (host === 'herdr') {
      read = async () => {
        const pane = await this.herdrPane(row)
        return 'ref' in pane ? this.herdr.read(pane.ref, lines) : null
      }
    }
    if (!read) return null
    return gated ? this.gate.capture(row.sessionId, read) : read()
  }

  private async send(target: string, what: 'key' | 'text', value: string): Promise<boolean> {
    const row = this.external(target)
    if (!row) return what === 'key' ? this.deps.fallback.sendKey(target, value) : this.deps.fallback.sendText(target, value)
    return this.deliver(row, what, value)
  }

  /**
   * A typed or spoken prompt for an external row (core/input.ts `externalPrompt`): the text, then Enter,
   * into its herdr pane or Orca terminal. Same switch and same audit as an answer.
   */
  async prompt(target: string, text: string): Promise<boolean> {
    const row = this.external(target)
    if (!row) return false
    return this.deliver(row, 'prompt', text)
  }

  private async deliver(row: ExternalRow, what: 'key' | 'text' | 'prompt', value: string): Promise<boolean> {
    const host = selectExternalHost(row.external)
    let ok = false
    let reason: string | undefined
    let terminal: string | undefined = host === 'orca' ? row.external.orca!.terminal : host === 'herdr' ? row.external.herdr!.pane : undefined
    if (!host) reason = 'no_host'
    else if (!this.deps.answersEnabled()) reason = 'answers_off'
    else if (host === 'orca') {
      // A prompt goes as it was given (the pre-herdr path did the same); an answer's text loses control bytes.
      const bytes = what === 'key' ? orcaKeyBytes(value) : what === 'prompt' ? value : value.replace(CONTROL_RE, '')
      if (!bytes) reason = 'key_refused'
      else {
        ok = await this.deps.orca.send(terminal!, bytes)
        if (ok && what === 'prompt') ok = await this.deps.orca.send(terminal!, '\r')
        if (!ok) reason = 'send_failed'
      }
    } else {
      const key = what === 'key' ? herdrKeyName(value) : null
      if (what === 'key' && !key) reason = 'key_refused'
      else {
        const pane = await this.herdrPane(row)
        if (!('ref' in pane)) reason = pane.reason
        else {
          terminal = pane.ref.pane
          // A prompt keeps its line breaks (herdr bracket-pastes it, so they do not submit); an answer's text does not.
          const text = what === 'prompt' ? value.replace(PROMPT_CONTROL_RE, '') : value.replace(CONTROL_RE, '')
          ok = key ? await this.herdr.sendKey(pane.ref, key) : await this.herdr.sendText(pane.ref, text)
          if (ok && what === 'prompt') ok = await this.herdr.sendKey(pane.ref, 'enter')
          if (!ok) reason = 'send_failed'
        }
      }
    }
    this.deps.audit({ agentId: row.agentId, sessionId: row.sessionId, route: host ?? 'none', what, value: value.slice(0, 200), ok, ...(terminal ? { terminal } : {}), ...(reason ? { reason } : {}) })
    return ok
  }
}

// ── liveness ─────────────────────────────────────────────────────────────────────────────────────

export interface ProcInfo { comm: string; exe: string; ppid: number; start: string }
export type ProcReader = (pid: number) => ProcInfo | null

/** Linux /proc reader: comm, exe, parent and the start-time field (PID-reuse proof). Null elsewhere. */
export const readProc: ProcReader = (pid) => {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8')
    const close = stat.lastIndexOf(')')
    const comm = stat.slice(stat.indexOf('(') + 1, close)
    const fields = stat.slice(close + 2).trim().split(/\s+/)
    let exe = ''
    try { exe = readlinkSync(`/proc/${pid}/exe`) } catch { /* another user's, or gone */ }
    return { comm, exe, ppid: Number(fields[1]), start: fields[19] ?? '' }
  } catch { return null }
}

/**
 * The hook's parent is usually a throwaway shell (measured: claude -> bash -> node notify.mjs), so
 * the engine itself is found by walking up a few generations for a process named like the engine.
 */
export function findEngineAncestor(pid: number, engine: ExternalEngine, read: ProcReader = readProc): { pid: number; start: string } | null {
  let cur = pid
  for (let depth = 0; depth < 8 && cur > 1; depth++) {
    const info = read(cur)
    if (!info) return null
    const exeName = info.exe.split('/').pop() ?? ''
    if (info.comm === engine || exeName === engine) return { pid: cur, start: info.start }
    cur = info.ppid
  }
  return null
}

export function engineStillRunning(proc: { pid: number; start: string }, read: ProcReader = readProc): boolean {
  const info = read(proc.pid)
  return !!info && info.start === proc.start
}
