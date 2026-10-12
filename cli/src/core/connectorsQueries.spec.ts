import { describe, expect, it, vi } from 'vitest'
import { fakeCore } from '../testing/fakeCore.js'
import { answerConnectorsQuery } from './connectorsQueries.js'

describe('the connectors service\'s query to the core', () => {
  it('answers only the connectors service, and only `connector_vault`', async () => {
    const core = fakeCore()
    expect(await answerConnectorsQuery(core, 'messages', 'connector_vault', { op: 'read' })).toBeNull()
    expect(await answerConnectorsQuery(core, 'connectors', 'backend', { method: 'GET', path: '/api/desk' })).toBeNull()
    expect(core.account.backend).not.toHaveBeenCalled()
  })

  it('reads and writes the account\'s envelope through the core\'s sign-in, and nothing else of the backend', async () => {
    const core = fakeCore({ account: { backend: vi.fn(async () => ({ status: 200, body: { success: true, data: { revision: 2 } } })) } as never })
    expect(await answerConnectorsQuery(core, 'connectors', 'connector_vault', { op: 'read', path: '/api/desk' }))
      .toEqual({ status: 200, body: { success: true, data: { revision: 2 } } })
    await answerConnectorsQuery(core, 'connectors', 'connector_vault', { op: 'write', base: 2, envelope: { v: 1 }, extra: 'x' })
    expect(core.account.backend).toHaveBeenNthCalledWith(1, 'GET', '/api/connector-vault')
    expect(core.account.backend).toHaveBeenNthCalledWith(2, 'PUT', '/api/connector-vault', { base: 2, envelope: { v: 1 } })
  })

  it('has the gateway seal and open, and says why it could not', async () => {
    const core = fakeCore({ account: { connectorVault: {
      seal: vi.fn(async (plaintext: string) => { if (!plaintext) throw new Error('frozen'); return { sealed: plaintext } }),
      open: vi.fn(async (envelope: unknown) => ((envelope as { sealed?: string }).sealed ? { plaintext: 'p', complete: false } : null)),
    } } as never })
    expect(await answerConnectorsQuery(core, 'connectors', 'connector_vault', { op: 'seal', plaintext: 'x' })).toEqual({ envelope: { sealed: 'x' } })
    expect(await answerConnectorsQuery(core, 'connectors', 'connector_vault', { op: 'seal' })).toEqual({ error: 'frozen' })
    expect(await answerConnectorsQuery(core, 'connectors', 'connector_vault', { op: 'open', envelope: { sealed: 1 } })).toEqual({ plaintext: 'p', complete: false })
    expect(await answerConnectorsQuery(core, 'connectors', 'connector_vault', { op: 'open', envelope: {} })).toEqual({})
    expect(await answerConnectorsQuery(core, 'connectors', 'connector_vault', { op: 'drop' })).toEqual({ error: 'UNKNOWN_OP' })
  })
})
