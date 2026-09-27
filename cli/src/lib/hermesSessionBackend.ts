/**
 * Hermes sessions that have no pane: Hermes Desktop bots, Bot Mode profiles, gateway and phone
 * sessions. Every Hermes surface writes to one SQLite store per home (`<home>/state.db`), so the
 * daemon can see them all by reading the stores, the way it already reads a pane-backed session's
 * messages. This poller lists every home, finds sessions with recent activity, registers each as a
 * HOSTED agent (a registry row with no terminal runtime, kept in memory only) and retires it when it
 * goes quiet or disappears. The existing per-session HermesReader then streams its turns.
 *
 * Injected everything, so the spec runs against a real sqlite3 store and a fake registry.
 */
import { sqliteReadAll } from './sqliteRead.js'
import { hermesDbPath, listHermesHomes } from '../engines/hermes/home.js'

export interface HostedHermesSession {
  sessionId: string
  hermesHome: string
  source: string
  cwd: string | null
  title: string | null
  lastActivityMs: number
}

export interface HostedRegistryLike {
  bySession(sessionId: string): { agentId: string; active: boolean; hosted?: string } | undefined
  registerHosted(input: { engine: 'hermes'; sessionId: string; hermesHome: string; source: string; cwd?: string | null; title?: string | null }): { agentId: string; isNew: boolean } | null
  setActive(agentId: string, active: boolean): boolean
  remove(sessionId: string): boolean
  hostedList(): Array<{ agentId: string; sessionId: string; active: boolean; hermesHome?: string | null }>
}

export interface HermesSessionBackendDeps {
  registry: HostedRegistryLike
  listHomes?: () => Promise<string[]>
  query?: (dbPath: string, sql: string, params: Array<string | number | null>) => Promise<Record<string, unknown>[] | null>
  now?: () => number
  intervalMs?: number
  idleMs?: number
  /** A newly registered hosted session; the caller attaches readers and announces it. */
  onNew?: (agentId: string, sessionId: string) => void
  /** A hosted session past the idle window (still in the store). */
  onRetired?: (agentId: string, sessionId: string) => void
  /** A hosted session no longer in any store. */
  onVanished?: (agentId: string, sessionId: string) => void
  log?: (line: string) => void
}

export const HERMES_SESSION_ID_RE = /^\d{8}_\d{6}_[0-9a-f]{6}$/
const DEFAULT_INTERVAL_MS = 5_000
const DEFAULT_IDLE_MS = 30 * 60 * 1000
const MAX_SESSIONS_PER_HOME = 200
/** Sources that belong to a pane-backed parent, never a hosted row of their own. */
const CHILD_SOURCES = new Set(['subagent', 'tool', 'delegation', 'delegate'])

/** Hermes stores epoch seconds (fractional) in `timestamp`; be tolerant of a store that used ms. */
export function toEpochMs(value: unknown): number {
  const n = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(n) || n <= 0) return 0
  return n > 1e12 ? n : n * 1000
}

export function isChildSource(source: string): boolean {
  return CHILD_SOURCES.has(source.toLowerCase())
}

/** Live sessions in one store: newest activity first, with the first user prompt as a title. */
export async function readLiveHermesSessions(
  dbPath: string,
  sinceMs: number,
  query: NonNullable<HermesSessionBackendDeps['query']>,
): Promise<Array<Omit<HostedHermesSession, 'hermesHome'>>> {
  const rows = await query(
    dbPath,
    'SELECT s.id AS id, s.source AS source, s.cwd AS cwd, MAX(m.timestamp) AS last, '
    + "(SELECT content FROM messages WHERE session_id = s.id AND role = 'user' ORDER BY id LIMIT 1) AS first "
    + 'FROM sessions s JOIN messages m ON m.session_id = s.id GROUP BY s.id ORDER BY last DESC LIMIT ?;',
    [MAX_SESSIONS_PER_HOME],
  )
  if (!rows) return []
  const out: Array<Omit<HostedHermesSession, 'hermesHome'>> = []
  for (const r of rows) {
    const id = typeof r.id === 'string' ? r.id : ''
    if (!HERMES_SESSION_ID_RE.test(id)) continue
    const lastActivityMs = toEpochMs(r.last)
    if (lastActivityMs < sinceMs) continue
    const source = typeof r.source === 'string' ? r.source : ''
    if (isChildSource(source)) continue
    const first = typeof r.first === 'string' ? r.first.replace(/\s+/g, ' ').trim() : ''
    out.push({
      sessionId: id,
      source,
      cwd: typeof r.cwd === 'string' && r.cwd ? r.cwd : null,
      title: first ? first.slice(0, 60) : null,
      lastActivityMs,
    })
  }
  return out
}

