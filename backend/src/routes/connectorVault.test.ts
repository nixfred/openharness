import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import Fastify, { type FastifyInstance } from 'fastify'
const mocks = vi.hoisted(() => ({
  prisma: { connectorVault: { findUnique: vi.fn(), updateMany: vi.fn(), create: vi.fn() } },
  changed: vi.fn(), auth: vi.fn(),
}))
vi.mock('../lib/prisma.js', () => ({ prisma: mocks.prisma }))
vi.mock('../lib/bus.js', () => ({ publishConnectorsChanged: mocks.changed }))
vi.mock('../lib/ssoAuth.js', async original => ({ ...await original<typeof import('../lib/ssoAuth.js')>(), authenticateAccessToken: mocks.auth }))
import { connectorVaultRoutes } from './connectorVault.js'
import { registerAuthMiddleware } from '../middlewares/authMiddleware.js'
import { errorHandler } from '../middlewares/errorHandler.js'

const user = { sub: 'u1', email: 'd@example.com', role: 'user', autonomousEnv: 'prod' as const }
const envelope = (ct: string) => ({ v: 1, sender: 'pubA', eph: 'eph', nonce: 'n', ct, keys: { pubA: 'k1', pubB: 'k2' }, sig: 'sig' })

describe('connector vault routes', () => {
  let app: FastifyInstance
  beforeEach(async () => {
    vi.resetAllMocks()
    mocks.auth.mockResolvedValue(user)
    mocks.changed.mockResolvedValue(1)
    app = Fastify(); app.setErrorHandler(errorHandler); registerAuthMiddleware(app, mocks.auth)
    await app.register(connectorVaultRoutes); await app.ready()
  })
  afterEach(async () => { await app.close() })
  const auth = { authorization: 'Bearer fixture' }
  const put = (body: unknown) => app.inject({ method: 'PUT', url: '/api/connector-vault', headers: auth, payload: body as any })

  it('answers no envelope for an account that has none', async () => {
    mocks.prisma.connectorVault.findUnique.mockResolvedValue(null)
    const res = await app.inject({ method: 'GET', url: '/api/connector-vault', headers: auth })
    expect(res.json()).toEqual({ success: true, data: { revision: 0, envelope: null } })
  })

  it('creates the row on the first write and tells every computer of the account', async () => {
    mocks.prisma.connectorVault.findUnique.mockResolvedValue(null)
    mocks.prisma.connectorVault.updateMany.mockResolvedValue({ count: 0 })
    mocks.prisma.connectorVault.create.mockResolvedValue({})
    const res = await put({ base: 0, envelope: envelope('ct1') })
    expect(res.json().data).toEqual({ written: true, revision: 1, envelope: envelope('ct1') })
    expect(mocks.prisma.connectorVault.create).toHaveBeenCalledWith({ data: { userId: 'u1', revision: 1, envelope: envelope('ct1') } })
    expect(mocks.changed).toHaveBeenCalledWith('u1', { revision: 1 })
  })

  it('writes nothing over a newer revision, and answers that one for the daemon to merge into', async () => {
    mocks.prisma.connectorVault.findUnique.mockResolvedValue({ revision: 4, envelope: envelope('ct4') })
    const res = await put({ base: 3, envelope: envelope('mine') })
    expect(res.json().data).toEqual({ written: false, revision: 4, envelope: envelope('ct4') })
    expect(mocks.prisma.connectorVault.updateMany).not.toHaveBeenCalled()
    expect(mocks.changed).not.toHaveBeenCalled()
  })

  it('loses a race on the compare-and-set and says so', async () => {
    mocks.prisma.connectorVault.findUnique
      .mockResolvedValueOnce({ revision: 4, envelope: envelope('ct4') })
      .mockResolvedValueOnce({ revision: 5, envelope: envelope('ct5') })
    mocks.prisma.connectorVault.updateMany.mockResolvedValue({ count: 0 })
    const res = await put({ base: 4, envelope: envelope('mine') })
    expect(res.json().data).toEqual({ written: false, revision: 5, envelope: envelope('ct5') })
    expect(mocks.prisma.connectorVault.updateMany).toHaveBeenCalledWith({ where: { userId: 'u1', revision: 4 }, data: { revision: 5, envelope: envelope('mine') } })
    expect(mocks.changed).not.toHaveBeenCalled()
  })

  it('refuses what is not an envelope', async () => {
    expect((await put({ base: 0, envelope: { ...envelope('x'), extra: 1 } })).statusCode).toBe(400)
    expect((await put({ base: -1, envelope: envelope('x') })).statusCode).toBe(400)
    expect((await put({ base: 0, envelope: { ...envelope('x'), v: 2 } })).statusCode).toBe(400)
  })
})
