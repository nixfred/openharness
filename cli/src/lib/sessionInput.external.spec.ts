import { describe, expect, it, vi } from 'vitest'
import { SessionInputController } from './sessionInput.js'

describe('external (Orca) prompts', () => {
  const session = { agentId: 'a1', sessionId: 's1', engine: 'claude', hosted: 'external' } as never
  const make = (ok: boolean) => {
    const onError = vi.fn(); const onSubmitted = vi.fn()
    const c = new SessionInputController({
      getSession: () => session, validateRuntime: async () => false, inject: async () => false, sendKey: async () => false,
      onError, onSubmitted, externalPrompt: async () => ok,
    } as never)
    return { c, onError, onSubmitted }
  }
  it('a successful send reports no error', async () => {
    const { c, onError, onSubmitted } = make(true)
    await (c as unknown as { inject: (...a: unknown[]) => Promise<void> }).inject('s1', session, 'hello')
    expect(onSubmitted).toHaveBeenCalledWith('s1', 'hello')
    expect(onError).not.toHaveBeenCalled()
  })
  it('a failed send reports the error once', async () => {
    const { c, onError } = make(false)
    await (c as unknown as { inject: (...a: unknown[]) => Promise<void> }).inject('s1', session, 'hello')
    expect(onError).toHaveBeenCalledTimes(1)
  })
})
