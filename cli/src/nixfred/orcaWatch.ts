/**
 * Watch mode for live agent sessions this daemon did not start, with an answer path into Orca.
 *
 * Stock Harness tracks only the panes it created. A Claude or Codex session running anywhere else
 * (an Orca terminal, a plain terminal window) still fires the machine's hooks, but the hook script
 * returned before posting anything, because there was no tmux pane to bind. Watch mode keeps those
 * events: each becomes a roster row the app and the USB device show like any other agent, marked
 * external, never moved and never killed.
 *
 * Answers: when the row came from an Orca terminal (the hook forwards ORCA_TERMINAL_HANDLE and the
 * worktree id, never Orca's hook token), an answer given on the device or in the app is typed into
 * that terminal with the `orca` CLI. A row with a tmux pane keeps the stock tmux path. Nothing is ever
 * sent except as the result of an explicit answer, and every send is written to the audit journal.
 *
 * Off by default. `harness orca on` turns it on; `harness orca off` and HARNESS_ORCA_WATCH=0 turn it off.
 * Orca is by stablyai (https://github.com/stablyai/orca); this module only drives its public CLI.
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
}

const ENGINES = new Set<ExternalEngine>(['claude', 'codex'])
const EVENTS = new Set<ExternalEventName>(['SessionStart', 'UserPromptSubmit', 'Stop', 'StopFailure', 'SessionEnd', 'Notification'])
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const ORCA_HANDLE_RE = /^term_[0-9a-f-]{8,64}$/i
const TEXT_CLIP = 160

// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f]/g

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
  return s && !CONTROL_RE.test(s) ? s : undefined
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

export interface RoutableRow {
  agentId: string
  sessionId: string
  hosted?: string
  external?: { orca: OrcaRef | null } | null
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
  route: 'orca' | 'none'
  what: 'key' | 'text'
  value: string
  ok: boolean
  terminal?: string
}

/**
 * Splits terminal I/O between Orca (external rows with an Orca handle) and the daemon's own tmux path
 * (everything else, untouched). `answerDeps` is handed ONLY to the answer controller, so the one way
 * bytes reach an Orca terminal is an explicit answer; typing a new prompt into an external row is not
 * wired anywhere.
 */
export class ExternalTerminalRouter {
  readonly gate: ExternalCaptureGate
  readonly answerDeps: AnswerDeps

  constructor(private readonly deps: {
    resolve: (target: string) => RoutableRow | undefined
    orca: OrcaCli
    answersEnabled: () => boolean
    gate: ExternalCaptureGate
    fallback: AnswerDeps
    audit: (entry: SendAudit) => void
  }) {
    this.gate = deps.gate
    this.answerDeps = {
      capture: (target, lines) => this.capture(target, lines, false),
      sendText: (target, text) => this.send(target, 'text', text),
      sendKey: (target, key) => this.send(target, 'key', key),
      acquireControl: (sessionId, opts) => {
        const row = this.external(sessionId)
        // An Orca terminal has no lease to pin; the controller's own one-answer-at-a-time rule applies.
        if (row) return () => {}
        return deps.fallback.acquireControl ? deps.fallback.acquireControl(sessionId, opts) : () => {}
      },
    }
  }

  /** The row, when it is one of ours (external); undefined for every pane-backed row. */
  external(target: string): (RoutableRow & { external: { orca: OrcaRef | null } }) | undefined {
    const row = this.deps.resolve(target)
    return row && row.hosted === 'external' && row.external ? row as RoutableRow & { external: { orca: OrcaRef | null } } : undefined
  }

  /**
   * For upstream's native question steps (core/main.ts question controls, #1040): the engine's own navigation
   * decides each key and text, and for an external row they are typed into its Orca terminal (audited, and
   * refused with no terminal or answers off). Undefined for every pane-backed row: the stock write applies.
   */
  controlWrite(target: string): { text: (text: string) => Promise<boolean>; key: (key: string) => Promise<boolean> } | undefined {
    if (!this.external(target)) return undefined
    return { text: (text) => this.send(target, 'text', text), key: (key) => this.send(target, 'key', key) }
  }

  /** For the question watcher: external rows go through the gate. */
  watcherCapture(target: string, lines?: number): Promise<string | null> { return this.capture(target, lines, true) }

  private async capture(target: string, lines: number | undefined, gated: boolean): Promise<string | null> {
    const row = this.external(target)
    if (!row) return this.deps.fallback.capture(target, lines)
    const handle = row.external.orca?.terminal
    if (!handle) return null
    const read = () => this.deps.orca.readScreen(handle)
    return gated ? this.gate.capture(row.sessionId, read) : read()
  }

  private async send(target: string, what: 'key' | 'text', value: string): Promise<boolean> {
    const row = this.external(target)
    if (!row) return what === 'key' ? this.deps.fallback.sendKey(target, value) : this.deps.fallback.sendText(target, value)
    const handle = row.external.orca?.terminal
    const bytes = what === 'key' ? orcaKeyBytes(value) : value.replace(CONTROL_RE, '')
    let ok = false
    if (handle && bytes && this.deps.answersEnabled()) ok = await this.deps.orca.send(handle, bytes)
    this.deps.audit({ agentId: row.agentId, sessionId: row.sessionId, route: handle ? 'orca' : 'none', what, value: value.slice(0, 200), ok, ...(handle ? { terminal: handle } : {}) })
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
