import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { ed25519 } from '@noble/curves/ed25519.js'
import { checkDevAck, devAckMessage, signDevAck } from './deviceAckCore.js'
import { applyDevLogEntries, emptyDevLogState } from './deviceLogCore.js'

// The same fixture the CLI and both Dart ports are held to (cli/scripts/gen-devack-vectors.ts).
const vectors = JSON.parse(readFileSync(join(import.meta.dirname, 'deviceAck.vectors.json'), 'utf-8'))
const b64d = (s: string): Uint8Array => new Uint8Array(Buffer.from(s, 'base64'))

describe('device acknowledgement core against the shared vectors', () => {
  const state = applyDevLogEntries(emptyDevLogState(vectors.acct), vectors.log).state
  const seeds = vectors.seeds as Record<string, string>
  const byPub = new Map(Object.entries(vectors.pubs as Record<string, string>).map(([name, pub]) => [pub, b64d(seeds[name])]))

  it('encodes, signs and accepts every valid acknowledgement as the fixture does', () => {
    expect(Buffer.from(devAckMessage(vectors.valid[0])).toString('hex')).toBe(vectors.message)
    for (const a of vectors.valid) {
      const { sig, ...unsigned } = a
      expect(Buffer.from(ed25519.getPublicKey(byPub.get(a.signer)!)).toString('base64')).toBe(a.signer)
      expect(signDevAck(unsigned, byPub.get(a.signer)!).sig).toBe(sig)
      expect(checkDevAck(state, a)).toEqual({ ok: true, ack: a })
    }
  })

  for (const c of vectors.invalid as Array<{ name: string; ack: unknown; code: string }>) {
    it(`refuses: ${c.name} (${c.code})`, () => {
      expect(checkDevAck(state, c.ack)).toEqual({ ok: false, code: c.code })
    })
  }
})
