import { describe, expect, it } from 'vitest'
import { buildCheckpoint, describeCheckpoint, listCheckpoints, restoreCheckpoint, type CheckpointDeps } from './taskCheckpoint.js'

function fakeDeps(gitAnswers: Record<string, string>, opts: { applyFails?: boolean } = {}) {
  const files = new Map<string, string>()
  const dirs = new Set<string>()
  const calls: string[][] = []
  const deps: CheckpointDeps = {
    exec: async (cmd, args) => {
      calls.push([cmd, ...args])
      const key = args.filter((a) => a !== '-C' && !a.startsWith('/')).join(' ')
      if (key.startsWith('apply')) { if (opts.applyFails) throw new Error('conflict'); return '' }
      if (key in gitAnswers) return gitAnswers[key]!
      throw new Error('git failed: ' + key)
    },
    writeFile: async (p, d) => { files.set(p, d) },
    readFile: async (p) => { const v = files.get(p); if (v === undefined) throw new Error('ENOENT ' + p); return v },
    mkdir: async (p) => { dirs.add(p) },
    listDir: async (p) => [...dirs].filter((d) => d.startsWith(p + '/')).map((d) => d.slice(p.length + 1)),
    now: () => Date.UTC(2026, 8, 27, 3, 4, 5),
    dataDir: '/data', machine: 'gus',
  }
  return { deps, files, dirs, calls }
}

const answers = {
  'rev-parse HEAD': 'deadbeefcafe1234\n', 'rev-parse --abbrev-ref HEAD': 'nixfred/pulse\n',
  'status --short': ' M a.ts\n?? b.ts\n', 'remote get-url origin': 'https://github.com/nixfred/openharness.git\n',
  'diff --binary HEAD': 'diff --git a/a.ts b/a.ts\n+x\n',
}

describe('taskCheckpoint', () => {
  it('writes checkpoint.json and the patch under a timestamped folder', async () => {
    const { deps, files } = fakeDeps(answers)
    deps.writeFile('/tmp/last-test.txt', 'ok 12 tests')
    const { dir, checkpoint } = await buildCheckpoint(deps, { agentId: 'a1', cwd: '/repo', brief: 'Build Pulse', decisions: ['rings not bars'], testResultPath: '/tmp/last-test.txt' })
    expect(dir).toBe('/data/checkpoints/a1/2026-09-27T03-04-05-000Z')
    expect(checkpoint.git).toEqual({ head: 'deadbeefcafe1234', branch: 'nixfred/pulse', status: ' M a.ts\n?? b.ts', remote: 'https://github.com/nixfred/openharness.git' })
    expect(files.get(`${dir}/uncommitted.patch`)).toBe('diff --git a/a.ts b/a.ts\n+x\n')
    expect(JSON.parse(files.get(`${dir}/checkpoint.json`)!).testResult).toBe('ok 12 tests')
    expect(describeCheckpoint(checkpoint)).toBe('a1@gus 2026-09-27T03:04:05.000Z nixfred/pulse@deadbeef 2 dirty files, 1 decisions')
  })

  it('survives a folder that is not a git repo', async () => {
    const { deps } = fakeDeps({})
    const { checkpoint } = await buildCheckpoint(deps, { agentId: 'a2', cwd: '/notgit', brief: 'b', decisions: [] })
    expect(checkpoint.git).toEqual({ head: '', branch: '', status: '' })
    expect(describeCheckpoint(checkpoint)).toContain('clean tree')
  })

  it('lists and restores, applying the patch with --3way and producing a handoff brief', async () => {
    const { deps, calls } = fakeDeps(answers)
    const { dir } = await buildCheckpoint(deps, { agentId: 'a1', cwd: '/repo', brief: 'Build Pulse', decisions: ['rings'], notes: 'ask Fred about colours' })
    expect(await listCheckpoints(deps, 'a1')).toEqual([dir])
    expect(await listCheckpoints(deps, 'nobody')).toEqual([])
    const r = await restoreCheckpoint(deps, dir, '/other')
    expect(r.applied).toBe(true)
    expect(calls.at(-1)).toEqual(['git', '-C', '/other', 'apply', '--3way', `${dir}/uncommitted.patch`])
    expect(r.handoff).toContain('## Brief\nBuild Pulse')
    expect(r.handoff).toContain('- rings')
    expect(r.handoff).toContain('uncommitted patch applied')
    expect(r.handoff).toContain('ask Fred about colours')
  })

  it('reports an unapplied patch instead of pretending', async () => {
    const { deps } = fakeDeps(answers, { applyFails: true })
    const { dir } = await buildCheckpoint(deps, { agentId: 'a1', cwd: '/repo', brief: 'b', decisions: [] })
    const r = await restoreCheckpoint(deps, dir, '/other')
    expect(r.applied).toBe(false)
    expect(r.handoff).toContain('NOT applied')
  })
})
