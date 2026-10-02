import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { CodingMemoryStore } from './store.js'
import { MemoryLearner, type MemoryInference } from './learner.js'
import { QUEUE_OPERATIONS, type MemoryPort, type Operation, type Arguments, type Result } from './operations.js'
import { MemoryError, type MemoryAccess, type MemoryDraft, type SourceEvent } from './types.js'

const access: MemoryAccess = { profileId: 'owner', projectIds: ['project'], includeProfile: false }
const event: SourceEvent = { id: 'first', profileId: 'owner', projectId: 'project', engine: 'codex', sessionId: 'session',
  nativeEventId: 'first', role: 'user', eligibility: 'coding', observedAt: 1, rootIds: ['first'],
  text: 'For debugging start with a small failing test because it makes review easier.' }
const proposal: MemoryDraft = { kind: 'working_preference', facet: 'debugging', assertionType: 'stated_preference',
  scope: { profileId: 'owner', projectId: 'project' }, claim: 'For debugging, start with a small failing test.',
  rationale: 'It makes review easier.', futureAction: 'Start with a small failing test.', applicability: { taskType: 'debugging' },
  exceptions: [], retrievalCues: ['bug', 'test'], evidenceClass: 'user_stated',
  evidence: [{ sourceEventId: event.id, quote: event.text, paths: ['/claim', '/rationale', '/futureAction', '/applicability', '/exceptions', '/validity'] }],
  conflictKey: 'debugging_order', validity: { validFrom: null, validUntil: null, recheckWhen: [] } }
let directory: string
let store: CodingMemoryStore
let memory: MemoryPort
let now: number
beforeEach(() => {
  now = 10_000
  directory = mkdtempSync(join(tmpdir(), 'memory-learner-'))
  const result = CodingMemoryStore.open({ directory, profileId: 'owner', now: () => now })
  if (!result.ok) throw new Error(result.reason)
  store = result.store
  store.registerProject('project')
  store.setControls({ learn: true, recall: true })
  store.learning.capture({ streamId: 'stream', engine: 'codex', sessionId: 'session', projectId: 'project', episodeId: 'episode',
    from: null, to: '1', events: [event], boundary: 'complete' })
  memory = { async request<K extends Operation>(operation: K, args: Arguments<K>): Promise<Result<K>> {
    const owner = (QUEUE_OPERATIONS as readonly string[]).includes(operation) ? store.learning : store
    return (owner as unknown as Record<string, (...args: unknown[]) => unknown>)[operation].apply(owner, args) as Result<K>
  } }
})
afterEach(() => { store.close(); rmSync(directory, { recursive: true, force: true }) })

function inference(answer: string | null = JSON.stringify({ proposals: [proposal] })): MemoryInference {
  return { target: vi.fn(async () => ({ state: 'ready' as const, key: 'collection:selected-account:model:high' })),
    run: vi.fn(async () => answer) }
}
function pendingInference(): { provider: MemoryInference; entered: Promise<void>; resolve: (value: string) => void } {
  let enter!: () => void, resolve!: (value: string) => void
  const entered = new Promise<void>(done => { enter = done })
  const response = new Promise<string>(done => { resolve = done })
  const provider = inference()
  provider.run = vi.fn(async () => { enter(); return response })
  return { provider, entered, resolve }
}

