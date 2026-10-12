/**
 * "It's mine", said once for the whole account: a device's signed acknowledgement that another device
 * on the account's device key log is the person's own, kept beside the log and never in it (an op the
 * log does not know would make every older client freeze it as invalid). The backend checks one before
 * it keeps it, so a device never has to throw a bad one away — but no device takes the backend's word
 * for it: each checks the signature and its signer against its own verified log.
 *
 * ⚠ A copy of cli/src/lib/e2ee/deviceAck.ts, identical below the imports (noble v2 import paths here;
 * cli/src/lib/e2ee/deviceAck.spec.ts compares them). Also ported to Dart
 * (desktop/lib/viewer/device_ack.dart, mobile/lib/viewer/device_ack.dart). All of them are held to
 * deviceAck.vectors.json; change the format in every copy together.
 */
import { ed25519 } from '@noble/curves/ed25519.js'
import type { DevLogState } from './deviceLogCore.js'

export const DEVACK_VERSION = 1
/** The domain tag that heads every signed acknowledgement. Never the device log's (`harness-devlog-v1`). */
export const DEVACK_TAG = 'harness-devack-v1'

export interface DevAck {
  v: number
  /** The account (backend User id) whose log names both keys. */
  acct: string
  /** base64 Ed25519 key of the device being acknowledged. */
  pub: string
  /** seq of the log entry that added `pub`: an acknowledgement is of that one entry, never of the key in
   *  general (a key cannot come back after a remove, but naming the entry keeps it exact). */
  addSeq: number
  /** base64 Ed25519 key of the device that acknowledges it, and signs it. */
  signer: string
  /** Milliseconds since the epoch, as the signer's clock read it. Shown, never trusted for anything. */
  at: number
  sig: string
}

export type UnsignedDevAck = Omit<DevAck, 'sig'>

/** Why `checkDevAck` refused an acknowledgement. */
export type DevAckRefusal =
  | 'BAD_ACK'
  | 'WRONG_ACCOUNT'
  | 'BAD_SIGNATURE'
  | 'SELF_ACK'
  | 'SIGNER_NOT_ACTIVE'
  | 'NOT_ADDED_THERE'

const HAS_BUFFER = typeof Buffer !== 'undefined'

function b64e(u: Uint8Array): string {
  if (HAS_BUFFER) return Buffer.from(u).toString('base64')
  let s = ''
  for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i])
  return btoa(s)
}
function b64d(s: string): Uint8Array {
  if (HAS_BUFFER) return new Uint8Array(Buffer.from(s, 'base64'))
  const bin = atob(s)
  const u = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i)
  return u
}
/** base64 of exactly [n] bytes, in its one canonical spelling; false otherwise. */
function isBytes(s: unknown, n: number): s is string {
  if (typeof s !== 'string' || s.length > 128) return false
  try {
    const u = b64d(s)
    return u.length === n && b64e(u) === s
  } catch { return false }
}
function lvCat(...parts: Array<Uint8Array | string>): Uint8Array {
  const chunks: Uint8Array[] = []
  let total = 0
  for (const p of parts) {
    const b = typeof p === 'string' ? new TextEncoder().encode(p) : p
    const len = new Uint8Array(4)
    new DataView(len.buffer).setUint32(0, b.length, false)
    chunks.push(len, b)
    total += 4 + b.length
  }
  const out = new Uint8Array(total)
  let off = 0
  for (const c of chunks) { out.set(c, off); off += c.length }
  return out
}

/** The bytes a signature covers. Numbers are written in decimal, so every language agrees. */
export function devAckMessage(a: UnsignedDevAck): Uint8Array {
  return lvCat(DEVACK_TAG, String(a.v), a.acct, b64d(a.pub), String(a.addSeq), b64d(a.signer), String(a.at))
}

export function signDevAck(a: UnsignedDevAck, priv: Uint8Array): DevAck {
  return { ...a, sig: b64e(ed25519.sign(devAckMessage(a), priv)) }
}

/** Every field present, of its type and within bounds; null when anything is off. */
export function parseDevAck(raw: unknown): DevAck | null {
  if (!raw || typeof raw !== 'object') return null
  const { v, acct, pub, addSeq, signer, at, sig } = raw as Record<string, unknown>
  if (v !== DEVACK_VERSION) return null
  if (typeof acct !== 'string' || !acct || acct.length > 128) return null
  if (!isBytes(pub, 32) || !isBytes(signer, 32) || !isBytes(sig, 64)) return null
  if (!Number.isSafeInteger(addSeq) || (addSeq as number) < 1) return null
  if (!Number.isSafeInteger(at) || (at as number) <= 0) return null
  return { v, acct, pub, addSeq: addSeq as number, signer, at: at as number, sig }
}

/** Whether [a]'s signature is its signer's, over its fields. */
export function verifyDevAckSignature(a: DevAck): boolean {
  try { return ed25519.verify(b64d(a.sig), devAckMessage(a), b64d(a.signer)) } catch { return false }
}

/**
 * Check [raw] against [state], a device key log as verified by whoever is asking: well formed, of this
 * account, signed by its signer, not the key vouching for itself, the signer active on the log, and
 * `pub` active on it and added at `addSeq`. What it does NOT judge is each device's own: whether the
 * signer is itself new, suspended or gone there, or whether `pub` is suspended there.
 */
export function checkDevAck(state: DevLogState, raw: unknown): { ok: true; ack: DevAck } | { ok: false; code: DevAckRefusal } {
  const ack = parseDevAck(raw)
  if (!ack) return { ok: false, code: 'BAD_ACK' }
  if (ack.acct !== state.acct) return { ok: false, code: 'WRONG_ACCOUNT' }
  if (!verifyDevAckSignature(ack)) return { ok: false, code: 'BAD_SIGNATURE' }
  // A key saying it is its own owner's says nothing: whoever added it would sign that too.
  if (ack.signer === ack.pub) return { ok: false, code: 'SELF_ACK' }
  if (!state.active[ack.signer]) return { ok: false, code: 'SIGNER_NOT_ACTIVE' }
  if (state.active[ack.pub]?.seq !== ack.addSeq) return { ok: false, code: 'NOT_ADDED_THERE' }
  return { ok: true, ack }
}
