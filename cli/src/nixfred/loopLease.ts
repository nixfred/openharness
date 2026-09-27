/**
 * Loops across a fleet: a lease so a scheduled job runs on exactly one machine, a defer policy so
 * a laptop on battery, with its lid shut, or with a busy GPU does not take it, quiet hours in
 * Fred's timezone, and a catch-up rule for a machine that wakes up after missing its slot.
 */
import type { MachineCapabilities } from '../lib/machineCapabilities.js'

export interface LeaseDeps {
  readFile(path: string): Promise<string>
  writeFile(path: string, data: string): Promise<void>
  now(): number
  dataDir: string
}

export interface Lease { jobKey: string; machineId: string; acquiredAt: number; expiresAt: number }

export class LoopLeaseStore {
  private readonly file: string
  constructor(private readonly deps: LeaseDeps) { this.file = `${deps.dataDir}/loop-leases.json` }

  private async load(): Promise<Record<string, Lease>> {
    try { return JSON.parse(await this.deps.readFile(this.file)) as Record<string, Lease> } catch { return {} }
  }
  private async save(leases: Record<string, Lease>): Promise<void> {
    await this.deps.writeFile(this.file, JSON.stringify(leases, null, 2) + '\n')
  }

  /** True when this machine now holds the lease. False when another machine holds an unexpired one. */
  async acquire(jobKey: string, machineId: string, ttlMs: number): Promise<{ ok: boolean; holder?: string; lease?: Lease }> {
    const now = this.deps.now()
    const leases = await this.load()
    const cur = leases[jobKey]
    if (cur && cur.expiresAt > now && cur.machineId !== machineId) return { ok: false, holder: cur.machineId }
    const lease: Lease = { jobKey, machineId, acquiredAt: now, expiresAt: now + ttlMs }
    leases[jobKey] = lease
    await this.save(leases)
    return { ok: true, lease }
  }

  async renew(jobKey: string, machineId: string, ttlMs: number): Promise<boolean> {
    const leases = await this.load()
    const cur = leases[jobKey]
    if (!cur || cur.machineId !== machineId) return false
    cur.expiresAt = this.deps.now() + ttlMs
    await this.save(leases)
    return true
  }

  async release(jobKey: string, machineId: string): Promise<boolean> {
    const leases = await this.load()
    const cur = leases[jobKey]
    if (!cur || cur.machineId !== machineId) return false
    delete leases[jobKey]
    await this.save(leases)
    return true
  }

  async expireStale(now = this.deps.now()): Promise<number> {
    const leases = await this.load()
    let n = 0
    for (const [k, l] of Object.entries(leases)) if (l.expiresAt <= now) { delete leases[k]; n++ }
    if (n) await this.save(leases)
    return n
  }

  async list(): Promise<Lease[]> { return Object.values(await this.load()) }
}

export interface LoopPolicy {
  allowOnBattery?: boolean
  allowLidClosed?: boolean
  allowGpuBusy?: boolean
  quietHours?: { start: number; end: number } // local hours, e.g. 23 to 7
  timeZone?: string
}

export const DEFAULT_LOOP_POLICY: Required<Omit<LoopPolicy, 'quietHours'>> & { quietHours: { start: number; end: number } } = {
  allowOnBattery: false, allowLidClosed: false, allowGpuBusy: false, quietHours: { start: 23, end: 7 }, timeZone: 'America/New_York',
}

export const GPU_BUSY_FOR_LOOPS_PCT = 60

/** Local hour (0-23) of `epochMs` in the policy timezone, without Date's host-TZ dependence. */
export function localHour(epochMs: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone, hour: 'numeric', hourCycle: 'h23' }).formatToParts(new Date(epochMs))
  const h = Number(parts.find((p) => p.type === 'hour')?.value ?? '0')
  return h === 24 ? 0 : h
}

export function inQuietHours(epochMs: number, q: { start: number; end: number }, timeZone: string): boolean {
  const h = localHour(epochMs, timeZone)
  return q.start <= q.end ? h >= q.start && h < q.end : h >= q.start || h < q.end
}

/** Milliseconds until quiet hours end, from `epochMs`, computed by stepping whole hours. */
export function msUntilQuietEnds(epochMs: number, q: { start: number; end: number }, timeZone: string): number {
  const hourMs = 60 * 60 * 1000
  let t = epochMs - (epochMs % hourMs) + hourMs
  for (let i = 0; i < 48 && inQuietHours(t, q, timeZone); i++) t += hourMs
  return t - epochMs
}

export interface DeferDecision { defer: boolean; reason?: string; retryAfterMs?: number }

export function shouldDeferLoop(caps: MachineCapabilities, policy: LoopPolicy = {}, now: number = caps.at): DeferDecision {
  const p = { ...DEFAULT_LOOP_POLICY, ...policy }
  if (!p.allowOnBattery && !caps.power.onAc) return { defer: true, reason: 'on battery', retryAfterMs: 15 * 60 * 1000 }
  if (!p.allowLidClosed && caps.lid === 'closed' && caps.power.batteryPct !== null) return { defer: true, reason: 'lid closed', retryAfterMs: 15 * 60 * 1000 }
  if (!p.allowGpuBusy && caps.gpus.some((g) => g.utilizationPct >= GPU_BUSY_FOR_LOOPS_PCT)) return { defer: true, reason: 'GPU busy', retryAfterMs: 5 * 60 * 1000 }
  if (inQuietHours(now, p.quietHours, p.timeZone)) return { defer: true, reason: `quiet hours ${p.quietHours.start}:00 to ${p.quietHours.end}:00 ${p.timeZone}`, retryAfterMs: msUntilQuietEnds(now, p.quietHours, p.timeZone) }
  return { defer: false }
}

/**
 * A machine that slept through its slot: run once now if the miss is recent, skip if it is older
 * than `maxAgeMs` (a day by default), never replay every missed slot.
 */
export function nextCatchUp(missedSince: number, now: number, maxAgeMs = 24 * 60 * 60 * 1000): { runNow: boolean; missedForMs: number; reason: string } {
  const missedForMs = Math.max(0, now - missedSince)
  if (missedForMs === 0) return { runNow: false, missedForMs, reason: 'nothing missed' }
  if (missedForMs > maxAgeMs) return { runNow: false, missedForMs, reason: 'missed slot is too old, waiting for the next one' }
  return { runNow: true, missedForMs, reason: 'catching up one missed slot' }
}
