import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  EXTERNAL_OFFLINE_KEEP_MS,
  EXTERNAL_SESSIONS_FILE,
  ExternalWatchRows,
  createExternalWatch,
  discoverExternalSessions,
  engineAncestor,
  externalAgentFrame,
  externalCommand,
  externalStateFor,
  parseExternalHook,
  readExternalSessionsSwitch,
  readOwnerRecord,
  writeExternalSessionsSwitch,
  type ExternalHook,
} from './externalWatch.js'
import type { AgentFrame } from './agentFrame.js'
import { OpenSessions } from './sessionSearch/external.js'
import { claudeProvider } from './sessionSearch/externals/claude.js'
import type { ProcessView, RunningProcess } from './sessionSearch/externals/types.js'

const SESSION = '0f8fad5b-d9cb-469f-a165-70867728950e'
const ENGINE = { pid: 200, executable: 'claude', startMarker: 'Fri Oct  2 09:00:00 2026' }

function hook(event: ExternalHook['event'], extra: Partial<ExternalHook> = {}): ExternalHook {
  return { engine: 'claude', event, sessionId: SESSION, cwd: '/work/app', title: null, model: null, message: '', notificationType: '', callerPid: null, ...extra }
}

let dataDir = ''
beforeEach(() => { dataDir = mkdtempSync(join(tmpdir(), 'external-watch-')) })
afterEach(() => { rmSync(dataDir, { recursive: true, force: true }) })

describe('parseExternalHook', () => {
  it('keeps only known fields, bounded and without control characters', () => {
    const parsed = parseExternalHook({
      engine: 'claude', event: 'Notification', sessionId: SESSION.toUpperCase(), cwd: '/work/app',
      title: 'Fix\u0007 the build', model: 'claude-opus', message: 'x'.repeat(500), notificationType: 'permission_prompt',
      callerPid: 4242, token: 'secret', env: { HOME: '/home/someone' },
    })
    expect(parsed).toEqual({ ok: true, hook: {
      engine: 'claude', event: 'Notification', sessionId: SESSION, cwd: '/work/app', title: 'Fix the build',
      model: 'claude-opus', message: 'x'.repeat(160), notificationType: 'permission_prompt', callerPid: 4242,
    } })
  })

  it.each([
    [null, 'body'],
    [[], 'body'],
    [{ engine: 'cursor', event: 'Stop', sessionId: SESSION }, 'engine'],
    [{ engine: 'claude', event: 'PreToolUse', sessionId: SESSION }, 'event'],
    [{ engine: 'claude', event: 'Stop', sessionId: 'not-a-session' }, 'sessionId'],
    [{ engine: 'codex', event: 'Stop', sessionId: SESSION, cwd: 'relative/path' }, 'cwd'],
  ])('rejects %j (%s)', (body, reason) => {
    expect(parseExternalHook(body)).toEqual({ ok: false, reason })
  })

  it('drops a caller pid that cannot be a process', () => {
    for (const callerPid of [0, 1, -5, 1.5, '42']) {
      const parsed = parseExternalHook({ engine: 'codex', event: 'SessionStart', sessionId: SESSION, callerPid })
      expect(parsed.ok && parsed.hook.callerPid).toBeNull()
    }
  })
})

describe('externalStateFor', () => {
  it.each([
    ['SessionStart', {}, 'idle'],
    ['UserPromptSubmit', {}, 'working'],
    ['Stop', {}, 'done'],
    ['StopFailure', {}, 'failed'],
    ['SessionEnd', {}, 'offline'],
    ['Notification', { notificationType: 'permission_prompt', message: 'Claude needs your permission to use Bash' }, 'needsYou'],
    ['Notification', { notificationType: 'elicitation_dialog' }, 'needsYou'],
    ['Notification', { message: 'Claude needs your permission to use Write' }, 'needsYou'],
  ] as const)('%s %j is %s', (event, extra, state) => {
    expect(externalStateFor(hook(event, extra))?.state).toBe(state)
  })

  it('leaves the state alone for an idle reminder', () => {
    expect(externalStateFor(hook('Notification', { notificationType: 'idle_prompt', message: 'Claude is waiting for your input' }))).toBeNull()
  })
})

