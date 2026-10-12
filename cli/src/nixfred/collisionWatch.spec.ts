import { describe, expect, it } from 'vitest'
import { CollisionWatcher, countsTowardBranch, pathsFromToolInput } from './collisionWatch.js'

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

describe('countsTowardBranch', () => {
  const H = 3_600_000
  const now = 100 * H
  it('counts an agent that is working, or that was active inside the window', () => {
    expect(countsTowardBranch({ state: 'working', since: now - 5 * H }, now)).toBe(true)
    expect(countsTowardBranch({ state: 'done', since: now - H / 2 }, now)).toBe(true)
    expect(countsTowardBranch({ state: 'idle', since: now - H }, now)).toBe(true)
    expect(countsTowardBranch({ state: 'waiting', since: now - 10 }, now)).toBe(true)
  })
  it('ignores offline rows and finished or forgotten ones older than the window', () => {
    expect(countsTowardBranch({ state: 'offline', since: now }, now)).toBe(false)
    expect(countsTowardBranch({ state: 'done', since: now - 2 * H }, now)).toBe(false) // a finished headless run still listed as "done, unreviewed"
    expect(countsTowardBranch({ state: 'idle', since: 0 }, now)).toBe(false) // never seen doing anything
    expect(countsTowardBranch({ state: 'idle', since: now, detail: 'watching' }, now)).toBe(false) // a SessionStart and no turn: the resumed-session phantom
    expect(countsTowardBranch({ state: 'idle', since: now, detail: 'reviewed' }, now)).toBe(true) // a real session whose finished turn was looked at, just now
  })
  it('a forgotten "done" row beside the one live session raises no branch collision (the hourly "mobs and mobs on branch main")', () => {
    const w = new CollisionWatcher({ now: () => now })
    const live = { agentId: 'live', agentName: 'mobs' }
    const ghost = { agentId: 'ghost', agentName: 'mobs' }
    const rows = [{ ...live, state: 'working', since: now - 60_000 }, { ...ghost, state: 'done', since: now - 50 * H }]
    for (const r of rows) if (countsTowardBranch(r, now)) w.noteBranch({ agentId: r.agentId, agentName: r.agentName }, '/p/mobs', 'main')
    expect(w.recent()).toEqual([])
    w.noteBranch(ghost, '/p/mobs', 'main') // feeding the ghost too, as the poll used to, is what raised it every hour
    expect(w.recent()).toHaveLength(1)
    expect(w.recent()[0]!.detail).toBe('mobs and mobs on branch main in /p/mobs')
  })
  it('two sessions that both worked inside the window still collide', () => {
    const w = new CollisionWatcher({ now: () => now })
    const rows = [{ agentId: 'a', agentName: 'Aiona', state: 'working', since: now - 1000 }, { agentId: 'j', agentName: 'Jasmine', state: 'done', since: now - H / 4 }]
    for (const r of rows) if (countsTowardBranch(r, now)) w.noteBranch({ agentId: r.agentId, agentName: r.agentName }, '/p', 'main')
    expect(w.recent().map((e) => e.kind)).toEqual(['branch'])
  })
})