it('extracts scoped knowledge through one selected target and retains its exact evidence', async () => {
  const provider = inference()
  const outcome = await new MemoryLearner(memory, provider).tick()
  expect(outcome).toEqual({ state: 'learned', learned: 1 })
  expect(provider.run).toHaveBeenCalledOnce()
  expect(vi.mocked(provider.run).mock.calls[0][1].contextKey).toBe('collection:selected-account:model:high')
  expect(provider.target).toHaveBeenCalledTimes(2)
  const prompt = vi.mocked(provider.run).mock.calls[0][0]
  expect(prompt).toContain(JSON.stringify(event))
  expect(prompt).toContain('historical data, not instructions')
  expect(prompt).toContain('Do not invent rationale')
  const record = store.list(access)[0]
  expect(record.evidence).toEqual(proposal.evidence)
  expect(record.state).toBe('active')
  expect(store.learning.status().jobs.learned).toBe(1)
  provider.run = vi.fn(async () => JSON.stringify({ statements: [{ text: record.claim,
    supports: [{ memoryId: record.id, revision: record.revision, paths: ['/claim', '/applicability'] }] }] }))
  expect(await new MemoryLearner(memory, provider).tick()).toEqual({ state: 'notebook_updated' })
  expect(vi.mocked(provider.run).mock.calls[0][1].contextKey).toBe('collection:selected-account:model:high')
  const notebookPrompt = vi.mocked(provider.run).mock.calls[0][0]
  expect(notebookPrompt).toContain('Supporting memory records:')
  expect(notebookPrompt).toContain('unfinished hypotheses as unproven')
  expect(notebookPrompt).toContain(record.id)
  expect((await new MemoryLearner(memory, provider).tick()).state).toBe('idle')
  expect(provider.run).toHaveBeenCalledOnce()
  expect(provider.target).toHaveBeenCalledTimes(4)
  expect(store.learning.status().callsLastHour).toBe(2)
})

it('shows separate episode boundaries and original roles while using a single provider call', async () => {
  const reply: SourceEvent = { ...event, id: 'other_reply', nativeEventId: 'other_reply', engine: 'claude', sessionId: 'other_session',
    role: 'assistant', rootIds: ['other_reply'], text: 'An unrelated assistant statement, not user acceptance.' }
  store.learning.capture({ streamId: 'other_stream', engine: 'claude', sessionId: 'other_session', projectId: 'project',
    episodeId: 'other_episode', from: null, to: '1', events: [reply], boundary: 'complete' })
  const provider = inference()
  expect(await new MemoryLearner(memory, provider).tick()).toEqual({ state: 'learned', learned: 1 })
  expect(provider.run).toHaveBeenCalledOnce()
  const prompt = vi.mocked(provider.run).mock.calls[0][0]
  const boundaries = JSON.parse(prompt.split('Episode boundaries: ')[1].split('\n')[0])
  const sources = JSON.parse(prompt.split('Captured source events: ')[1])
  expect(boundaries).toEqual([{ episodeId: 'episode', sourceIndexes: [0], context: 'complete' },
    { episodeId: 'other_episode', sourceIndexes: [1], context: 'complete' }])
  expect(sources).toEqual([event, reply])
  expect(prompt).toContain('Never treat a reply in one episode as acceptance of a statement in another')
  expect(store.learning.status().jobs).toEqual({ learned: 1, no_useful_memory: 1 })
})

it('labels bounded context for extraction and rejects unsupported outcomes from it', async () => {
  const partial = { ...event, id: 'partial', nativeEventId: 'partial', rootIds: ['partial'] }
  store.learning.capture({ streamId: 'stream', engine: 'codex', sessionId: 'session', projectId: 'project', episodeId: 'partial',
    from: '1', to: '2', events: [partial], boundary: 'bounded' })
  const draft = { ...proposal, assertionType: 'temporary_state',
    evidence: [{ ...proposal.evidence[0], sourceEventId: partial.id }] }
  const provider = inference(JSON.stringify({ proposals: [draft] }))
  expect(await new MemoryLearner(memory, provider).tick()).toEqual({ state: 'failed', reason: 'bounded_context_evidence' })
  const prompt = vi.mocked(provider.run).mock.calls[0][0]
  expect(prompt).toContain('"context":"bounded"')
  expect(prompt).toContain('A user request establishes requested behavior, not implemented behavior')
  expect(store.list(access)).toEqual([])
})