describe('the switch', () => {
  it('is off by default and when the file is unreadable', () => {
    expect(readExternalSessionsSwitch(dataDir, {})).toEqual({ enabled: false, source: 'default' })
    writeFileSync(join(dataDir, EXTERNAL_SESSIONS_FILE), '{not json')
    expect(readExternalSessionsSwitch(dataDir, {})).toEqual({ enabled: false, source: 'file' })
  })

  it('reads the saved file, and the environment overrides it', () => {
    writeExternalSessionsSwitch(dataDir, true)
    expect(JSON.parse(readFileSync(join(dataDir, EXTERNAL_SESSIONS_FILE), 'utf8'))).toEqual({ enabled: true })
    expect(readExternalSessionsSwitch(dataDir, {})).toEqual({ enabled: true, source: 'file' })
    expect(readExternalSessionsSwitch(dataDir, { HARNESS_EXTERNAL_SESSIONS: '0' })).toEqual({ enabled: false, source: 'env' })
    writeExternalSessionsSwitch(dataDir, false)
    expect(readExternalSessionsSwitch(dataDir, { HARNESS_EXTERNAL_SESSIONS: 'on' })).toEqual({ enabled: true, source: 'env' })
  })

  it('harness external on|off|status', () => {
    const run = (...argv: string[]) => {
      const out: string[] = [], err: string[] = []
      const code = externalCommand({ argv, dataDir, env: {}, output: (l) => out.push(l), error: (l) => err.push(l) })
      return { code, out, err }
    }
    expect(run('status').out[0]).toBe('external sessions: off')
    expect(run('on')).toMatchObject({ code: 0, out: ['external sessions: on', expect.stringContaining('Restart the daemon')] })
    expect(run('status', '--json').out).toEqual([JSON.stringify({ enabled: true, source: 'file' })])
    expect(run('off').out).toEqual(['external sessions: off'])
    expect(run('maybe')).toMatchObject({ code: 1, err: ['Unknown command: external maybe', expect.stringContaining('usage')] })
  })
})

describe('ExternalWatchRows', () => {
  it('follows a session from start to end and back', () => {
    const rows = new ExternalWatchRows()
    const started = rows.apply(hook('SessionStart', { title: 'Fix the build' }), { now: 1, process: ENGINE })
    expect(started).toMatchObject({ state: 'idle', cwd: '/work/app', title: 'Fix the build', process: ENGINE })
    const agentId = started!.agentId
    expect(rows.apply(hook('UserPromptSubmit', { cwd: null }), { now: 2 })).toMatchObject({ agentId, state: 'working', cwd: '/work/app' })
    expect(rows.apply(hook('Notification', { notificationType: 'permission_prompt', message: 'needs your permission' }), { now: 3 }))
      .toMatchObject({ state: 'needsYou', detail: 'needs your permission' })
    expect(rows.apply(hook('Stop'), { now: 4 })).toMatchObject({ state: 'done', detail: '' })
    expect(rows.apply(hook('StopFailure'), { now: 5 })).toMatchObject({ state: 'failed' })
    expect(rows.apply(hook('SessionEnd'), { now: 6 })).toMatchObject({ state: 'offline' })
    expect(rows.apply(hook('UserPromptSubmit'), { now: 7 })).toMatchObject({ agentId, state: 'working' })
    expect(rows.list()).toHaveLength(1)
  })

  it('never creates a row from an ending or a notification alone', () => {
    const rows = new ExternalWatchRows()
    expect(rows.apply(hook('SessionEnd'), { now: 1 })).toBeNull()
    expect(rows.apply(hook('Notification', { notificationType: 'permission_prompt' }), { now: 1 })).toBeNull()
    expect(rows.list()).toEqual([])
  })

  it('goes offline when its engine process is gone, and is forgotten later', () => {
    const rows = new ExternalWatchRows()
    rows.apply(hook('SessionStart'), { now: 0, process: ENGINE })
    rows.apply(hook('SessionStart', { sessionId: '1b4e28ba-2fa1-41d2-883f-0016d3cca427' }), { now: 0 })
    expect(rows.sweep(() => true, 10)).toEqual({ offline: [], removed: [] })
    const gone = rows.sweep(() => false, 20)
    expect(gone.offline.map((row) => row.sessionId)).toEqual([SESSION])
    expect(rows.sweep(() => false, 20 + EXTERNAL_OFFLINE_KEEP_MS - 1).removed).toEqual([])
    expect(rows.sweep(() => false, 20 + EXTERNAL_OFFLINE_KEEP_MS).removed.map((row) => row.sessionId)).toEqual([SESSION])
    // A row with no known process is ended only by its SessionEnd.
    expect(rows.list().map((row) => row.state)).toEqual(['idle'])
  })
})

