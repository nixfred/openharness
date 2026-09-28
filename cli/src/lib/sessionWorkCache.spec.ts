import { appendFile, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AgentTokenUsageCache } from './agentTokenUsage.js'
import type { RegisteredSession } from './registry.js'

const at = '2026-09-27T13:00:00.000Z'
const lines = (values: unknown[]) => values.map(v => JSON.stringify(v)).join('\n') + '\n'
const receipt = (id: string, cwd = '/ship-hn/tui', extra = {}) => [
  { timestamp: at, sessionId: 'session', cwd: '/silent-beacon', type: 'assistant', ...extra,
    message: { content: [{ type: 'tool_use', id, name: 'Bash', input: { command: `cd ${cwd} && gh pr create --title Fix` } }] } },
  { timestamp: at, sessionId: 'session', cwd: '/silent-beacon', type: 'user', ...extra,
    message: { content: [{ type: 'tool_result', tool_use_id: id, content: `https://github.com/acme/app/pull/${id}` }] } },
]
describe('work evidence in the incremental transcript cache', () => {
  let dir: string, now: number, bytes: number, cache: AgentTokenUsageCache
  let target: Pick<RegisteredSession, 'agentId' | 'sessionId' | 'engine' | 'transcriptPath' | 'registeredAt' | 'cwd' | 'forkedFrom'>
  const open = () => new AgentTokenUsageCache(join(dir, 'cache'), { now: () => now, onRead: n => { bytes += n } })
  const read = async () => { now += 30_000; cache.changed(target); await cache.settled(); return cache.get(target) }
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'session-work-cache-')); now = Date.parse(at); bytes = 0
    target = { agentId: 'hn', sessionId: 'session', engine: 'claude', transcriptPath: join(dir, 'session.jsonl'), registeredAt: 1, cwd: '/silent-beacon' }
    cache = open()
  })
  afterEach(async () => { cache.dispose(); await cache.settled(); await rm(dir, { recursive: true, force: true }) })

  it('publishes work without token usage, persists across restart, and reads only appended bytes', async () => {
    const changed = vi.fn(); cache.onChanged = changed
    await writeFile(target.transcriptPath!, lines([{ type: 'user', text: 'x'.repeat(200_000) }, ...receipt('12')]))
    expect(await read()).toMatchObject({ totalTokens: null, work: { current: [{ cwd: '/ship-hn/tui' }] } })
    expect(changed).toHaveBeenCalledOnce()
    const oldBytes = bytes
    await appendFile(target.transcriptPath!, lines(receipt('13', '/another')))
    expect((await read())?.work?.pullRequests).toHaveLength(2)
    expect(bytes - oldBytes).toBeLessThan(2048)
    cache.dispose(); cache = open()
    const restartBytes = bytes
    expect((await read())?.work?.current[0]?.cwd).toBe('/another')
    expect(bytes).toBe(restartBytes)
    const file = join(dir, 'cache', (await readdir(join(dir, 'cache')))[0])
    const stored = await readFile(file, 'utf8')
    expect(stored).not.toContain('gh pr create')
    expect(stored).not.toContain('x'.repeat(100))
  })

  it('retains known PR links after compaction while invalidating the old current checkout', async () => {
    await writeFile(target.transcriptPath!, lines(receipt('12'))); await read()
    await writeFile(target.transcriptPath!, lines([{ type: 'user', text: 'compacted' }]))
    expect((await read())?.work).toMatchObject({ current: [], uncertain: true,
      pullRequests: [{ url: 'https://github.com/acme/app/pull/12' }] })
    await appendFile(target.transcriptPath!, lines(receipt('13', '/new')))
    expect((await read())?.work).toMatchObject({ current: [{ cwd: '/new' }], uncertain: false })
    expect(cache.get(target)?.work?.pullRequests).toHaveLength(2)
  })

  it('ignores another conversation, child sidechains, and inherited fork history', async () => {
    await writeFile(target.transcriptPath!, lines([
      ...receipt('12', '/foreign', { sessionId: 'other' }),
      ...receipt('13', '/child', { isSidechain: true }),
      ...receipt('14', '/mine'),
    ]))
    expect((await read())?.work?.locations.map(p => p.cwd)).toEqual(['/mine'])
    target = { ...target, forkedFrom: { agentId: 'parent', name: 'Parent' }, registeredAt: Date.parse(at) + 1 }
    expect((await read())?.work).toBeUndefined()
  })

  it('does not import a foreign Codex transcript when its metadata disagrees with the registry', async () => {
    target.engine = 'codex'
    await writeFile(target.transcriptPath!, lines([
      { timestamp: at, type: 'session_meta', payload: { id: 'foreign', cwd: '/foreign' } },
      { timestamp: at, type: 'response_item', payload: { type: 'function_call', call_id: 'one', name: 'exec_command', arguments: '{"cmd":"pwd"}' } },
      { timestamp: at, type: 'response_item', payload: { type: 'function_call_output', call_id: 'one', output: 'ok' } },
    ]))
    expect(await read()).toBeNull()
  })

  it('rebuilds an older cache to recover work associations', async () => {
    await writeFile(target.transcriptPath!, lines(receipt('12'))); await read()
    const file = join(dir, 'cache', (await readdir(join(dir, 'cache')))[0])
    const stored = JSON.parse(await readFile(file, 'utf8')); stored.version = 2; delete stored.work
    await writeFile(file, JSON.stringify(stored)); cache.dispose(); cache = open()
    expect((await read())?.work?.current[0]?.cwd).toBe('/ship-hn/tui')
  })
})
