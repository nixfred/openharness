/**
 * The account's connected services, the same on every computer: one envelope the daemons seal for the
 * account's machines (cli/src/lib/e2ee/connectorVault.ts). The backend never holds a key to it: it keeps
 * the latest envelope and its revision, and tells every computer when it changed, as with the desk.
 *
 *   GET /api/connector-vault  → { revision, envelope }   (envelope null before the first write)
 *   PUT /api/connector-vault  { base, envelope } → { written, revision, envelope }
 *
 * A write names the revision it was made from. If another computer wrote since, nothing is written and
 * the answer is the newer envelope (`written: false`): the daemon merges what it holds into it and writes
 * again. After a write every adapter socket of the user hears `connectors_changed` (lib/adapterAccountPushes.ts).
 */
import type { FastifyInstance } from 'fastify'
import { Prisma } from '@prisma/client'
import { z } from 'zod'
import { prisma } from '../lib/prisma.js'
import { publishConnectorsChanged } from '../lib/bus.js'
import { validateBody } from '../middlewares/validation.js'
import { sendSuccess } from '../utils/response.js'

/** The envelope as sealed: opaque here beyond its shape. Its size is bounded, not its meaning. */
export const vaultEnvelopeSchema = z.object({
  v: z.literal(1),
  sender: z.string().min(1).max(128),
  eph: z.string().min(1).max(128),
  nonce: z.string().min(1).max(64),
  ct: z.string().min(1).max(1_000_000),
  keys: z.record(z.string().min(1).max(128), z.string().min(1).max(256)).refine(keys => Object.keys(keys).length <= 64),
  sig: z.string().min(1).max(256),
}).strict()

export const vaultWriteSchema = z.object({
  base: z.number().int().min(0),
  envelope: vaultEnvelopeSchema,
}).strict()

export interface VaultDoc { revision: number; envelope: z.infer<typeof vaultEnvelopeSchema> | null }

async function readVault(userId: string): Promise<VaultDoc> {
  const row = await prisma.connectorVault.findUnique({ where: { userId } })
  if (!row) return { revision: 0, envelope: null }
  const parsed = vaultEnvelopeSchema.safeParse(row.envelope)
  return { revision: row.revision, envelope: parsed.success ? parsed.data : null }
}

export async function connectorVaultRoutes(app: FastifyInstance): Promise<void> {
  app.get('/api/connector-vault', async (req, reply) => {
    sendSuccess(reply, await readVault(req.user!.sub))
  })

  app.put<{ Body: z.infer<typeof vaultWriteSchema> }>(
    '/api/connector-vault', { preHandler: [validateBody(vaultWriteSchema)], bodyLimit: 2 * 1024 * 1024 },
    async (req, reply) => {
      const userId = req.user!.sub
      const { base, envelope } = req.body
      const current = await readVault(userId)
      if (current.revision !== base) return sendSuccess(reply, { written: false, ...current })
      const next = { revision: base + 1, envelope }
      const stored = envelope as unknown as Prisma.InputJsonValue
      // Compare-and-set on the revision: whoever wrote first wins, the other is answered the newer one.
      const bumped = await prisma.connectorVault.updateMany({ where: { userId, revision: base }, data: { revision: next.revision, envelope: stored } })
      if (bumped.count !== 1) {
        if (base !== 0) return sendSuccess(reply, { written: false, ...await readVault(userId) })
        try {
          await prisma.connectorVault.create({ data: { userId, revision: next.revision, envelope: stored } })
        } catch (error) {
          if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
            return sendSuccess(reply, { written: false, ...await readVault(userId) })
          }
          throw error
        }
      }
      void publishConnectorsChanged(userId, { revision: next.revision })
      return sendSuccess(reply, { written: true, ...next })
    },
  )
}