describe('engineAncestor', () => {
  const rows = [
    { pid: 300, parentPid: 250, executable: 'node', startMarker: 'a' },
    { pid: 250, parentPid: 200, executable: 'sh', startMarker: 'b' },
    { pid: 200, parentPid: 1, executable: 'claude', startMarker: 'c' },
  ]
  it('walks up from the hook to the engine', () => {
    expect(engineAncestor(rows, 300, (row) => row.executable === 'claude')).toEqual({ pid: 200, executable: 'claude', startMarker: 'c' })
    expect(engineAncestor(rows, 300, () => false)).toBeNull()
    expect(engineAncestor(rows, 999, () => true)).toBeNull()
  })
})

describe('externalAgentFrame', () => {
  it('is read-only and marked external', () => {
    const rows = new ExternalWatchRows()
    const row = rows.apply(hook('UserPromptSubmit', { title: 'Fix the build', model: 'claude-opus' }), { now: Date.UTC(2026, 9, 2) })!
    const frame = externalAgentFrame(row, null)
    expect(frame).toMatchObject({
      id: row.agentId, sessionId: SESSION, name: 'app', title: 'Fix the build', status: 'active', engine: 'claude',
      selectedModel: 'claude-opus', tmuxPane: null, terminal: { available: false, primary: '', runtimes: [] },
      closeSupported: false, forkable: false, external: { state: 'working' },
    })
    rows.apply(hook('SessionEnd'), { now: Date.UTC(2026, 9, 2, 1) })
    expect(externalAgentFrame(row, null)).toMatchObject({ status: 'offline', external: { state: 'offline' } })
  })
})

