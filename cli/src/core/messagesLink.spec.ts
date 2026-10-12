import { describe, expect, it, vi } from 'vitest'
import type { RegisteredSession } from '../lib/registry.js'
import { fakeCore } from '../testing/fakeCore.js'
import { MESSAGES_QUERIES } from './api.js'
import { askForMessages, createMessagesLink } from './messagesLink.js'

const agent = (agentId: string) => ({ agentId, sessionId: `s-${agentId}`, engine: 'claude', cwd: '/w' }) as RegisteredSession

describe('Agent Messages in its own process, as the core keeps it', () => {
  const link = (over: Parameters<typeof fakeCore>[0] = {}, now?: () => number) => {
    const notify = vi.fn(() => true)
    return { notify, link: createMessagesLink({ core: fakeCore(over), notify, now }) }
  }

  it('says a delivery may be written only while the process last said so, and not past when it said', () => {
    let clock = 1_000
    const { link: l } = link({}, () => clock)
    expect(l.port.canWrite('team:d1')).toBe(false)
    expect(l.answer('writable', { deliveries: { 'team:d1': 1_000 + 3_000, 'team:d2': 'soon' } })).toEqual({})
    expect(l.port.canWrite('team:d1')).toBe(true)
    expect(l.port.canWrite('team:d2')).toBe(false)
    clock += 3_000
    expect(l.port.canWrite('team:d1')).toBe(false)
    l.answer('writable', { deliveries: { 'team:d1': 99_999 } })
    expect(l.port.canWrite('team:d1')).toBe(true)
    // A report replaces the last whole.
    l.answer('writable', {})
    expect(l.port.canWrite('team:d1')).toBe(false)
  })

  it('reads the real clock by default', () => {
    const { link: l } = link()
    l.answer('writable', { deliveries: { 'team:d1': Date.now() + 60_000 } })
    expect(l.port.canWrite('team:d1')).toBe(true)
  })

  it('shows it the agents as the apps are shown them, and how this daemon is reached and whether it is signed in', async () => {
    let signedIn = true
    const { link: l } = link({
      agents: { live: () => [agent('a1')], displayName: (s) => `name of ${s.agentId}`, terminalAvailable: () => true, dsh: () => null },
      daemon: { command: `'node' 'cli.js'`, port: 18473, machineId: () => 'machine-7', autonomousEnv: 'prod' },
      account: { signedIn: () => signedIn },
    })
    expect(await l.answer('shown', {})).toEqual({ agents: [{ ...agent('a1'), displayName: 'name of a1', terminalAvailable: true, dshContext: null }] })
    expect(await l.answer('daemon', {})).toEqual({ command: `'node' 'cli.js'`, port: 18473, machineId: 'machine-7', autonomousEnv: 'prod', signedIn: true })
    signedIn = false
    expect(await l.answer('daemon', {})).toMatchObject({ signedIn: false })
  })

  it('reads the account\'s tabs for it, and nothing else of the backend', async () => {
    const backend = vi.fn(async () => ({ status: 200, body: { success: true, data: { tabs: [] } } }))
    const { link: l } = link({ account: { backend } })
    expect(await l.answer('backend', { method: 'GET', path: '/api/agent-messages' })).toEqual({ status: 200, body: { success: true, data: { tabs: [] } } })
    expect(backend.mock.calls).toEqual([['GET', '/api/agent-messages']])
    // An experiment may write the account's settings or read anything under /api/; Agent Messages reads its tabs.
    for (const asked of [{ method: 'PATCH', path: '/api/agent-messages' }, { method: 'GET', path: '/api/machines' }, { method: 'GET', path: '/api/agent-messages?all=1' }, {}]) {
      expect(await l.answer('backend', asked)).toEqual({ error: 'INVALID_REQUEST' })
    }
    expect(backend).toHaveBeenCalledOnce()
  })

  it('tells the windows its log changed, and nothing else', async () => {
    const windows = vi.fn()
    const { link: l } = link({ clients: { windows } })
    expect(await l.answer('windows', { frame: { type: 'messages_changed', payload: { tabId: 'app' }, extra: 1 } })).toEqual({})
    expect(windows.mock.calls).toEqual([[{ type: 'messages_changed', payload: { tabId: 'app' } }]])
    for (const frame of [undefined, { type: 'orchestrator_changed', payload: {} }, { type: 'agents_list', payload: {} }, { type: 'messages_changed' }, { type: 'messages_changed', payload: 'x' }]) {
      expect(await l.answer('windows', { frame })).toEqual({ error: 'INVALID_FRAME' })
    }
    expect(windows).toHaveBeenCalledOnce()
  })

  it('answers what it uses alone: never what an experiment acts on the core through', async () => {
    const create = vi.fn()
    const stop = vi.fn()
    const { link: l } = link({ agents: { create }, turns: { stop } })
    for (const query of ['create', 'stop_turn', 'observer_key', 'observer_send', 'live', 'agents', 'connector_vault']) {
      expect(await l.answer(query, { engine: 'claude', cwd: '/w', prompt: 'p', name: 'n', agentId: 'a1' })).toEqual({ error: 'UNKNOWN_QUERY' })
    }
    expect(create).not.toHaveBeenCalled()
    expect(stop).not.toHaveBeenCalled()
    expect([...MESSAGES_QUERIES].sort()).toEqual(['backend', 'daemon', 'shown', 'windows', 'writable'])
  })

  it('tells the process its switch changed here', () => {
    const { link: l, notify } = link()
    l.port.settingsChanged()
    expect(notify.mock.calls).toEqual([[{ type: 'service_event', payload: { kind: 'settings' } }]])
  })

  it('tells the process the desk changed, and no other notice', () => {
    const { link: l, notify } = link()
    l.notice({ type: 'desk_changed', revision: 7 })
    l.notice({ type: 'machines_changed', reason: 'renamed' })
    l.notice({ type: 'connectors_changed', revision: 1 })
    expect(notify.mock.calls).toEqual([[{ type: 'service_event', payload: { kind: 'notice', notice: { type: 'desk_changed', revision: 7 } } }]])
  })
})

describe('Agent Messages asked for as the core starts', () => {
  it('is asked for when it runs out of the core\'s process, which starts a process only under a master from before', () => {
    const want = vi.fn()
    expect(askForMessages(new Set(['search', 'messages']), want)).toBe(true)
    expect(want.mock.calls).toEqual([['messages']])
    expect(askForMessages(new Set(['search']), want)).toBe(false)
    expect(want).toHaveBeenCalledOnce()
  })
})
