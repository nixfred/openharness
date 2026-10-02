import { expect, it, vi } from 'vitest'
import { companionMemoryInference } from './companion.js'

it('waits for a certified selected Codex runtime and preserves foreground priority', async () => {
  const intelligence = { extractionStatus: async () => ({ state: 'ready' as const, agentId: 'companion', engine: 'codex', contextKey: 'selected' }),
    extract: vi.fn(async () => '{"proposals":[]}') }
  const capability = vi.fn(async () => ({ supported: false, version: 'untested' }))
  let busy = true
  const foreground = vi.fn((id: string) => id === 'companion' && busy)
  const inference = companionMemoryInference(intelligence, foreground, capability)
  expect(await inference.target()).toEqual({ state: 'unsupported' })
  expect(intelligence.extract).not.toHaveBeenCalled()
  capability.mockResolvedValue({ supported: true, version: '0.159.0' })
  expect(await inference.target()).toEqual({ state: 'ready', key: 'selected', foregroundBusy: true })
  expect(foreground).toHaveBeenLastCalledWith('companion')
  busy = false
  expect((await inference.target()).foregroundBusy).toBe(false)
  const options = { signal: new AbortController().signal, timeoutMs: 1000, contextKey: 'selected' }
  expect(await inference.run('evidence', options)).toBe('{"proposals":[]}')
  expect(intelligence.extract).toHaveBeenCalledExactlyOnceWith('evidence', options)
})

it('uses only the selected companion for foreground priority and waits when that binding is missing', async () => {
  const busyIds = new Set(['other-local-agent', 'remote-agent'])
  let agentId: string | undefined = 'companion'
  const capability = vi.fn(async () => ({ supported: true, version: '0.159.0' }))
  const inference = companionMemoryInference({ extractionStatus: async () => ({ state: 'ready', agentId,
    engine: 'codex', contextKey: 'selected' }), extract: async () => null }, id => busyIds.has(id), capability)
  expect((await inference.target()).foregroundBusy).toBe(false)
  busyIds.add('companion')
  expect((await inference.target()).foregroundBusy).toBe(true)
  agentId = undefined
  capability.mockClear()
  expect(await inference.target()).toEqual({ state: 'waiting' })
  expect(capability).not.toHaveBeenCalled()
})

it('checks OpenCode native compatibility without probing a different engine', async () => {
  const claude = vi.fn(), codex = vi.fn()
  const opencode = vi.fn(async () => ({ supported: false, version: '2.0.0' }))
  const inference = companionMemoryInference({ extractionStatus: async () => ({ state: 'ready', agentId: 'companion',
    engine: 'opencode', contextKey: 'native-binding' }), extract: async () => null }, () => false, codex, claude, opencode)
  expect(await inference.target()).toEqual({ state: 'unsupported' })
  opencode.mockResolvedValue({ supported: true, version: '1.18.34' })
  expect(await inference.target()).toEqual({ state: 'ready', key: 'native-binding', foregroundBusy: false })
  expect(codex).not.toHaveBeenCalled(); expect(claude).not.toHaveBeenCalled()
})
