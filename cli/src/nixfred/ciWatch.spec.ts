import { describe, expect, it } from 'vitest'
import { CiWatcher, parsePrChecks, type CiCheck } from './ciWatch.js'

const target = { agentId: 'p', agentName: 'Peyton PR', cwd: '/repo', branch: 'feature' }

function watcher(sequence: CiCheck[][], logs: Record<string, string> = {}) {
  let i = 0
  return new CiWatcher({
    prChecks: async () => sequence[Math.min(i++, sequence.length - 1)] ?? [],
    failedLog: async (_cwd, c) => logs[c.name] ?? '',
    now: () => 42,
  })
}

describe('CiWatcher', () => {
  it('wakes once per failing check with the log tail, stays quiet while green or pending, and re-wakes after a pass', async () => {
    const w = watcher([
      [{ name: 'build', state: 'pending' }],
      [{ name: 'build', state: 'fail', link: 'https://ci/1' }, { name: 'lint', state: 'pass' }],
      [{ name: 'build', state: 'fail', link: 'https://ci/1' }],
      [{ name: 'build', state: 'pass' }],
      [{ name: 'build', state: 'fail', link: 'https://ci/2' }],
    ], { build: 'line1\n\nError: boom\n' })
    expect(await w.poll(target)).toBeNull()
    const wake = await w.poll(target)
    expect(wake?.failed.map((c) => c.name)).toEqual(['build'])
    expect(wake?.message).toContain('CI failed on branch feature: build.')
    expect(wake?.message).toContain('Error: boom')
    expect(wake?.message).toContain('Run: https://ci/1')
    expect(wake?.message).toMatch(/Do not merge\.$/)
    expect(await w.poll(target)).toBeNull()
    expect(await w.poll(target)).toBeNull()
    expect((await w.poll(target))?.message).toContain('https://ci/2')
  })
  it('swallows gh errors', async () => {
    const w = new CiWatcher({ prChecks: async () => { throw new Error('no pr') }, failedLog: async () => '', now: () => 1 })
    expect(await w.poll(target)).toBeNull()
  })
})

describe('parsePrChecks', () => {
  it('maps gh output and ignores junk', () => {
    expect(parsePrChecks('[{"name":"test","state":"FAILURE","link":"x","bucket":"fail"},5,{"workflow":"w","status":"SUCCESS"}]')).toEqual([
      { name: 'test', state: 'failure', link: 'x', bucket: 'fail' }, { name: 'w', state: 'success', link: undefined, bucket: undefined },
    ])
    expect(parsePrChecks('not json')).toEqual([])
  })
})