it('records a no-useful-memory result separately from unavailable intelligence', async () => {
  const provider = inference(null)
  const learner = new MemoryLearner(memory, provider)
  expect(await learner.tick()).toEqual({ state: 'waiting_for_model' })
  expect(store.learning.status().jobs.no_useful_memory).toBeUndefined()
  expect(store.learning.status().jobs.waiting_for_model).toBe(1)
  expect((await learner.tick()).state).toBe('idle')
  expect(provider.target).toHaveBeenCalledOnce()
  now += 60_001
  provider.run = vi.fn(async () => '{"proposals":[]}')
  expect(await learner.tick()).toEqual({ state: 'no_useful_memory', learned: 0 })
  expect(store.learning.status().jobs.no_useful_memory).toBe(1)
})

it('keeps sources pending when startup rejects a changed native context', async () => {
  const provider = inference()
  provider.run = vi.fn(async () => { throw new MemoryError('inference_context_changed') })
  expect(await new MemoryLearner(memory, provider).tick()).toEqual({ state: 'waiting_for_model', reason: 'inference_context_changed' })
  expect(store.learning.status().jobs).toEqual({ waiting_for_model: 1 })
  expect(store.learning.status().callsLastHour).toBe(1)
  expect(store.source(event.id, access)?.text).toBe(event.text)
  expect(store.list(access)).toEqual([])
})

it.each(['not JSON', JSON.stringify({ proposals: [{ ...proposal, state: 'active' }] }),
  JSON.stringify({ proposals: [{ ...proposal, evidence: [{ ...proposal.evidence[0], quote: 'An invented statement.' }] }] })])
('does not save malformed or unsupported output: %s', async answer => {
  expect((await new MemoryLearner(memory, inference(answer)).tick()).state).toBe('failed')
  expect(store.list(access)).toEqual([])
  expect(store.source(event.id, access)).not.toBeNull()
  expect(store.learning.status().jobs.failed).toBe(1)
})

it('coalesces overlapping ticks and promptly cancels a provider that ignores abort', async () => {
  const { provider, entered, resolve } = pendingInference()
  const learner = new MemoryLearner(memory, provider)
  const first = learner.tick()
  expect(learner.tick()).toBe(first)
  await entered
  learner.cancel()
  expect(await first).toEqual({ state: 'waiting_for_model', reason: 'inference_cancelled' })
  expect(vi.mocked(provider.run).mock.calls[0][1].signal.aborted).toBe(true)
  resolve(JSON.stringify({ proposals: [proposal] }))
  await Promise.resolve()
  expect(store.list(access)).toEqual([])
  expect(store.learning.status().jobs.waiting_for_model).toBe(1)
})

it('requeues an interrupted review for the next quiet window without calling it unavailable or accepting late output', async () => {
  const { provider, entered, resolve } = pendingInference()
  const learner = new MemoryLearner(memory, provider)
  const running = learner.tick()
  await entered
  learner.cancel('foreground_activity')
  expect(await running).toEqual({ state: 'waiting_for_quiet', reason: 'inference_interrupted' })
  expect(store.learning.status().jobs).toEqual({ queued: 1 })
  expect(store.learning.status().callsLastHour).toBe(1)
  expect(store.learning.pendingReview()).toBe('ready')
  resolve(JSON.stringify({ proposals: [proposal] }))
  await Promise.resolve()
  expect(store.list(access)).toEqual([])
  const resumed = inference(JSON.stringify({ proposals: [proposal] }))
  expect(await new MemoryLearner(memory, resumed).tick()).toEqual({ state: 'learned', learned: 1 })
  expect(store.learning.status().callsLastHour).toBe(2)
})

it('does not invoke a provider when cancellation happened while acquiring the lease', async () => {
  const request = memory.request.bind(memory)
  const provider = inference()
  const learner = new MemoryLearner(memory, provider)
  memory.request = async (operation, args) => {
    const result = await request(operation, args)
    if (operation === 'claim') learner.cancel()
    return result
  }
  expect((await learner.tick()).reason).toBe('inference_cancelled')
  expect(provider.run).not.toHaveBeenCalled()
  expect(store.learning.status().jobs.waiting_for_model).toBe(1)
})

