/**
 * Mike Gannotti's five rules for a healthy Hermes fleet, as a check: isolate profiles, stop writers
 * before touching state.db, treat memory as a budget, doctor after every update, skip the fleet PONG.
 * One report per Hermes home, with a green/amber/red verdict the bar and the device can draw as an arc.
 * Injected deps: nothing here reads the real machine in tests.
 */
export interface HermesHealthDeps {
  listHomes(): Promise<string[]>
  stat(path: string): Promise<{ size: number; mtimeMs: number } | null>
  dirBytes(path: string): Promise<number>
  /** Process ids with the file open (lsof -t / fuser); empty when the tool is missing. */
  writers(path: string): Promise<number[]>
  hermesVersion(): Promise<string | null>
  readJson(path: string): Promise<unknown>
  writeJson(path: string, value: unknown): Promise<void>
  now(): number
  dataDir: string
  memoryBudgetBytes?: number
  dbBudgetBytes?: number
  staleAfterMs?: number
}

export type Verdict = 'green' | 'amber' | 'red'

export interface HermesHomeHealth {
  home: string
  profile: string
  dbBytes: number
  dbAgeMs: number | null
  writers: number
  memoryBytes: number
  findings: string[]
  verdict: Verdict
}

export interface HermesHealthReport {
  at: number
  version: string | null
  lastDoctor: { version: string; at: number } | null
  doctorStale: boolean
  homes: HermesHomeHealth[]
  verdict: Verdict
}

const DOCTOR_STAMP = 'hermes-doctor.json'
export const MEMORY_BUDGET_BYTES = 64 * 1024 * 1024
export const DB_BUDGET_BYTES = 512 * 1024 * 1024
export const STALE_AFTER_MS = 7 * 24 * 60 * 60 * 1000

function worse(a: Verdict, b: Verdict): Verdict { const rank = { green: 0, amber: 1, red: 2 }; return rank[b] > rank[a] ? b : a }

export async function hermesHealth(deps: HermesHealthDeps): Promise<HermesHealthReport> {
  const now = deps.now()
  const version = await deps.hermesVersion()
  let lastDoctor: { version: string; at: number } | null = null
  try {
    const raw = await deps.readJson(`${deps.dataDir}/${DOCTOR_STAMP}`) as { version?: unknown; at?: unknown } | null
    if (raw && typeof raw.version === 'string' && typeof raw.at === 'number') lastDoctor = { version: raw.version, at: raw.at }
  } catch { /* no stamp yet */ }
  const doctorStale = !!version && (!lastDoctor || lastDoctor.version !== version)
  const homes: HermesHomeHealth[] = []
  const seenDb = new Set<string>()
  for (const home of await deps.listHomes()) {
    const db = `${home.replace(/\/+$/, '')}/state.db`
    const st = await deps.stat(db)
    const findings: string[] = []
    let verdict: Verdict = 'green'
    const writers = await deps.writers(db)
    const memoryBytes = (await deps.dirBytes(`${home}/memory`)) + (await deps.dirBytes(`${home}/memories`))
    const profile = home.includes('/profiles/') ? home.slice(home.lastIndexOf('/') + 1) : 'default'
    if (seenDb.has(db)) { findings.push('shares a state.db with another home (profiles are not isolated)'); verdict = worse(verdict, 'red') }
    seenDb.add(db)
    if (writers.length >= 2) { findings.push(`${writers.length} processes have state.db open; stop writers before touching it`); verdict = worse(verdict, 'red') }
    if (st && st.size > (deps.dbBudgetBytes ?? DB_BUDGET_BYTES)) { findings.push(`state.db is ${(st.size / 1048576).toFixed(0)} MB`); verdict = worse(verdict, 'amber') }
    if (memoryBytes > (deps.memoryBudgetBytes ?? MEMORY_BUDGET_BYTES)) { findings.push(`memory is ${(memoryBytes / 1048576).toFixed(0)} MB, over budget`); verdict = worse(verdict, 'amber') }
    const dbAgeMs = st ? now - st.mtimeMs : null
    if (dbAgeMs !== null && dbAgeMs > (deps.staleAfterMs ?? STALE_AFTER_MS)) { findings.push(`no activity for ${Math.round(dbAgeMs / 86400000)} days`); verdict = worse(verdict, 'amber') }
    if (!st) { findings.push('no state.db yet'); verdict = worse(verdict, 'amber') }
    homes.push({ home, profile, dbBytes: st?.size ?? 0, dbAgeMs, writers: writers.length, memoryBytes, findings, verdict })
  }
  let overall: Verdict = homes.reduce<Verdict>((v, h) => worse(v, h.verdict), 'green')
  if (doctorStale) overall = worse(overall, 'amber')
  return { at: now, version, lastDoctor, doctorStale, homes, verdict: overall }
}

/** Record that `hermes doctor` was run on the current version. */
export async function stampHermesDoctor(deps: Pick<HermesHealthDeps, 'hermesVersion' | 'writeJson' | 'now' | 'dataDir'>): Promise<{ version: string | null; at: number }> {
  const version = await deps.hermesVersion()
  const stamp = { version: version ?? 'unknown', at: deps.now() }
  await deps.writeJson(`${deps.dataDir}/${DOCTOR_STAMP}`, stamp)
  return stamp
}

export function describeHermesHealth(r: HermesHealthReport): string[] {
  const lines = [`hermes ${r.version ?? 'not found'}: ${r.verdict}${r.doctorStale ? ' (doctor not run since this version)' : ''}`]
  for (const h of r.homes) {
    lines.push(`  ${h.verdict === 'green' ? '+' : h.verdict === 'amber' ? '~' : '!'} ${h.profile.padEnd(16)} db ${(h.dbBytes / 1048576).toFixed(1)} MB  writers ${h.writers}  memory ${(h.memoryBytes / 1048576).toFixed(1)} MB${h.findings.length ? '  ' + h.findings.join('; ') : ''}`)
  }
  return lines
}