describe('createExternalWatch', () => {
  function setup(table: Array<{ pid: number; parentPid: number; executable: string; startMarker: string }> | null = []) {
    const published: AgentFrame[] = []
    const removed: string[] = []
    let processes = table
    let now = 1_000
    const watch = createExternalWatch({
      dataDir, env: {}, owned: (sessionId) => sessionId === '9b2c1f1e-0000-4000-8000-000000000000',
      processes: async () => processes, isEngine: (row, engine) => row.executable === engine, selfPid: 50,
      project: async () => null, publish: (frame) => published.push(frame), remove: (id) => removed.push(id),
      now: () => now, log: () => {},
    })
    return { watch, published, removed, setProcesses: (rows: typeof table) => { processes = rows }, tick: (ms: number) => { now += ms } }
  }
  const body = (event: string, extra: Record<string, unknown> = {}) => ({ engine: 'claude', event, sessionId: SESSION, cwd: '/work/app', ...extra })

  it('ignores every hook while the switch is off', async () => {
    const { watch, published } = setup()
    expect(await watch.hook(body('SessionStart'))).toEqual({ ignored: true, reason: 'off' })
    expect(await watch.frames()).toEqual([])
    expect(published).toEqual([])
  })

  it('publishes rows, skips sessions Harness owns or spawned, and drops everything when switched off', async () => {
    writeExternalSessionsSwitch(dataDir, true)
    const { watch, published, removed } = setup([
      { pid: 60, parentPid: 50, executable: 'claude', startMarker: 'x' },
      { pid: 61, parentPid: 60, executable: 'sh', startMarker: 'y' },
      { pid: 200, parentPid: 1, executable: 'claude', startMarker: 'z' },
      { pid: 201, parentPid: 200, executable: 'sh', startMarker: 'w' },
    ])
    expect(await watch.hook(body('SessionStart', { sessionId: '9b2c1f1e-0000-4000-8000-000000000000' }))).toEqual({ ignored: true, reason: 'owned' })
    expect(await watch.hook(body('SessionStart', { callerPid: 61 }))).toEqual({ ignored: true, reason: 'harness_child' })
    expect(await watch.hook(body('Stop'))).toMatchObject({ ok: true, state: 'done' })
    expect(await watch.hook(body('bogus'))).toEqual({ ignored: true, reason: 'event' })
    expect(published.map((f) => f.external?.state)).toEqual(['done'])
    expect((await watch.frames()).map((f) => f.sessionId)).toEqual([SESSION])

    writeExternalSessionsSwitch(dataDir, false)
    await watch.sweep()
    expect(removed).toEqual([published[0]!.id])
    expect(await watch.frames()).toEqual([])
  })

  it('takes a row offline when its engine exits, then forgets it', async () => {
    writeExternalSessionsSwitch(dataDir, true)
    const table = [
      { pid: 200, parentPid: 1, executable: 'claude', startMarker: 'z' },
      { pid: 201, parentPid: 200, executable: 'sh', startMarker: 'w' },
    ]
    const { watch, published, removed, setProcesses, tick } = setup(table)
    await watch.hook(body('UserPromptSubmit', { callerPid: 201 }))
    await watch.sweep()
    expect(published.map((f) => f.status)).toEqual(['active'])
    // Same pid, a different process: the engine is gone.
    setProcesses([{ pid: 200, parentPid: 1, executable: 'claude', startMarker: 'later' }])
    await watch.sweep()
    expect(published.map((f) => f.status)).toEqual(['active', 'offline'])
    tick(EXTERNAL_OFFLINE_KEEP_MS)
    await watch.sweep()
    expect(removed).toEqual([published[0]!.id])
  })
})