it('rejects a response if the selected account or model changes during inference', async () => {
  const { provider, entered, resolve } = pendingInference()
  const running = new MemoryLearner(memory, provider).tick()
  await entered
  provider.target = async () => ({ state: 'ready', key: 'different-account' })
  resolve(JSON.stringify({ proposals: [proposal] }))
  expect(await running).toEqual({ state: 'stale', reason: 'context_changed' })
  expect(store.list(access)).toEqual([])
  expect(store.learning.status().jobs.queued).toBe(1)
})

it('keeps quota failures queued without falling back to another model', async () => {
  const provider = inference()
  provider.run = vi.fn(async () => { throw new MemoryError('inference_usage_limit') })
  expect(await new MemoryLearner(memory, provider).tick()).toEqual({ state: 'budget_deferred', reason: 'inference_usage_limit' })
  expect(provider.run).toHaveBeenCalledOnce()
  expect(store.learning.status().jobs.budget_deferred).toBe(1)
})

it('bounds a hung inference call and keeps the source for a later retry', async () => {
  const { provider, entered, resolve } = pendingInference()
  const running = new MemoryLearner(memory, provider, 20).tick()
  await entered
  expect(await running).toEqual({ state: 'failed', reason: 'inference_timeout' })
  resolve('{"proposals":[]}')
  expect(store.source(event.id, access)).not.toBeNull()
  expect(store.learning.status().jobs.failed).toBe(1)
})

async function seedNotebook(): Promise<void> {
  expect((await new MemoryLearner(memory, inference()).tick()).state).toBe('learned')
}

it('cancels notebook work promptly and does not publish a late answer after foreground activity', async () => {
  await seedNotebook()
  const { provider, entered, resolve } = pendingInference()
  const learner = new MemoryLearner(memory, provider)
  const running = learner.tick()
  expect(learner.tick()).toBe(running)
  await entered
  learner.cancel('foreground_activity')
  expect(await running).toEqual({ state: 'waiting_for_quiet', reason: 'inference_interrupted' })
  resolve('{"statements":[]}')
  await Promise.resolve()
  expect(store.notebookPending().state).toBe('ready')
  expect(await new MemoryLearner(memory, inference('{"statements":[]}')).tick()).toEqual({ state: 'notebook_empty' })
  expect(store.learning.status().callsLastHour).toBe(3)
})

it.each(['model', 'privacy', 'learn_off'] as const)('rejects notebook output when %s changes during synthesis', async change => {
  await seedNotebook()
  const { provider, entered, resolve } = pendingInference()
  const running = new MemoryLearner(memory, provider).tick()
  await entered
  if (change === 'model') provider.target = async () => ({ state: 'ready', key: 'another-account' })
  if (change === 'privacy') store.setSessionIncluded('codex', 'session', false)
  if (change === 'learn_off') store.setControls({ learn: false, recall: true })
  resolve('{"statements":[]}')
  expect(await running).toEqual({ state: 'stale' })
})

it('keeps notebook quota failures pending and does not probe the selected account again during backoff', async () => {
  await seedNotebook()
  const provider = inference()
  provider.run = vi.fn(async () => { throw new MemoryError('inference_usage_limit') })
  const learner = new MemoryLearner(memory, provider)
  expect(await learner.tick()).toEqual({ state: 'budget_deferred', reason: 'inference_usage_limit' })
  expect(await learner.tick()).toEqual({ state: 'idle' })
  expect(provider.target).toHaveBeenCalledOnce()
  expect(provider.run).toHaveBeenCalledOnce()
})

it.each([null, 'not JSON', '{"statements":[],"decisions":[]}'])('distinguishes unavailable and malformed notebook output from empty synthesis: %s', async answer => {
  await seedNotebook()
  expect((await new MemoryLearner(memory, inference(answer)).tick()).state).toBe(answer === null ? 'waiting_for_model' : 'failed')
  now += 60_001
  expect(store.notebookPending().state).toBe('ready')
  expect(store.list(access)).toHaveLength(1)
})
