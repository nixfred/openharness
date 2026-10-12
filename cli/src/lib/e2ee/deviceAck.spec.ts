import { describe, expect, it } from 'vitest'
import { readFileSync } from 'fs'
import { fileURLToPath } from 'url'
import { ed25519 } from '@noble/curves/ed25519'
import vectors from './deviceAck.vectors.json' with { type: 'json' }
import { checkDevAck, devAckMessage, parseDevAck, signDevAck, verifyDevAckSignature, type DevAck } from './deviceAck.js'
import { applyDevLogEntries, emptyDevLogState } from './deviceLog.js'

const b64d = (s: string): Uint8Array => new Uint8Array(Buffer.from(s, 'base64'))
const read = (rel: string): Buffer => readFileSync(fileURLToPath(new URL(rel, import.meta.url)))
/** A source file from its first line after the imports: what every copy must share. */
const belowImports = (src: string): string => {
  const lines = src.split('\n')
  let last = -1
  lines.forEach((l, i) => { if (l.startsWith('import ')) last = i })
  return lines.slice(last + 1).join('\n')
}

describe('device acknowledgement vectors', () => {
  const state = applyDevLogEntries(emptyDevLogState(vectors.acct), vectors.log).state
  const seeds = vectors.seeds as Record<string, string>
  const byPub = new Map(Object.entries(vectors.pubs).map(([name, pub]) => [pub, b64d(seeds[name])]))

  it('every other copy of the fixture is byte-identical to this one', () => {
    const here = read('./deviceAck.vectors.json')
    for (const copy of ['../../../../backend/src/lib/deviceAck.vectors.json', '../../../../desktop/test/viewer/deviceAck.vectors.json', '../../../../mobile/test/viewer/deviceAck.vectors.json']) {
      expect(read(copy).equals(here), `${copy} differs: run scripts/gen-devack-vectors.ts and copy it`).toBe(true)
    }
  })

  it('the backend copy of the module is this one, below the imports', () => {
    const backend = read('../../../../backend/src/lib/deviceAckCore.ts').toString()
    expect(belowImports(backend)).toBe(belowImports(read('./deviceAck.ts').toString()))
  })

  it('derives the fixture keys from their seeds', () => {
    for (const [name, seed] of Object.entries(seeds)) {
      expect(Buffer.from(ed25519.getPublicKey(b64d(seed))).toString('base64')).toBe((vectors.pubs as Record<string, string>)[name])
    }
  })

  it('encodes the first acknowledgement to the fixture bytes', () => {
    expect(Buffer.from(devAckMessage(vectors.valid[0])).toString('hex')).toBe(vectors.message)
  })

  it('re-signs every valid acknowledgement to the same signature, and accepts it', () => {
    for (const a of vectors.valid) {
      const { sig, ...unsigned } = a
      expect(signDevAck(unsigned, byPub.get(a.signer)!).sig).toBe(sig)
      expect(checkDevAck(state, a)).toEqual({ ok: true, ack: a })
    }
  })

  for (const c of vectors.invalid) {
    it(`refuses: ${c.name} (${c.code})`, () => {
      expect(checkDevAck(state, c.ack)).toEqual({ ok: false, code: c.code })
    })
  }
})

describe('parseDevAck', () => {
  const good = vectors.valid[0] as DevAck

  it('takes exactly the fields it signs', () => {
    expect(parseDevAck({ ...good, extra: 1 })).toEqual(good)
  })

  it('refuses each field out of bounds', () => {
    for (const bad of [
      null, 7, { ...good, acct: '' }, { ...good, acct: 'x'.repeat(129) }, { ...good, acct: 5 },
      { ...good, signer: 'not base64!' }, { ...good, sig: Buffer.alloc(63).toString('base64') },
      // Base64 that decodes but is not in its one canonical spelling.
      { ...good, pub: `${good.pub.slice(0, -2)}x=` }, { ...good, pub: 'A'.repeat(200) },
      { ...good, addSeq: 1.5 }, { ...good, addSeq: '3' }, { ...good, at: 0 }, { ...good, at: Number.MAX_SAFE_INTEGER + 1 },
    ]) expect(parseDevAck(bad)).toBeNull()
  })

  it('a signature that does not decode is no signature', () => {
    expect(verifyDevAckSignature({ ...good, sig: Buffer.alloc(64, 0xff).toString('base64') })).toBe(false)
  })
})