describe('discovery without hooks', () => {
  const OTHER = '6c1e0a52-3b1f-4c55-9d1e-2f0f7a1b9c11'
  const RECORDS: Record<string, { cwd: string | null; entrypoint?: string; kind?: string } | null> = {
    '/r/sdk': { cwd: '/work/sdk', entrypoint: 'sdk-cli' },
    '/r/print': { cwd: '/work/print', kind: 'print' },
    '/r/unreadable': null,
  }
  const READ = async (owner: { record: string }) =>
    owner.record in RECORDS ? RECORDS[owner.record] : { cwd: '/work/app', kind: 'interactive', entrypoint: 'cli' }

  it('keeps only terminal sessions on exact evidence, never apps, Harness panes, SDK runs or its own data folder', async () => {
    const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`
    const owners = new Map([
      [id(1), { pid: 1, engine: 'claude', tty: '/dev/pts/3', record: '/r/linux' }],
      [id(2), { pid: 2, engine: 'codex', tty: '/dev/ttys004', record: '/r/macos' }],
      [id(3), { pid: 3, engine: 'claude', tty: null, record: '/r/app' }],
      [id(4), { pid: 4, engine: 'claude', tty: '/dev/pts/4', record: '/r/pane', harness: true }],
      [id(5), { pid: 5, engine: 'claude', tty: '/dev/pts/5', record: '/r/args', fromArgs: true }],
      [id(6), { pid: 6, engine: 'claude', tty: '/dev/pts/6', record: '/r/unsure', unverified: true }],
      [id(7), { pid: 7, engine: 'claude', tty: '/dev/pts/7', record: '/r/sdk' }],
      [id(8), { pid: 8, engine: 'claude', tty: '/dev/pts/8', record: '/r/print' }],
      [id(9), { pid: 9, engine: 'claude', tty: '/dev/pts/9', record: '/r/unreadable' }],
      [id(10), { pid: 10, engine: 'grok', tty: '/dev/pts/10', record: '/r/other' }],
      ['not-a-uuid', { pid: 11, engine: 'claude', tty: '/dev/pts/11', record: '/r/x' }],
      [id(12), { pid: 12, engine: 'claude', tty: '/dev/pts/12', record: '/r/mine' }],
    ] as const)
    const read = async (owner: { record: string }) => owner.record === '/r/mine' ? { cwd: join(dataDir, 'summary-scratch') } : READ(owner)
    expect(await discoverExternalSessions(new Map(owners), { dataDir, read: read as never })).toEqual([
      { engine: 'claude', sessionId: id(1), pid: 1, cwd: '/work/app' },
      { engine: 'codex', sessionId: id(2), pid: 2, cwd: '/work/app' },
    ])
  })

  it("reads a Claude record's folder, entrypoint and kind, and nothing from a missing one", async () => {
    const path = join(dataDir, '42.json')
    writeFileSync(path, JSON.stringify({ pid: 42, sessionId: SESSION, cwd: '/work/app', kind: 'interactive', entrypoint: 'cli' }))
    expect(await readOwnerRecord({ engine: 'claude', record: path })).toEqual({ cwd: '/work/app', kind: 'interactive', entrypoint: 'cli' })
    expect(await readOwnerRecord({ engine: 'claude', record: join(dataDir, 'gone.json') })).toBeNull()
    expect(await readOwnerRecord({ engine: 'grok', record: path })).toBeNull()
  })

  function setup(opts: { table?: Array<{ pid: number; parentPid: number; executable: string; startMarker: string }> | null; found?: Array<{ engine: 'claude' | 'codex'; sessionId: string; pid: number; cwd: string | null }> } = {}) {
    const published: AgentFrame[] = []
    let table = opts.table === undefined ? [ENGINE].map((p) => ({ ...p, parentPid: 1 })) : opts.table
    const watch = createExternalWatch({
      dataDir, env: { HARNESS_EXTERNAL_SESSIONS: '1' }, owned: (sessionId) => sessionId === OTHER,
      processes: async () => table, isEngine: (row, engine) => row.executable === engine, selfPid: 50,
      project: async () => null, publish: (frame) => published.push(frame), remove: () => {},
      discovered: async () => opts.found ?? [{ engine: 'claude', sessionId: SESSION, pid: ENGINE.pid, cwd: '/work/app' }],
      now: () => 1_000, log: () => {},
    })
    return { watch, published, setTable: (rows: typeof table) => { table = rows } }
  }

  it('lists a session that sent no hook as idle, once, and takes it offline when its process exits', async () => {
    const { watch, published, setTable } = setup()
    await watch.discover()
    await watch.discover()
    expect(published).toHaveLength(1)
    expect(published[0]).toMatchObject({ sessionId: SESSION, name: 'app', external: { state: 'idle' } })
    expect(watch.sessions.bySession(SESSION)?.process).toEqual(ENGINE)
    // Its next hook moves it on like any other row.
    await watch.hook({ engine: 'claude', event: 'UserPromptSubmit', sessionId: SESSION })
    expect(watch.sessions.bySession(SESSION)?.state).toBe('working')
    setTable([])
    await watch.sweep()
    expect(watch.sessions.bySession(SESSION)?.state).toBe('offline')
  })

  it("never lists a session the registry owns, one of the daemon's own children, or a pid now held by something else", async () => {
    const reused = { pid: 300, parentPid: 1, executable: 'zsh', startMarker: 'later' }
    const child = { pid: 400, parentPid: 50, executable: 'claude', startMarker: 'x' }
    const { watch, published } = setup({
      table: [reused, child],
      found: [
        { engine: 'claude', sessionId: OTHER, pid: 200, cwd: null },
        { engine: 'claude', sessionId: SESSION, pid: 300, cwd: null },
        { engine: 'claude', sessionId: '11111111-1111-4111-8111-111111111111', pid: 400, cwd: null },
        { engine: 'claude', sessionId: '22222222-2222-4222-8222-222222222222', pid: 999, cwd: null },
      ],
    })
    await watch.discover()
    expect(published).toEqual([])
  })

  it('does nothing where the process table cannot be read, or with the switch off', async () => {
    const unsupported = setup({ table: null })
    await unsupported.watch.discover()
    expect(unsupported.published).toEqual([])
    const off = createExternalWatch({
      dataDir, env: { HARNESS_EXTERNAL_SESSIONS: '0' }, owned: () => false, processes: async () => [{ ...ENGINE, parentPid: 1 }],
      isEngine: () => true, selfPid: 50, project: async () => null, publish: () => { throw new Error('published') }, remove: () => {},
      discovered: async () => [{ engine: 'claude', sessionId: SESSION, pid: 200, cwd: null }], log: () => {},
    })
    await off.discover()
    expect(off.sessions.list()).toEqual([])
  })

  describe('from OpenSessions', () => {
    const started = Date.parse('2026-10-02T09:00:00Z')
    function open(running: RunningProcess[], ttys: (pids: number[]) => Promise<Map<number, string | null>>) {
      const home = mkdtempSync(join(dataDir, 'claude-'))
      mkdirSync(join(home, 'sessions'))
      writeFileSync(join(home, 'sessions', '200.json'), JSON.stringify({ pid: 200, sessionId: SESSION, cwd: '/work/app', kind: 'interactive', entrypoint: 'cli', startedAt: started + 300 }))
      writeFileSync(join(home, 'sessions', '201.json'), JSON.stringify({ pid: 201, sessionId: OTHER, cwd: '/work/old', kind: 'interactive', entrypoint: 'cli', startedAt: started }))
      const view: ProcessView = { list: async () => running, openFiles: async () => new Map(), openFilesOf: async () => new Map(), alive: (pid) => running.some((p) => p.pid === pid) }
      return new OpenSessions({
        providers: [claudeProvider({ projectsDir: join(home, 'projects'), home })],
        view: () => view, ttys, harnessTtys: async () => new Set(),
      })
    }
    const claude = (pid: number, at = started): RunningProcess => ({ pid, ppid: 1, executable: 'claude', args: 'claude', started: at })

    it.each([
      ['Linux', '/dev/pts/3'],
      ['macOS', '/dev/ttys003'],
    ])('finds a live session on %s, and not one whose pid a later process reused', async (_os, tty) => {
      // 201's record is from a Claude that exited; its pid now belongs to a Claude started a minute later.
      const sessions = open([claude(200), claude(201, started + 60_000)], async (pids) => new Map(pids.map((pid) => [pid, tty])))
      expect(await discoverExternalSessions(await sessions.owners(), { dataDir })).toEqual([
        { engine: 'claude', sessionId: SESSION, pid: 200, cwd: '/work/app' },
      ])
    })

    it('finds nothing where processes cannot be listed', async () => {
      const sessions = open([], async () => { throw new Error('no ps') })
      expect(await discoverExternalSessions(await sessions.owners(), { dataDir })).toEqual([])
    })
  })
})
