import { describe, expect, it } from 'vitest'
import { describeHermesHealth, hermesHealth, stampHermesDoctor, type HermesHealthDeps } from './hermesHealth.js'

const NOW = 1_800_000_000_000
function deps(over: Partial<HermesHealthDeps> & { files?: Record<string, { size: number; mtimeMs: number }>; dirs?: Record<string, number>; open?: Record<string, number[]>; stamp?: unknown } = {}): HermesHealthDeps & { written: Record<string, unknown> } {
  const written: Record<string, unknown> = {}
  return {
    written,
    listHomes: over.listHomes ?? (async () => ['/h/.hermes', '/h/.hermes/profiles/aiona', '/h/.hermes/profiles/peyton']),
    stat: async (p) => over.files?.[p] ?? null,
    dirBytes: async (p) => over.dirs?.[p] ?? 0,
    writers: async (p) => over.open?.[p] ?? [],
    hermesVersion: over.hermesVersion ?? (async () => '0.9.4'),
    readJson: async () => { if (over.stamp === undefined) throw new Error('ENOENT'); return over.stamp },
    writeJson: async (p, v) => { written[p] = v },
    now: () => NOW,
    dataDir: '/data',
  }
}

describe('hermesHealth', () => {
  it('is green when every profile is isolated, quiet, small and doctored', async () => {
    const r = await hermesHealth(deps({
      files: { '/h/.hermes/state.db': { size: 1e6, mtimeMs: NOW - 1000 }, '/h/.hermes/profiles/aiona/state.db': { size: 2e6, mtimeMs: NOW - 5000 }, '/h/.hermes/profiles/peyton/state.db': { size: 3e6, mtimeMs: NOW - 5000 } },
      stamp: { version: '0.9.4', at: NOW - 3600_000 },
    }))
    expect(r.verdict).toBe('green')
    expect(r.doctorStale).toBe(false)
    expect(r.homes.map((h) => h.profile)).toEqual(['default', 'aiona', 'peyton'])
  })
  it('flags two writers as red, a fat memory folder as amber, and a version without a doctor run', async () => {
    const r = await hermesHealth(deps({
      files: { '/h/.hermes/state.db': { size: 1e6, mtimeMs: NOW }, '/h/.hermes/profiles/aiona/state.db': { size: 1e6, mtimeMs: NOW }, '/h/.hermes/profiles/peyton/state.db': { size: 1e6, mtimeMs: NOW } },
      open: { '/h/.hermes/profiles/aiona/state.db': [101, 202] },
      dirs: { '/h/.hermes/profiles/peyton/memory': 90 * 1024 * 1024 },
      stamp: { version: '0.9.3', at: NOW - 86400_000 },
    }))
    expect(r.doctorStale).toBe(true)
    const aiona = r.homes.find((h) => h.profile === 'aiona')!
    expect(aiona.verdict).toBe('red')
    expect(aiona.findings[0]).toMatch(/2 processes have state.db open/)
    const peyton = r.homes.find((h) => h.profile === 'peyton')!
    expect(peyton).toMatchObject({ verdict: 'amber', memoryBytes: 90 * 1024 * 1024 })
    expect(r.verdict).toBe('red')
    expect(describeHermesHealth(r)[0]).toBe('hermes 0.9.4: red (doctor not run since this version)')
  })
  it('calls out a missing store, staleness, and the doctor stamp writes the current version', async () => {
    const r = await hermesHealth(deps({
      listHomes: async () => ['/h/.hermes', '/h/.hermes/profiles/new'],
      files: { '/h/.hermes/state.db': { size: 10, mtimeMs: NOW - 10 * 86400_000 } },
      stamp: { version: '0.9.4', at: NOW },
    }))
    expect(r.homes[0]!.findings).toEqual(['no activity for 10 days'])
    expect(r.homes[1]!.findings).toEqual(['no state.db yet'])
    const d = deps()
    expect(await stampHermesDoctor(d)).toEqual({ version: '0.9.4', at: NOW })
    expect(d.written['/data/hermes-doctor.json']).toEqual({ version: '0.9.4', at: NOW })
  })
})
