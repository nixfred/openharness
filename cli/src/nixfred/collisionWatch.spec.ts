import { describe, expect, it } from 'vitest'
import { CollisionWatcher, pathsFromToolInput } from './collisionWatch.js'

const A = { agentId: 'a', agentName: 'Aiona' }
const J = { agentId: 'j', agentName: 'Jasmine' }

describe('pathsFromToolInput', () => {
  it('reads file_path from edit tools and absolute paths from Bash, ignoring build folders', () => {
    expect(pathsFromToolInput('Edit', { file_path: '/home/pi/Projects/blip/src/bridge.ts' })).toEqual(['/home/pi/Projects/blip/src/bridge.ts'])
    expect(pathsFromToolInput('Bash', { command: 'sed -i s/a/b/ /home/pi/Projects/blip/src/x.ts && ls /home/pi/Projects/blip/node_modules/foo' })).toEqual(['/home/pi/Projects/blip/src/x.ts'])
    expect(pathsFromToolInput('Bash', { command: 'npm test' }, '/home/pi/Projects/blip')).toEqual(['/home/pi/Projects/blip/'])
    expect(pathsFromToolInput('Read', { file_path: 'relative.txt' })).toEqual([])
  })
})

describe('CollisionWatcher', () => {
  it('raises a file collision once per window when two agents edit the same file', () => {
    let t = 0
    const w = new CollisionWatcher({ now: () => t, windowMs: 3_600_000 })
    expect(w.noteTool(A, 'Edit', { file_path: '/p/src/a.ts' })).toEqual([])
    t = 1000
    const e = w.noteTool(J, 'Edit', { file_path: '/p/src/a.ts' })
    expect(e).toHaveLength(1)
    expect(e[0]).toMatchObject({ kind: 'file', key: '/p/src/a.ts', detail: 'Jasmine and Aiona on file /p/src/a.ts' })
    t = 2000
    expect(w.noteTool(J, 'Edit', { file_path: '/p/src/a.ts' })).toEqual([]) // deduped
    expect(w.recent()).toHaveLength(1)
  })
  it('raises a folder collision for different files in the same folder, and nothing after the window', () => {
    let t = 0
    const w = new CollisionWatcher({ now: () => t, windowMs: 1000 })
    w.noteTool(A, 'Write', { file_path: '/p/src/a.ts' })
    t = 500
    const e = w.noteTool(J, 'Write', { file_path: '/p/src/b.ts' })
    expect(e.map((x) => x.kind)).toEqual(['folder'])
    t = 5000
    expect(w.noteTool(J, 'Write', { file_path: '/p/src/c.ts' })).toEqual([])
    expect(w.recent()).toEqual([])
  })
  it('raises a branch collision and a lock violation', () => {
    const w = new CollisionWatcher({ now: () => 10 })
    expect(w.noteBranch(A, '/p', 'main')).toEqual([])
    const e = w.noteBranch(J, '/p', 'main')
    expect(e[0]).toMatchObject({ kind: 'branch', detail: 'Jasmine and Aiona on branch main in /p' })
    const lock = w.lock({ repo: '/p', branch: 'feature', holderAgentId: 'a', holderName: 'Aiona', machineId: 'm' })
    expect(lock).toMatchObject({ key: '/p::feature' })
    expect(w.lock({ repo: '/p', branch: 'feature', holderAgentId: 'j', holderName: 'Jasmine', machineId: 'm' })).toMatchObject({ error: expect.stringMatching(/held by Aiona/) })
    const v = w.noteBranch(J, '/p', 'feature')
    expect(v.map((x) => x.kind)).toEqual(['lock'])
    expect(w.unlock('/p', 'feature')).toBe(true)
    expect(w.listLocks()).toEqual([])
  })
  it('notifies listeners', () => {
    const w = new CollisionWatcher({ now: () => 1 })
    const seen: string[] = []
    w.onCollision((e) => seen.push(e.kind))
    w.noteTool(A, 'Edit', { file_path: '/p/x' }); w.noteTool(J, 'Edit', { file_path: '/p/x' })
    expect(seen).toEqual(['file'])
  })
})
