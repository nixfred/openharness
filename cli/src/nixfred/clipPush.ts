/**
 * nixfred `clip_push`: a paired machine of the owner's pushes text or a file to this machine's clipboard or
 * drop folder (`harness clip push`). Sealed end to end (lib/e2ee/applicationFrames.ts MACHINE_REQUESTS).
 *
 * Upstream moved every request out of backendSocket.ts's switch into services that declare their request
 * types (services/AGENTS.md). This is that shape: core/main.ts serves `CLIP_REQUESTS` through the service
 * host in the core's own process, beside the shell service, and the handler only checks the asker and the
 * sizes before handing the push to the nixfred wiring. Sizes are bounded before anything touches the
 * clipboard or the disk.
 */
import type { Asker } from '../core/api.js'

export interface ClipPush { text?: string; file?: { name: string; base64: string }; from: string }
export type ClipReceive = (push: ClipPush) => Promise<{ ok: true; detail: string } | { ok: false; error: string }>

export const CLIP_REQUESTS = ['clip_push'] as const
export const CLIP_TEXT_MAX = 1_000_000
export const CLIP_FILE_MAX_B64 = 34_000_000 // ~25 MB decoded

export async function clipPushRequest(payload: Record<string, unknown>, asker: Pick<Asker, 'owner'>, receive: ClipReceive): Promise<Record<string, unknown>> {
  if (!asker.owner) return { error: 'OWNER_REQUIRED' }
  const text = typeof payload.text === 'string' ? payload.text : undefined
  const file = payload.file && typeof payload.file === 'object' ? payload.file as { name?: unknown; base64?: unknown } : undefined
  if (text !== undefined && text.length > CLIP_TEXT_MAX) return { error: 'CLIP_TOO_LARGE', detail: `text over ${CLIP_TEXT_MAX} chars` }
  if (file && (typeof file.name !== 'string' || typeof file.base64 !== 'string' || file.base64.length > CLIP_FILE_MAX_B64)) {
    return { error: 'CLIP_TOO_LARGE', detail: `file over ${Math.round(CLIP_FILE_MAX_B64 * 3 / 4 / 1048576)} MB or malformed` }
  }
  if (text === undefined && !file) return { error: 'CLIP_EMPTY' }
  try {
    return { ...await receive({ text, file: file ? { name: file.name as string, base64: file.base64 as string } : undefined, from: typeof payload.from === 'string' ? payload.from.slice(0, 64) : 'peer' }) }
  } catch (error) {
    return { error: 'INTERNAL', detail: error instanceof Error ? error.message : String(error) }
  }
}
