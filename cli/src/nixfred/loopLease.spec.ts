import { describe, expect, it } from 'vitest'
import type { MachineCapabilities } from '../lib/machineCapabilities.js'
import { LoopLeaseStore, inQuietHours, localHour, msUntilQuietEnds, nextCatchUp, shouldDeferLoop, type LeaseDeps } from './loopLease.js'

function store(startNow: number) {
  const files = new Map<string, string>()
  let now = startNow
  const deps: LeaseDeps = {
    readFile: async (p) => { const v = files.get(p); if (v === undefined) throw new Error('ENOENT'); return v },
    writeFile: async (p, d) => { files.set(p, d) },
    now: () => now, dataDir: '/data',
  }
  return { s: new LoopLeaseStore(deps), files, tick: (ms: number) => { now += ms } }
}

describe('LoopLeaseStore', () => {
  it('lets one machine hold a lease, refuses another until expiry, allows renew and release', async () => {
    const { s, tick } = store(1000)
    expect((await s.acquire('nightly-update', 'gus', 5000)).ok).toBe(true)
    expect(await s.acquire('nightly-update', 'vic', 5000)).toEqual({ ok: false, holder: 'gus' })
    expect((await s.acquire('nightly-update', 'gus', 5000)).ok).toBe(true)
    expect(await s.renew('nightly-update', 'vic', 5000)).toBe(false)
    expect(await s.renew('nightly-update', 'gus', 5000)).toBe(true)
    tick(6000)
    expect((await s.acquire('nightly-update', 'vic', 5000)).ok).toBe(true)
    expect(await s.release('nightly-update', 'gus')).toBe(false)
    expect(await s.release('nightly-update', 'vic')).toBe(true)
    expect(await s.list()).toEqual([])
  })

  it('expires stale leases', async () => {
    const { s, tick } = store(0)
    await s.acquire('a', 'gus', 100)
    await s.acquire('b', 'gus', 10_000)
    tick(500)
    expect(await s.expireStale()).toBe(1)
    expect((await s.list()).map((l) => l.jobKey)).toEqual(['b'])
  })
})

// 2026-01-15T04:30:00Z is 23:30 the previous evening in New York (EST, UTC-5).
const nyLateNight = Date.UTC(2026, 0, 15, 4, 30)
// 2026-07-15T13:00:00Z is 09:00 in New York (EDT, UTC-4).
const nyMorning = Date.UTC(2026, 6, 15, 13, 0)

const caps = (over: Partial<MachineCapabilities> = {}): MachineCapabilities => ({
  at: nyMorning, hostname: 'gus', cpu: { cores: 8, load1: 1, load5: 1 }, gpus: [{ name: 'g', vramTotalMb: 12000, vramUsedMb: 1000, utilizationPct: 5 }],
  power: { onAc: true, batteryPct: 90 }, thermal: { maxC: 50 }, lid: 'open', toolchains: {}, ...over,
})

describe('quiet hours in America/New_York', () => {
  it('computes the local hour across DST', () => {
    expect(localHour(nyLateNight, 'America/New_York')).toBe(23)
    expect(localHour(nyMorning, 'America/New_York')).toBe(9)
    expect(localHour(Date.UTC(2026, 6, 15, 4, 0), 'America/New_York')).toBe(0)
  })
  it('handles a window that wraps midnight', () => {
    expect(inQuietHours(nyLateNight, { start: 23, end: 7 }, 'America/New_York')).toBe(true)
    expect(inQuietHours(nyMorning, { start: 23, end: 7 }, 'America/New_York')).toBe(false)
    expect(inQuietHours(nyMorning, { start: 8, end: 10 }, 'America/New_York')).toBe(true)
  })
  it('measures time until quiet hours end', () => {
    // 23:30 to 07:00 is 7.5 hours.
    expect(msUntilQuietEnds(nyLateNight, { start: 23, end: 7 }, 'America/New_York')).toBe(7.5 * 60 * 60 * 1000)
  })
})

describe('shouldDeferLoop', () => {
  it('runs on a healthy plugged-in machine in the daytime', () => {
    expect(shouldDeferLoop(caps())).toEqual({ defer: false })
  })
  it('defers on battery, lid, busy GPU and quiet hours, in that order', () => {
    expect(shouldDeferLoop(caps({ power: { onAc: false, batteryPct: 50 } })).reason).toBe('on battery')
    expect(shouldDeferLoop(caps({ lid: 'closed' })).reason).toBe('lid closed')
    expect(shouldDeferLoop(caps({ lid: 'closed', power: { onAc: true, batteryPct: null } })).defer).toBe(false)
    expect(shouldDeferLoop(caps({ gpus: [{ name: 'g', vramTotalMb: 1, vramUsedMb: 0, utilizationPct: 80 }] })).reason).toBe('GPU busy')
    const quiet = shouldDeferLoop(caps({ at: nyLateNight }))
    expect(quiet.defer).toBe(true)
    expect(quiet.reason).toContain('quiet hours 23:00 to 7:00 America/New_York')
    expect(quiet.retryAfterMs).toBe(7.5 * 60 * 60 * 1000)
  })
  it('honours policy overrides', () => {
    expect(shouldDeferLoop(caps({ at: nyLateNight, power: { onAc: false, batteryPct: 50 } }), { allowOnBattery: true, quietHours: { start: 1, end: 2 } })).toEqual({ defer: false })
  })
})

describe('nextCatchUp', () => {
  it('runs one missed slot if recent, skips if stale', () => {
    const now = 10_000_000
    expect(nextCatchUp(now, now).runNow).toBe(false)
    expect(nextCatchUp(now - 60_000, now)).toMatchObject({ runNow: true, missedForMs: 60_000 })
    expect(nextCatchUp(now - 2 * 24 * 60 * 60 * 1000, now).runNow).toBe(false)
  })
})
