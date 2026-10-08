import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

// External rows: live Claude/Codex sessions the daemon did not start (Orca terminals and the like),
// registered from their hooks by watch mode. See nixfred/orcaWatch.ts.
let dataDir = ''
const SID = '0f8fad5b-d9cb-469f-a165-70867728950e'
const TERM = 'term_15fd9a21-2ea5-4e58-ab61-1d555010bb22'

async function load() {
  vi.resetModules()
  process.env.ADAPTER_DATA_DIR = dataDir
  process.env.CLAUDE_PROJECTS_DIR = join(dataDir, 'projects')
  process.env.CODEX_HOME = join(dataDir, 'codex')
  return import('./registry.js')
}

function transcript(): string {
  const dir = join(dataDir, 'projects', '-home-u-proj')
  mkdirSync(dir, { recursive: true })
  const p = join(dir, `${SID}.jsonl`)
  writeFileSync(p, '{}\n')
  return p
}

describe('registerExternal', () => {
  beforeEach(() => { dataDir = mkdtempSync(join(tmpdir(), 'adapter-registry-ext-')) })
  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true })
    delete process.env.ADAPTER_DATA_DIR; delete process.env.CLAUDE_PROJECTS_DIR; delete process.env.CODEX_HOME
  })

  it('adds an advertised, memory-only row that carries its Orca terminal', async () => {
    const { registry } = await load()
    registry.load()
    const path = transcript()
    const out = registry.registerExternal({ engine: 'claude', sessionId: SID, cwd: '/home/u/proj', title: 'fix bar', transcriptPath: path, orca: { terminal: TERM, worktree: 'r::/home/u/proj' }, proc: { pid: 4242, start: 's1' } })
    expect(out).toMatchObject({ isNew: true })
    const row = registry.bySession(SID)!
    expect(row).toMatchObject({ hosted: 'external', engine: 'claude', active: true, cwd: '/home/u/proj', transcriptPath: path, runtimes: [], processIdentity: null })
    expect(row.external).toEqual({ orca: { terminal: TERM, worktree: 'r::/home/u/proj' }, herdr: null, inner: null, proc: { pid: 4242, start: 's1' } })
    expect(registry.advertised().map((r) => r.sessionId)).toContain(SID)
    expect(registry.hostedList('external').map((r) => r.sessionId)).toEqual([SID])
    expect(registry.hostedList('hermes-store')).toEqual([])
    registry.flush()
    const saved = existsSync(join(dataDir, 'registry.json')) ? readFileSync(join(dataDir, 'registry.json'), 'utf8') : '[]'
    expect(saved).not.toContain(SID)
  })

  it('carries a herdr pane and the innermost host, keeps them when a later hook has none, and never persists them', async () => {
    const { registry } = await load()
    registry.load()
    const herdr = { pane: 'w4F:p1', workspace: 'w4F', tab: 'w4F:t1', socket: '/home/u/.config/herdr/herdr.sock', bin: '/usr/bin/herdr' }
    registry.registerExternal({ engine: 'claude', sessionId: SID, cwd: '/home/u/proj', title: null, transcriptPath: null, orca: null, herdr, inner: 'herdr', proc: { pid: 9, start: 's9' } })
    expect(registry.bySession(SID)!.external).toEqual({ orca: null, herdr, inner: 'herdr', proc: { pid: 9, start: 's9' } })
    registry.registerExternal({ engine: 'claude', sessionId: SID, cwd: null, title: null, transcriptPath: null, orca: null, proc: null })
    expect(registry.bySession(SID)!.external).toEqual({ orca: null, herdr, inner: 'herdr', proc: { pid: 9, start: 's9' } })
    registry.flush()
    const saved = existsSync(join(dataDir, 'registry.json')) ? readFileSync(join(dataDir, 'registry.json'), 'utf8') : '[]'
    expect(saved).not.toContain('w4F')
  })

  it('is idempotent, refreshes the Orca ref and fills gaps, and reactivates a row that ended', async () => {
    const { registry } = await load()
    registry.load()
    const first = registry.registerExternal({ engine: 'claude', sessionId: SID, cwd: null, title: null, transcriptPath: null, orca: null, proc: null })!
    registry.setActive(first.agentId, false)
    const path = transcript()
    const again = registry.registerExternal({ engine: 'claude', sessionId: SID, cwd: '/home/u/proj', title: 'later', transcriptPath: path, orca: { terminal: TERM }, proc: { pid: 7, start: 's7' } })
    expect(again).toEqual({ agentId: first.agentId, isNew: false, reactivated: true })
    expect(registry.bySession(SID)).toMatchObject({ active: true, cwd: '/home/u/proj', transcriptPath: path, external: { orca: { terminal: TERM }, proc: { pid: 7, start: 's7' } } })
  })

  it('refuses a transcript outside the engine home, and never shadows a row the daemon owns', async () => {
    const { registry } = await load()
    registry.load()
    const stray = join(dataDir, 'elsewhere.jsonl')
    writeFileSync(stray, '{}\n')
    const out = registry.registerExternal({ engine: 'claude', sessionId: SID, cwd: null, title: null, transcriptPath: stray, orca: null, proc: null })!
    expect(registry.bySession(SID)?.transcriptPath).toBeNull()
    registry.remove(SID)
    expect(registry.byAgent(out.agentId)).toBeUndefined()
    // A hermes hosted row with the same id space is a different kind: never adopted as external.
    const hermes = registry.registerHosted({ engine: 'hermes', sessionId: '20260930_120000_abcdef', hermesHome: '/x', source: 'cli' })!
    expect(registry.registerExternal({ engine: 'claude', sessionId: SID, cwd: null, title: null, transcriptPath: null, orca: null, proc: null })).toMatchObject({ isNew: true })
    expect(registry.byAgent(hermes.agentId)?.hosted).toBe('hermes-store')
  })

  it('keeps hosted rows in memory across a save (they used to vanish on the first write)', async () => {
    const { registry } = await load()
    registry.load()
    const hermes = registry.registerHosted({ engine: 'hermes', sessionId: '20260930_120000_abcdef', hermesHome: '/x', source: 'cli' })!
    const ext = registry.registerExternal({ engine: 'claude', sessionId: SID, cwd: null, title: null, transcriptPath: null, orca: null, proc: null })!
    registry.setActive(ext.agentId, false) // any save
    registry.flush()
    expect(registry.byAgent(hermes.agentId)?.hosted).toBe('hermes-store')
    expect(registry.bySession(SID)?.active).toBe(false)
    expect(registry.hostedList().length).toBe(2)
  })
})
