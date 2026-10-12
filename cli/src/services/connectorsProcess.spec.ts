import { afterEach, describe, expect, it, vi } from 'vitest'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { runServiceProcess, type ServiceProcessOptions } from './process.js'
import { runConnectorsService } from './connectorsProcess.js'
import type { ConnectorsDeps } from './connectors.js'
import type { CoreApi } from '../core/api.js'

// The real default reaches a real socket: never in a test.
vi.mock('./process.js', () => ({ runServiceProcess: vi.fn(() => ({ stop: vi.fn() })) }))

describe('connected services in their own process', () => {
  afterEach(() => vi.clearAllMocks())

  it('answers connectors with the same handler as in the core\'s process', async () => {
    let options: ServiceProcessOptions | null = null
    runConnectorsService({
      dataDir: '/data', socketPath: '/data/daemon-1.sock', machineId: 'm', token: 't',
      run: (given) => { options = given; return { stop: vi.fn() } },
      start: () => ({ connectors: async () => ({ connections: [] }) }),
    })
    expect(options).toMatchObject({ name: 'connectors', socketPath: '/data/daemon-1.sock', machineId: 'm', token: 't' })
    expect(await options!.requests.connectors!({ action: 'list' }, { local: true, owner: true })).toEqual({ connections: [] })
  })

  it('asks the core for the account\'s sealed connections, and hears the notices that change them', async () => {
    let options: ServiceProcessOptions | null = null
    let given: { api: CoreApi, overrides: Partial<ConnectorsDeps> } | null = null
    runConnectorsService({
      dataDir: '/data', socketPath: '/data/daemon-1.sock', machineId: 'm', token: 't',
      run: (o) => { options = o; return { stop: vi.fn() } },
      start: (api, overrides = {}) => { given = { api, overrides }; return { connectors: async () => ({}) } },
    })
    const port = given!.overrides.vaultPort!
    // No core yet: the backend reads as unreachable.
    expect(await port.read()).toBeNull()
    const query = vi.fn(async (_query: string, payload: Record<string, unknown>) =>
      payload.op === 'read' ? { status: 200, body: { success: true, data: { revision: 2, envelope: null } } } : {})
    options!.onConnected!({ query } as never)
    expect(await port.read()).toEqual({ revision: 2, envelope: null })
    expect(query).toHaveBeenCalledWith('connector_vault', { op: 'read' })

    const heard = vi.fn()
    const stop = given!.api.account.onNotice(heard)
    await options!.onEvent!({ kind: 'notice', notice: { type: 'connectors_changed', revision: 3 } })
    await options!.onEvent!({ kind: 'notice' })
    await options!.onEvent!({ kind: 'something_else', notice: { type: 'desk_changed', revision: 1 } })
    expect(heard).toHaveBeenCalledTimes(1)
    expect(heard).toHaveBeenCalledWith({ type: 'connectors_changed', revision: 3 })
    stop()
    await options!.onEvent!({ kind: 'notice', notice: { type: 'connectors_changed', revision: 4 } })
    expect(heard).toHaveBeenCalledTimes(1)

    options!.onDisconnected!()
    expect(await port.read()).toBeNull()
  })

  it('runs as a real service by default', () => {
    // The real start opens the bridge: on a free port, in a throwaway home.
    const home = mkdtempSync(join(tmpdir(), 'connectors-process-'))
    vi.stubEnv('HOME', home)
    vi.stubEnv('HARNESS_CONNECTIONS_PORT', '0')
    vi.stubEnv('PATH', '')
    try {
      runConnectorsService({ dataDir: '/data', socketPath: '/data/daemon-1.sock', machineId: 'm', token: 't' })
      expect(runServiceProcess).toHaveBeenCalledWith(expect.objectContaining({ name: 'connectors', requests: { connectors: expect.any(Function) } }))
    } finally { vi.unstubAllEnvs(); rmSync(home, { recursive: true, force: true }) }
  })
})
