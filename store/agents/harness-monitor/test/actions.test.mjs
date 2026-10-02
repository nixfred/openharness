import assert from 'node:assert/strict'
import { test } from 'node:test'
import { stop, open } from '../lib/actions.mjs'
import { mergeRows } from '../lib/inventory.mjs'
import { frame } from './fixtures.mjs'
const observed = Date.now()
const agent = extra => frame({ updatedAt: observed, resumeMode: 'conversation', monitor: { activity: 'idle', activityKnown: true }, ...extra })
const row = extra => mergeRows([agent(extra)], { machine: { machineId: 'remote', name: 'Office' }, local: false })[0]
const intent = async () => ({ creationId: 'same-operation', path: '/fixture', existing: false })
const clearIntent = async () => {}

test('remote stop uses daemon identity, never a signal or tmux command', async () => {
  const calls = []
  const result = await stop(row(), { list: async () => [agent()], rpc: async (...args) => { calls.push(args); return { deleted: true } } })
  assert.equal(result.ok, true)
  assert.deepEqual(calls, [['remote', 'agent_delete', { agentId: 'a1', expectedSessionId: 's1' }]])
})
test('cleanup rechecks live questions, working and unknown activity', async () => {
  for (const activity of ['needsInput', 'working', null]) {
    let wrote = false
    const result = await stop(row(), { list: async () => [agent({ monitor: activity ? { activity, activityKnown: true } : null })], rpc: async () => { wrote = true } })
    assert.equal(result.ok, false); assert.equal(wrote, false)
  }
})
test('explicit single stop can stop work; self and rotated sessions remain protected', async () => {
  assert.equal((await stop(row(), { force: true, list: async () => [agent({ monitor: { activity: 'working', activityKnown: true } })], rpc: async () => ({ deleted: true }) })).ok, true)
  for (const changed of [{ sessionId: 'another-conversation' }, { dsh: 'autonomous/harness-monitor' }]) {
    let wrote = false
    assert.equal((await stop(row(), { force: true, list: async () => [agent(changed)], rpc: async () => { wrote = true } })).ok, false)
    assert.equal(wrote, false)
  }
})
test('a lost stop reply is uncertain, not retried', async () => {
  let writes = 0
  const result = await stop(row(), { list: async () => [agent()], rpc: async () => { writes++; throw Error('Reply lost') } })
  assert.equal(writes, 1); assert.equal(result.ok, false)
})
test('open checks the same durable receipt after a lost reply', async () => {
  const calls = []
  const result = await open(row({ status: 'stopped' }), { intent, clearIntent, list: async () => [agent({ status: 'stopped' })], rpc: async (machine, type, payload) => {
    calls.push([machine, type, payload]); if (type === 'agent_resume') throw Error('Disconnected')
    return { state: 'created', agent: { id: 'a1' } }
  } })
  assert.equal(result.ok, true)
  assert.deepEqual(calls.map(c => c[1]), ['agent_resume', 'agent_create_status'])
  assert.equal(calls[0][2].creationId, calls[1][2].creationId)
})
test('unconfirmed saved intent is only checked, never launched again', async () => {
  const calls = []
  const result = await open(row({ status: 'stopped' }), { intent: async () => ({ ...await intent(), existing: true }), clearIntent,
    list: async () => [agent({ status: 'stopped' })], rpc: async (_, type) => { calls.push(type); return { state: 'unconfirmed' } } })
  assert.equal(result.unconfirmed, true); assert.deepEqual(calls, ['agent_create_status'])
})
test('a reservation that never reached the daemon retries with the same receipt', async () => {
  const calls = []
  const result = await open(row({ status: 'stopped' }), { intent: async () => ({ ...await intent(), existing: true }), clearIntent,
    list: async () => [agent({ status: 'stopped' })], rpc: async (_, type, payload) => {
      calls.push([type, payload.creationId]); return type === 'agent_create_status' ? { state: 'missing' } : { state: 'created', agent: { id: 'a1' } }
    } })
  assert.equal(result.ok, true)
  assert.deepEqual(calls, [['agent_create_status', 'same-operation'], ['agent_resume', 'same-operation']])
})
test('completed receipts are cleared, including old resumes followed by another stop', async () => {
  for (const reply of [{ state: 'failed', failure: { code: 'NO_ENGINE', detail: 'Install OpenCode first.' } },
    { state: 'created', agent: { id: 'a1', terminal: { available: false } } }]) {
    let cleared = false
    const result = await open(row({ status: 'stopped' }), { intent: async () => ({ ...await intent(), existing: true }),
      clearIntent: async () => { cleared = true }, list: async () => [agent({ status: 'stopped' })], rpc: async () => reply })
    assert.equal(result.ok, false); assert.equal(cleared, true)
    if (reply.failure) assert.equal(result.detail, reply.failure.detail)
  }
})
test('cleanup refuses a session with activity after the reviewed snapshot', async () => {
  const result = await stop(row(), { list: async () => [agent({ updatedAt: observed + 1 })], rpc: async () => { throw Error('Must not stop') } })
  assert.match(result.detail, /Activity changed/)
})
test('concurrent open calls share one operation; running sessions need no launch', async () => {
  let writes = 0
  const target = row({ status: 'stopped' }), options = { intent, clearIntent, list: async () => [agent({ status: 'stopped' })], rpc: async () => { writes++; return { state: 'created', agent: { id: 'a1' } } } }
  const [a,b] = await Promise.all([open(target, options), open(target, options)])
  assert.equal(a.ok, true); assert.equal(b.ok, true); assert.equal(writes, 1)
  assert.equal((await open(row(), { list: async () => [agent()], rpc: async () => { throw Error('Must not send') } })).ok, true)
})
