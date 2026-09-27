import { describe, expect, it } from 'vitest'
import { listPins, pin, startRecording, stopRecording, toAsciicast, type RecorderDeps, type RecordingSidecar } from './sessionRecorder.js'

function fake(rawSize: () => number) {
  const files = new Map<string, string>()
  const calls: string[][] = []
  let t = 1_700_000_000_000
  const deps: RecorderDeps = {
    exec: async (cmd, args) => { calls.push([cmd, ...args]); return '' },
    writeFile: async (p, d) => { files.set(p, d) },
    readFile: async (p) => { const v = files.get(p); if (v === undefined) throw new Error('ENOENT'); return v },
    stat: async () => ({ size: rawSize() }),
    mkdir: async () => {},
    now: () => t,
  }
  return { deps, files, calls, tick: (ms: number) => { t += ms } }
}

describe('sessionRecorder', () => {
  it('starts with pipe-pane -o, pins with byte offsets, stops with a bare pipe-pane', async () => {
    let size = 0
    const { deps, calls, tick } = fake(() => size)
    const s = await startRecording(deps, { pane: '%7', agentId: 'a1', dataDir: '/data', cols: 100, rows: 30 })
    expect(calls[0]).toEqual(['tmux', 'pipe-pane', '-t', '%7', '-o', "cat >> '/data/recordings/a1/pane.raw'"])
    expect(s.rawFile).toBe('/data/recordings/a1/pane.raw')
    size = 1200; tick(3000)
    const p = await pin(deps, { agentId: 'a1', dataDir: '/data', label: 'tests green' })
    expect(p).toEqual({ at: 1_700_000_003_000, label: 'tests green', offsetBytes: 1200 })
    expect(await listPins(deps, { agentId: 'a1', dataDir: '/data' })).toEqual([p])
    size = 2000; tick(2000)
    const stopped = await stopRecording(deps, { agentId: 'a1', dataDir: '/data' })
    expect(calls.at(-1)).toEqual(['tmux', 'pipe-pane', '-t', '%7'])
    expect(stopped.stoppedAt).toBe(1_700_000_005_000)
    expect(stopped.stoppedOffsetBytes).toBe(2000)
    expect(await listPins(deps, { agentId: 'nobody', dataDir: '/data' })).toEqual([])
  })

  it('renders asciicast v2 with interpolated times and markers at pins', () => {
    const raw = 'a'.repeat(1000) + 'b'.repeat(1000)
    const sidecar: RecordingSidecar = { version: 1, agentId: 'a1', pane: '%1', rawFile: 'r', startedAt: 10_000, stoppedAt: 30_000, pins: [{ at: 20_000, label: 'half', offsetBytes: 1000 }], cols: 80, rows: 24 }
    const cast = toAsciicast(raw, sidecar, 500)
    const lines = cast.trim().split('\n').map((l) => JSON.parse(l))
    expect(lines[0]).toMatchObject({ version: 2, width: 80, height: 24, timestamp: 10, markers: [[10, 'half']] })
    // 4 output chunks of 500 bytes: offsets 0, 500, 1000, 1500 map to 0 s, 5 s, 10 s, 15 s
    expect(lines.slice(1, 5).map((e) => e[0])).toEqual([0, 5, 10, 15])
    expect(lines[1][1]).toBe('o')
    expect(lines[1][2]).toBe('a'.repeat(500))
    expect(lines[5]).toEqual([10, 'm', 'half'])
  })

  it('handles a recording with no pins and no stop time', () => {
    const sidecar: RecordingSidecar = { version: 1, agentId: 'a1', pane: '%1', rawFile: 'r', startedAt: 0, pins: [] }
    const lines = toAsciicast('hello', sidecar).trim().split('\n').map((l) => JSON.parse(l))
    expect(lines).toHaveLength(2)
    expect(lines[0].markers).toBeUndefined()
    expect(lines[1]).toEqual([0, 'o', 'hello'])
  })
})
