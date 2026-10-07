import { describe, expect, it, vi } from 'vitest'
import { CLIP_FILE_MAX_B64, CLIP_TEXT_MAX, clipPushRequest } from './clipPush.js'

describe('nixfred clip_push as a served request', () => {
  const owner = { owner: true }
  it('refuses anyone but the owner, oversized or empty pushes, before the clipboard is touched', async () => {
    const receive = vi.fn(async () => ({ ok: true as const, detail: 'copied' }))
    expect(await clipPushRequest({ text: 'hi' }, { owner: false }, receive)).toEqual({ error: 'OWNER_REQUIRED' })
    expect(await clipPushRequest({ text: 'x'.repeat(CLIP_TEXT_MAX + 1) }, owner, receive)).toMatchObject({ error: 'CLIP_TOO_LARGE' })
    expect(await clipPushRequest({ file: { name: 'a', base64: 'x'.repeat(CLIP_FILE_MAX_B64 + 1) } }, owner, receive)).toMatchObject({ error: 'CLIP_TOO_LARGE' })
    expect(await clipPushRequest({ file: { name: 7, base64: '' } }, owner, receive)).toMatchObject({ error: 'CLIP_TOO_LARGE' })
    expect(await clipPushRequest({}, owner, receive)).toEqual({ error: 'CLIP_EMPTY' })
    expect(receive).not.toHaveBeenCalled()
  })
  it('hands a valid push on, names its sender, and turns a failure into INTERNAL', async () => {
    const receive = vi.fn(async () => ({ ok: true as const, detail: 'copied' }))
    expect(await clipPushRequest({ text: 'hi', from: 'vic' }, owner, receive)).toEqual({ ok: true, detail: 'copied' })
    expect(receive).toHaveBeenCalledWith({ text: 'hi', file: undefined, from: 'vic' })
    await clipPushRequest({ file: { name: 'a.txt', base64: 'aGk=' } }, owner, receive)
    expect(receive).toHaveBeenLastCalledWith({ text: undefined, file: { name: 'a.txt', base64: 'aGk=' }, from: 'peer' })
    expect(await clipPushRequest({ text: 'hi' }, owner, async () => { throw new Error('no wl-copy') })).toEqual({ error: 'INTERNAL', detail: 'no wl-copy' })
  })
})
