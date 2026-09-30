/**
 * nixfred watch mode, part two: find Claude sessions already running in Orca terminals without waiting
 * for a hook.
 *
 * Claude Code reads its hooks once, when a session starts or resumes. A session started before
 * `harness start` wrote the notify hook never reports, and after any daemon restart the in-memory
 * external rows are gone until each session speaks again. Both left Fred's Orca agents invisible.
 *
 * Every live Claude process writes `~/.claude/sessions/<pid>.json` (pid, sessionId, cwd, procStart),
 * and an Orca terminal puts ORCA_TERMINAL_HANDLE in the process environment. Together they are enough
 * to register the row. Sessions with no hook get their working/idle state from transcript activity.
 */
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'

export interface DiscoveredSession {
  pid: number
  sessionId: string
  cwd: string | null
  transcriptPath: string | null
  orca: { terminal: string; worktree?: string; tab?: string; pane?: string }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const ORCA_HANDLE_RE = /^term_[0-9a-f-]{8,64}$/i

export interface DiscoveryFs {
  listSessionFiles(dir: string): string[]
  readText(path: string): string | null
  /** NUL-separated environment of a live pid, or null when unreadable or gone. */
  environ(pid: number): string | null
  /** Field 22 of /proc/<pid>/stat, or null when the pid is gone. */
  procStart(pid: number): string | null
  exists(path: string): boolean
}

export const nodeDiscoveryFs: DiscoveryFs = {
  listSessionFiles: (dir) => { try { return readdirSync(dir).filter((f) => /^\d+\.json$/.test(f)).map((f) => join(dir, f)) } catch { return [] } },
  readText: (p) => { try { return readFileSync(p, 'utf8') } catch { return null } },
  environ: (pid) => { try { return readFileSync(`/proc/${pid}/environ`, 'latin1') } catch { return null } },
  procStart: (pid) => {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, 'utf8')
      // comm can hold spaces and parens; fields after the last ')' are fixed. starttime is field 22.
      return stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19] ?? null
    } catch { return null }
  },
  exists: (p) => existsSync(p),
}

/** Claude's project folder name for a cwd: every character outside [A-Za-z0-9-] becomes '-'. */
export function claudeProjectSlug(cwd: string): string {
  return cwd.replace(/[^A-Za-z0-9-]/g, '-')
}

export function discoverOrcaClaudes(claudeHome: string, fs: DiscoveryFs = nodeDiscoveryFs): DiscoveredSession[] {
  const out: DiscoveredSession[] = []
  for (const file of fs.listSessionFiles(join(claudeHome, 'sessions'))) {
    let meta: Record<string, unknown>
    try { meta = JSON.parse(fs.readText(file) ?? '') as Record<string, unknown> } catch { continue }
    const pid = typeof meta.pid === 'number' && Number.isSafeInteger(meta.pid) && meta.pid > 1 ? meta.pid : null
    const sessionId = typeof meta.sessionId === 'string' && UUID_RE.test(meta.sessionId) ? meta.sessionId.toLowerCase() : null
    if (!pid || !sessionId) continue
    if (meta.kind !== undefined && meta.kind !== 'interactive') continue
    // A reused pid must not resurrect a dead session: the start time has to match what Claude recorded.
    const start = fs.procStart(pid)
    if (!start) continue
    if (typeof meta.procStart === 'string' && meta.procStart !== start) continue
    const env = fs.environ(pid)
    if (!env) continue
    const vars = new Map<string, string>()
    for (const kv of env.split('\u0000')) {
      const i = kv.indexOf('=')
      if (i > 0 && kv.startsWith('ORCA_')) vars.set(kv.slice(0, i), kv.slice(i + 1))
    }
    const terminal = vars.get('ORCA_TERMINAL_HANDLE')
    if (!terminal || !ORCA_HANDLE_RE.test(terminal)) continue
    const cwd = typeof meta.cwd === 'string' && meta.cwd.startsWith('/') ? meta.cwd : null
    const guess = cwd ? join(claudeHome, 'projects', claudeProjectSlug(cwd), `${sessionId}.jsonl`) : null
    const orca: DiscoveredSession['orca'] = { terminal }
    const worktree = vars.get('ORCA_WORKTREE_ID'); if (worktree) orca.worktree = worktree
    const tab = vars.get('ORCA_TAB_ID'); if (tab) orca.tab = tab
    const pane = vars.get('ORCA_PANE_KEY'); if (pane) orca.pane = pane
    out.push({ pid, sessionId, cwd, transcriptPath: guess && fs.exists(guess) ? guess : null, orca })
  }
  return out
}

/** Seconds since the transcript last changed, or null. Used only for sessions that send no hooks. */
export function transcriptAgeSec(path: string | null, now = Date.now()): number | null {
  if (!path) return null
  try { return (now - statSync(path).mtimeMs) / 1000 } catch { return null }
}
