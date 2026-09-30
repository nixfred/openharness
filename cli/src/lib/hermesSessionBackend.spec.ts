import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { HermesSessionBackend, hermesSessionBackendConfig, isChildSource, toEpochMs, type HostedRegistryLike } from './hermesSessionBackend.js'
import { sqliteReadAll } from './sqliteRead.js'

const hasSqlite = (() => {
  try { execFileSync('sqlite3', ['-version'], { stdio: 'ignore' }); return true } catch { return false }
})()
const d = hasSqlite ? describe : describe.skip

function run(db: string, sql: string): void {
  execFileSync('sqlite3', [db, sql], { stdio: ['ignore', 'ignore', 'inherit'] })
}
function makeStore(home: string): string {
  mkdirSync(home, { recursive: true })
  const db = join(home, 'state.db')
  run(db,
    'CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, cwd TEXT);'
    + 'CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_call_id TEXT,'
    + ' tool_calls TEXT, tool_name TEXT, finish_reason TEXT, reasoning TEXT, timestamp REAL);')
  return db
}
function addSession(db: string, id: string, source: string, cwd: string | null, prompt: string, atSec: number): void {
  run(db, `INSERT INTO sessions VALUES ('${id}', '${source}', ${cwd === null ? 'NULL' : `'${cwd}'`});`
    + `INSERT INTO messages (session_id, role, content, timestamp) VALUES ('${id}', 'user', '${prompt.replace(/'/g, "''")}', ${atSec});`
    + `INSERT INTO messages (session_id, role, content, finish_reason, timestamp) VALUES ('${id}', 'assistant', 'ok', 'stop', ${atSec + 1});`)
}

class FakeRegistry implements HostedRegistryLike {
  rows = new Map<string, { agentId: string; sessionId: string; active: boolean; hosted?: string; hermesHome: string | null; title: string | null; cwd: string | null; source: string }>()
  seq = 0
  bySession(sessionId: string) { return this.rows.get(sessionId) }
  registerHosted(input: { engine: 'hermes'; sessionId: string; hermesHome: string; source: string; cwd?: string | null; title?: string | null }) {
    if (this.rows.has(input.sessionId)) return { agentId: this.rows.get(input.sessionId)!.agentId, isNew: false }
    const agentId = `agent-${++this.seq}`
    this.rows.set(input.sessionId, { agentId, sessionId: input.sessionId, active: true, hosted: 'hermes-store', hermesHome: input.hermesHome, title: input.title ?? null, cwd: input.cwd ?? null, source: input.source })
    return { agentId, isNew: true }
  }
  setActive(agentId: string, active: boolean) {
    const row = [...this.rows.values()].find((r) => r.agentId === agentId)
    if (!row || row.active === active) return !!row
    row.active = active
    return true
  }
  remove(sessionId: string) { return this.rows.delete(sessionId) }
  hostedList(kind?: string) { return [...this.rows.values()].filter((r) => r.hosted && (!kind || r.hosted === kind)) }
}

const query = async (dbPath: string, sql: string, params: Array<string | number | null>) => {
  const r = await sqliteReadAll(dbPath, sql, params, { maxBuffer: 1 << 20 })
  return r.ok ? r.rows : null
}

describe('helpers', () => {
  it('reads seconds or milliseconds and knows child sources', () => {
    expect(toEpochMs(1_790_000_000.5)).toBe(1_790_000_000_500)
    expect(toEpochMs(1_790_000_000_500)).toBe(1_790_000_000_500)
    expect(toEpochMs('x')).toBe(0)
    expect(isChildSource('subagent')).toBe(true)
    expect(isChildSource('cli')).toBe(false)
    expect(isChildSource('desktop')).toBe(false)
  })
  it('config: off with 0 or false, custom idle window', () => {
    expect(hermesSessionBackendConfig({})).toEqual({ enabled: true, idleMs: 30 * 60 * 1000 })
    expect(hermesSessionBackendConfig({ HARNESS_HERMES_SESSIONS: '0' }).enabled).toBe(false)
    expect(hermesSessionBackendConfig({ HARNESS_HERMES_SESSIONS: 'false' }).enabled).toBe(false)
    expect(hermesSessionBackendConfig({ HARNESS_HERMES_SESSION_IDLE_MS: '60000' }).idleMs).toBe(60000)
  })
})

