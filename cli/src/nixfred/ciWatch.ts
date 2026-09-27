/**
 * CI-failure wake. An agent that opened a pull request should hear about a failing check once, with
 * the failing log's tail, and hear nothing while checks are green or still running. Pure: `gh` and
 * the clock are injected; the daemon decides how to deliver the message (a turn into the agent's pane).
 */
export interface CiCheck { name: string; state: 'pass' | 'fail' | 'pending' | 'skipping' | 'cancel' | string; link?: string; bucket?: string }

export interface CiWatchDeps {
  /** `gh pr checks <ref> --json name,state,link,bucket` for a repo path. */
  prChecks(cwd: string, branch: string): Promise<CiCheck[]>
  /** Best-effort tail of the failing run's log, empty when unavailable. */
  failedLog(cwd: string, check: CiCheck): Promise<string>
  now(): number
}

export interface CiWatchTarget { agentId: string; agentName: string; cwd: string; branch: string }

export interface CiWake { agentId: string; branch: string; failed: CiCheck[]; message: string; at: number }

const LOG_TAIL_LINES = 40

export class CiWatcher {
  /** branch -> set of check names already announced as failed (until they pass again). */
  private readonly announced = new Map<string, Set<string>>()

  constructor(private readonly deps: CiWatchDeps) {}

  /** Poll one agent's branch. Returns a wake only for checks that newly failed since the last poll. */
  async poll(t: CiWatchTarget): Promise<CiWake | null> {
    let checks: CiCheck[]
    try { checks = await this.deps.prChecks(t.cwd, t.branch) } catch { return null }
    const key = `${t.cwd}::${t.branch}`
    const seen = this.announced.get(key) ?? new Set<string>()
    this.announced.set(key, seen)
    const failed = checks.filter((c) => c.state === 'fail' || c.bucket === 'fail')
    // A check that passes again is forgotten, so its next failure is news again.
    for (const c of checks) if (c.state === 'pass' || c.bucket === 'pass') seen.delete(c.name)
    const fresh = failed.filter((c) => !seen.has(c.name))
    if (!fresh.length) return null
    for (const c of fresh) seen.add(c.name)
    const parts: string[] = [`CI failed on branch ${t.branch}: ${fresh.map((c) => c.name).join(', ')}.`]
    for (const c of fresh.slice(0, 2)) {
      let log = ''
      try { log = await this.deps.failedLog(t.cwd, c) } catch { log = '' }
      const tail = log.split('\n').filter((l) => l.trim()).slice(-LOG_TAIL_LINES).join('\n')
      if (tail) parts.push(`--- ${c.name} (last ${LOG_TAIL_LINES} lines) ---\n${tail}`)
      if (c.link) parts.push(`Run: ${c.link}`)
    }
    parts.push('Fix the failure on this branch, run the tests locally, and push. Do not merge.')
    return { agentId: t.agentId, branch: t.branch, failed: fresh, message: parts.join('\n'), at: this.deps.now() }
  }

  forget(cwd: string, branch: string): void { this.announced.delete(`${cwd}::${branch}`) }
}

/** Parse `gh pr checks --json` output defensively. */
export function parsePrChecks(json: string): CiCheck[] {
  try {
    const raw = JSON.parse(json) as unknown
    if (!Array.isArray(raw)) return []
    return raw.filter((r): r is Record<string, unknown> => !!r && typeof r === 'object').map((r) => ({
      name: String(r.name ?? r.workflow ?? 'check'),
      state: String(r.state ?? r.status ?? 'pending').toLowerCase(),
      link: typeof r.link === 'string' ? r.link : undefined,
      bucket: typeof r.bucket === 'string' ? r.bucket : undefined,
    }))
  } catch { return [] }
}