export class HermesSessionBackend {
  private timer: NodeJS.Timeout | null = null
  private polling = false
  private readonly listHomes: () => Promise<string[]>
  private readonly query: NonNullable<HermesSessionBackendDeps['query']>
  private readonly now: () => number

  constructor(private readonly deps: HermesSessionBackendDeps) {
    this.listHomes = deps.listHomes ?? (() => listHermesHomes())
    this.query = deps.query ?? (async (dbPath, sql, params) => {
      const result = await sqliteReadAll(dbPath, sql, params, { maxBuffer: 1 << 22 })
      return result.ok ? result.rows : null
    })
    this.now = deps.now ?? Date.now
  }

  start(): void {
    if (this.timer) return
    void this.poll()
    this.timer = setInterval(() => { void this.poll() }, this.deps.intervalMs ?? DEFAULT_INTERVAL_MS)
    this.timer.unref?.()
  }

  stop(): void {
    if (this.timer) { clearInterval(this.timer); this.timer = null }
  }

  /** One pass: register live sessions, retire idle ones, forget vanished ones. Safe to call directly. */
  async poll(): Promise<{ registered: string[]; retired: string[]; vanished: string[] }> {
    const summary = { registered: [] as string[], retired: [] as string[], vanished: [] as string[] }
    if (this.polling) return summary
    this.polling = true
    try {
      const idleMs = this.deps.idleMs ?? DEFAULT_IDLE_MS
      const sinceMs = this.now() - idleMs
      const homes = await this.listHomes()
      const seen = new Map<string, HostedHermesSession>()
      for (const home of homes) {
        let live: Array<Omit<HostedHermesSession, 'hermesHome'>> = []
        try { live = await readLiveHermesSessions(hermesDbPath(home), sinceMs, this.query) } catch { continue }
        for (const s of live) if (!seen.has(s.sessionId)) seen.set(s.sessionId, { ...s, hermesHome: home })
      }
      for (const s of seen.values()) {
        const existing = this.deps.registry.bySession(s.sessionId)
        if (existing) {
          // A pane-backed row (hooked from tmux) owns its session; a dormant hosted row wakes up.
          if (existing.hosted && !existing.active && this.deps.registry.setActive(existing.agentId, true)) this.deps.onNew?.(existing.agentId, s.sessionId)
          continue
        }
        const row = this.deps.registry.registerHosted({ engine: 'hermes', sessionId: s.sessionId, hermesHome: s.hermesHome, source: s.source, cwd: s.cwd, title: s.title })
        if (!row) continue
        summary.registered.push(s.sessionId)
        this.deps.log?.(`[hermes-store] hosted session ${s.sessionId.slice(0, 15)} (${s.source || 'unknown'}) in ${s.hermesHome}`)
        this.deps.onNew?.(row.agentId, s.sessionId)
      }
      // Retire what went quiet; forget what is gone from every store.
      const storeIds = await this.allSessionIds(homes)
      for (const hosted of this.deps.registry.hostedList()) {
        if (seen.has(hosted.sessionId)) continue
        if (storeIds && !storeIds.has(hosted.sessionId)) {
          this.deps.registry.remove(hosted.sessionId)
          summary.vanished.push(hosted.sessionId)
          this.deps.onVanished?.(hosted.agentId, hosted.sessionId)
        } else if (hosted.active) {
          this.deps.registry.setActive(hosted.agentId, false)
          summary.retired.push(hosted.sessionId)
          this.deps.onRetired?.(hosted.agentId, hosted.sessionId)
        }
      }
    } finally {
      this.polling = false
    }
    return summary
  }

  /** Every session id in every store, or null when a store could not be read (then nothing is forgotten). */
  private async allSessionIds(homes: string[]): Promise<Set<string> | null> {
    const ids = new Set<string>()
    for (const home of homes) {
      const rows = await this.query(hermesDbPath(home), 'SELECT id FROM sessions;', [])
      if (!rows) return null
      for (const r of rows) if (typeof r.id === 'string') ids.add(r.id)
    }
    return ids
  }
}

/** `HARNESS_HERMES_SESSIONS=0` turns the backend off; `HARNESS_HERMES_SESSION_IDLE_MS` sets the window. */
export function hermesSessionBackendConfig(envVars: NodeJS.ProcessEnv = process.env): { enabled: boolean; idleMs: number } {
  const enabled = envVars.HARNESS_HERMES_SESSIONS !== '0' && envVars.HARNESS_HERMES_SESSIONS?.toLowerCase() !== 'false'
  const idle = Number(envVars.HARNESS_HERMES_SESSION_IDLE_MS)
  return { enabled, idleMs: Number.isFinite(idle) && idle > 0 ? idle : DEFAULT_IDLE_MS }
}