d('HermesSessionBackend (sqlite3 CLI)', () => {
  let root = ''
  let homeA = ''
  let homeB = ''
  let dbA = ''
  let dbB = ''
  const NOW = 1_790_000_000_000
  const nowSec = NOW / 1000
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'hermes-hosted-'))
    homeA = join(root, 'hermes'); homeB = join(root, 'hermes', 'profiles', 'aiona')
    dbA = makeStore(homeA); dbB = makeStore(homeB)
  })
  afterEach(() => { rmSync(root, { recursive: true, force: true }) })

  it('discovers live sessions in two homes, ignores idle and child sessions, registers once', async () => {
    addSession(dbA, '20260927_100000_aaaaaa', 'desktop', '/home/mike/smf', 'Draft the newsletter for   Monday', nowSec - 60)
    addSession(dbA, '20260927_090000_bbbbbb', 'cli', null, 'old one', nowSec - 3 * 3600)      // idle
    addSession(dbA, '20260927_100500_cccccc', 'subagent', null, 'child', nowSec - 30)       // child of a pane session
    addSession(dbB, '20260927_101000_dddddd', 'gateway', '/home/mike/podcast', 'Record the Tuesday episode', nowSec - 120)
    const reg = new FakeRegistry()
    const events: string[] = []
    const backend = new HermesSessionBackend({
      registry: reg, listHomes: async () => [homeA, homeB], query, now: () => NOW, idleMs: 30 * 60 * 1000,
      onNew: (a, s) => events.push(`new:${s}`), onRetired: (a, s) => events.push(`retired:${s}`), onVanished: (a, s) => events.push(`gone:${s}`),
    })
    const first = await backend.poll()
    expect(first.registered.sort()).toEqual(['20260927_100000_aaaaaa', '20260927_101000_dddddd'])
    expect(reg.rows.get('20260927_100000_aaaaaa')).toMatchObject({ hermesHome: homeA, source: 'desktop', cwd: '/home/mike/smf', title: 'Draft the newsletter for Monday', active: true })
    expect(reg.rows.get('20260927_101000_dddddd')).toMatchObject({ hermesHome: homeB, source: 'gateway' })
    expect(reg.rows.has('20260927_090000_bbbbbb')).toBe(false)
    expect(reg.rows.has('20260927_100500_cccccc')).toBe(false)
    const second = await backend.poll()
    expect(second).toEqual({ registered: [], retired: [], vanished: [] })
    expect(reg.rows.size).toBe(2)
    expect(events).toEqual(['new:20260927_100000_aaaaaa', 'new:20260927_101000_dddddd'])
  })

  it('retires a session that went quiet, wakes it on new activity, and forgets one deleted from the store', async () => {
    addSession(dbA, '20260927_100000_aaaaaa', 'desktop', null, 'hello', nowSec - 60)
    addSession(dbB, '20260927_101000_dddddd', 'gateway', null, 'hi', nowSec - 60)
    const reg = new FakeRegistry()
    let now = NOW
    const events: string[] = []
    const backend = new HermesSessionBackend({
      registry: reg, listHomes: async () => [homeA, homeB], query, now: () => now, idleMs: 10 * 60 * 1000,
      onNew: (a, s) => events.push(`new:${s}`), onRetired: (a, s) => events.push(`retired:${s}`), onVanished: (a, s) => events.push(`gone:${s}`),
    })
    await backend.poll()
    now += 20 * 60 * 1000 // both idle now
    const quiet = await backend.poll()
    expect(quiet.retired.sort()).toEqual(['20260927_100000_aaaaaa', '20260927_101000_dddddd'])
    expect(reg.rows.get('20260927_100000_aaaaaa')?.active).toBe(false)
    run(dbA, `INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20260927_100000_aaaaaa', 'user', 'again', ${(now / 1000) - 5});`)
    run(dbB, `DELETE FROM messages WHERE session_id = '20260927_101000_dddddd'; DELETE FROM sessions WHERE id = '20260927_101000_dddddd';`)
    const back = await backend.poll()
    expect(reg.rows.get('20260927_100000_aaaaaa')?.active).toBe(true)
    expect(back.vanished).toEqual(['20260927_101000_dddddd'])
    expect(reg.rows.has('20260927_101000_dddddd')).toBe(false)
    expect(events.slice(-2)).toEqual(['new:20260927_100000_aaaaaa', 'gone:20260927_101000_dddddd'])
  })

  it('leaves a pane-backed (non-hosted) row alone and never registers over it', async () => {
    addSession(dbA, '20260927_100000_aaaaaa', 'cli', null, 'from tmux', nowSec - 60)
    const reg = new FakeRegistry()
    reg.rows.set('20260927_100000_aaaaaa', { agentId: 'pane-agent', sessionId: '20260927_100000_aaaaaa', active: true, hermesHome: null, title: null, cwd: null, source: 'hook' })
    const backend = new HermesSessionBackend({ registry: reg, listHomes: async () => [homeA], query, now: () => NOW })
    expect((await backend.poll()).registered).toEqual([])
    expect(reg.rows.get('20260927_100000_aaaaaa')?.agentId).toBe('pane-agent')
  })

  it('never retires or forgets a watch-mode external row, which is not in any Hermes store', async () => {
    addSession(dbA, '20260927_100000_aaaaaa', 'cli', null, 'hello', nowSec - 60)
    const reg = new FakeRegistry()
    reg.rows.set('0f8fad5b-d9cb-469f-a165-70867728950e', { agentId: 'orca-agent', sessionId: '0f8fad5b-d9cb-469f-a165-70867728950e', active: true, hosted: 'external', hermesHome: null, title: null, cwd: null, source: 'external' })
    const backend = new HermesSessionBackend({ registry: reg, listHomes: async () => [homeA], query, now: () => NOW })
    const out = await backend.poll()
    expect(out.retired).toEqual([])
    expect(out.vanished).toEqual([])
    expect(reg.rows.get('0f8fad5b-d9cb-469f-a165-70867728950e')?.active).toBe(true)
  })

  it('does not forget anything when a store cannot be read', async () => {
    addSession(dbA, '20260927_100000_aaaaaa', 'desktop', null, 'hello', nowSec - 60)
    const reg = new FakeRegistry()
    const backend = new HermesSessionBackend({ registry: reg, listHomes: async () => [homeA], query, now: () => NOW })
    await backend.poll()
    const flaky = new HermesSessionBackend({
      registry: reg, listHomes: async () => [homeA, join(root, 'missing')], query, now: () => NOW + 60 * 60 * 1000,
    })
    const out = await flaky.poll()
    expect(out.vanished).toEqual([])
    expect(reg.rows.has('20260927_100000_aaaaaa')).toBe(true)
  })
})
