import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  ExternalCaptureGate,
  ExternalTerminalRouter,
  HerdrCli,
  OrcaCli,
  applyOrcaWatchSwitch,
  attentionForExternalEvent,
  herdrKeyName,
  herdrRefFromEnv,
  herdrRowName,
  orcaKeyBytes,
  parseExternalHook,
  parseHerdrRef,
  readOrcaWatchConfig,
  selectExternalHost,
  type HerdrExec,
  type HerdrPaneInfo,
  type OrcaExec,
} from './orcaWatch.js'

const SID = '0f8fad5b-d9cb-469f-a165-70867728950e'
const TERM = 'term_15fd9a21-2ea5-4e58-ab61-1d555010bb22'
const dirs: string[] = []
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }) })
function tmp(): string { const d = mkdtempSync(join(tmpdir(), 'orca-watch-')); dirs.push(d); return d }

describe('parseExternalHook', () => {
  const base = { engine: 'claude', event: 'SessionStart', sessionId: SID, cwd: '/home/u/proj', transcriptPath: '/home/u/.claude/projects/x/a.jsonl' }

  it('accepts a claude SessionStart with Orca ids and keeps only the fields it knows', () => {
    const r = parseExternalHook({ ...base, title: 'fix the bar', orca: { terminal: TERM, worktree: 'repo::/home/u/proj', tab: 't1', pane: 'p:1', token: 'SECRET' }, extra: 'x' })
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.event).toMatchObject({ engine: 'claude', event: 'SessionStart', sessionId: SID, cwd: '/home/u/proj', title: 'fix the bar' })
    expect(r.event.orca).toEqual({ terminal: TERM, worktree: 'repo::/home/u/proj', tab: 't1', pane: 'p:1' })
    expect(JSON.stringify(r.event)).not.toContain('SECRET')
  })

  it('rejects unknown engines, events and malformed ids', () => {
    expect(parseExternalHook({ ...base, engine: 'grok' })).toEqual({ ok: false, reason: 'engine' })
    expect(parseExternalHook({ ...base, event: 'PreToolUse' })).toEqual({ ok: false, reason: 'event' })
    expect(parseExternalHook({ ...base, sessionId: '../../etc' })).toEqual({ ok: false, reason: 'session_id' })
    expect(parseExternalHook({ ...base, cwd: 'relative/path' })).toEqual({ ok: false, reason: 'cwd' })
    expect(parseExternalHook(null)).toEqual({ ok: false, reason: 'body' })
  })

  it('drops an Orca terminal handle that is not a runtime handle, but keeps the row', () => {
    const r = parseExternalHook({ ...base, orca: { terminal: 'term_x; rm -rf /' } })
    expect(r.ok && r.event.orca).toBeNull()
  })

  it('clips prompt and message and strips control characters', () => {
    const r = parseExternalHook({ ...base, event: 'UserPromptSubmit', prompt: `a\u0007b${'x'.repeat(500)}` })
    expect(r.ok && r.event.prompt.length).toBe(160)
    expect(r.ok && r.event.prompt.startsWith('ab')).toBe(true)
  })
})

describe('attentionForExternalEvent', () => {
  const ev = (event: string, extra: Record<string, unknown> = {}) => {
    const r = parseExternalHook({ engine: 'claude', event, sessionId: SID, ...extra })
    if (!r.ok) throw new Error(r.reason)
    return r.event
  }
  it('maps the hook lifecycle to attention states', () => {
    expect(attentionForExternalEvent(ev('SessionStart'))).toEqual({ state: 'idle', detail: 'watching' })
    expect(attentionForExternalEvent(ev('UserPromptSubmit', { prompt: 'ship it' }))).toEqual({ state: 'working', detail: 'ship it' })
    expect(attentionForExternalEvent(ev('Stop'))).toEqual({ state: 'done', detail: '' })
    expect(attentionForExternalEvent(ev('StopFailure'))).toEqual({ state: 'failed', detail: 'engine ended the turn with an error' })
    expect(attentionForExternalEvent(ev('SessionEnd'))).toEqual({ state: 'offline', detail: '' })
  })
  it('reads permission and waiting out of Notification', () => {
    expect(attentionForExternalEvent(ev('Notification', { notificationType: 'permission_prompt', message: 'Claude needs your permission to use Bash' })))
      .toEqual({ state: 'permission', detail: 'Claude needs your permission to use Bash' })
    expect(attentionForExternalEvent(ev('Notification', { message: 'Claude needs your permission to use Write' }))?.state).toBe('permission')
    expect(attentionForExternalEvent(ev('Notification', { notificationType: 'elicitation_dialog', message: 'Pick one' }))?.state).toBe('waiting')
    expect(attentionForExternalEvent(ev('Notification', { notificationType: 'idle_prompt', message: 'Claude is waiting for your input' }))).toBeNull()
  })
})

describe('the switch', () => {
  it('is off by default and persists on/off/answers', () => {
    const dir = tmp()
    expect(readOrcaWatchConfig(dir, {})).toMatchObject({ enabled: false, answers: false, source: 'default' })
    expect(applyOrcaWatchSwitch(dir, 'on', {})).toMatchObject({ enabled: true, answers: true })
    expect(JSON.parse(readFileSync(join(dir, 'orca-watch.json'), 'utf8'))).toMatchObject({ enabled: true, answers: true })
    expect(applyOrcaWatchSwitch(dir, 'answers-off', {})).toMatchObject({ enabled: true, answers: false })
    expect(applyOrcaWatchSwitch(dir, 'off', {})).toMatchObject({ enabled: false, answers: false })
  })
  it('lets the environment force it either way', () => {
    const dir = tmp()
    applyOrcaWatchSwitch(dir, 'on', {})
    expect(readOrcaWatchConfig(dir, { HARNESS_ORCA_WATCH: '0' })).toMatchObject({ enabled: false, answers: false, source: 'env' })
    expect(readOrcaWatchConfig(tmp(), { HARNESS_ORCA_WATCH: '1', HARNESS_ORCA_ANSWERS: '0' })).toMatchObject({ enabled: true, answers: false })
  })
  it('treats a corrupt file as off', () => {
    const dir = tmp()
    writeFileSync(join(dir, 'orca-watch.json'), '{nope')
    expect(readOrcaWatchConfig(dir, {}).enabled).toBe(false)
  })
})

describe('orcaKeyBytes', () => {
  it('translates the driver key vocabulary to terminal bytes', () => {
    expect(orcaKeyBytes('Enter')).toBe('\r')
    expect(orcaKeyBytes('Escape')).toBe('\x1b')
    expect(orcaKeyBytes('Tab')).toBe('\t')
    expect(orcaKeyBytes('Down')).toBe('\x1b[B')
    expect(orcaKeyBytes('3')).toBe('3')
  })
  it('refuses the keys that would stop or kill the session', () => {
    expect(orcaKeyBytes('C-c')).toBeNull()
    expect(orcaKeyBytes('C-d')).toBeNull()
    expect(orcaKeyBytes('rm -rf')).toBeNull()
  })
})

function fakeExec(screen: string[] = ['line']): OrcaExec & { calls: string[][] } {
  const calls: string[][] = []
  const fn = (async (_bin: string, args: string[]) => {
    calls.push(args)
    if (args[1] === 'read') return JSON.stringify({ ok: true, result: { terminal: { handle: TERM, status: 'running', tail: screen } } })
    if (args[1] === 'send') return JSON.stringify({ ok: true, result: { send: { handle: TERM, accepted: true } } })
    return JSON.stringify({ ok: false, error: { message: 'nope' } })
  }) as unknown as OrcaExec & { calls: string[][] }
  fn.calls = calls
  return fn
}

describe('OrcaCli', () => {
  it('reads the rendered screen and sends text and keys as argv, never through a shell', async () => {
    const exec = fakeExec(['❯ 1. Yes', '  2. No'])
    const orca = new OrcaCli({ bin: 'orca', exec })
    expect(await orca.readScreen(TERM)).toBe('❯ 1. Yes\n  2. No')
    expect(exec.calls[0]).toEqual(['terminal', 'read', '--terminal', TERM, '--screen', '--json'])
    expect(await orca.send(TERM, 'hello; rm -rf /')).toBe(true)
    expect(exec.calls[1]).toEqual(['terminal', 'send', '--terminal', TERM, '--text', 'hello; rm -rf /', '--json'])
  })
  it('reports failure when orca says not ok or throws', async () => {
    const orca = new OrcaCli({ bin: 'orca', exec: async () => { throw new Error('ENOENT') } })
    expect(await orca.readScreen(TERM)).toBeNull()
    expect(await orca.send(TERM, 'x')).toBe(false)
    const refused = new OrcaCli({ bin: 'orca', exec: async () => JSON.stringify({ ok: true, result: { send: { accepted: false } } }) })
    expect(await refused.send(TERM, 'x')).toBe(false)
  })
})

describe('ExternalCaptureGate', () => {
  it('reads fresh while a dialog is hinted, and otherwise at most once per idle window, replaying the last screen', async () => {
    let now = 1_000
    const read = vi.fn(async () => `screen@${now}`)
    const gate = new ExternalCaptureGate({ idleCaptureMs: 8_000, now: () => now })
    expect(await gate.capture(SID, read)).toBe('screen@1000')
    now = 2_000
    expect(await gate.capture(SID, read)).toBe('screen@1000') // throttled: replay, not null (null reads as "dialog gone")
    expect(read).toHaveBeenCalledTimes(1)
    gate.hint(SID)
    expect(await gate.capture(SID, read)).toBe('screen@2000')
    now = 3_000
    expect(await gate.capture(SID, read)).toBe('screen@3000')
    gate.clear(SID)
    now = 4_000
    expect(await gate.capture(SID, read)).toBe('screen@3000')
    now = 11_001
    expect(await gate.capture(SID, read)).toBe('screen@11001')
  })
  it('never reads when idle capture is disabled and no dialog is hinted', async () => {
    const read = vi.fn(async () => 'x')
    const gate = new ExternalCaptureGate({ idleCaptureMs: 0, now: () => 0 })
    expect(await gate.capture(SID, read)).toBeNull()
    expect(read).not.toHaveBeenCalled()
  })
  it('lets a hint expire so a missed clear cannot pin fresh reads forever', async () => {
    let now = 0
    const read = vi.fn(async () => 'x')
    const gate = new ExternalCaptureGate({ idleCaptureMs: 0, hintTtlMs: 1_000, now: () => now })
    gate.hint(SID)
    expect(gate.hinted(SID)).toBe(true)
    now = 1_001
    expect(gate.hinted(SID)).toBe(false)
  })
})

describe('ExternalTerminalRouter', () => {
  const orcaRow = { agentId: 'a1', sessionId: SID, hosted: 'external' as const, external: { orca: { terminal: TERM } } }
  const tmuxRow = { agentId: 'a2', sessionId: 'tmux-sid', runtimes: [{ backend: 'tmux', paneId: '%3' }] }
  const plainExternal = { agentId: 'a3', sessionId: 's3', hosted: 'external' as const, external: { orca: null } }

  function setup(opts: { answers?: boolean } = {}) {
    const exec = fakeExec(['❯ 1. Yes'])
    const audit = vi.fn()
    const fallback = { capture: vi.fn(async () => 'tmux screen'), sendText: vi.fn(async () => true), sendKey: vi.fn(async () => true), acquireControl: vi.fn(() => () => {}) }
    const rows: Record<string, unknown> = { a1: orcaRow, [SID]: orcaRow, a2: tmuxRow, 'tmux-sid': tmuxRow, a3: plainExternal, s3: plainExternal }
    const router = new ExternalTerminalRouter({
      resolve: (id) => rows[id] as never,
      orca: new OrcaCli({ bin: 'orca', exec }),
      answersEnabled: () => opts.answers ?? true,
      gate: new ExternalCaptureGate({ idleCaptureMs: 0, now: () => 0 }),
      fallback,
      audit,
    })
    return { router, exec, audit, fallback }
  }

  it('routes an Orca row to the orca CLI and logs every send', async () => {
    const { router, exec, audit, fallback } = setup()
    expect(await router.answerDeps.capture('a1')).toBe('❯ 1. Yes')
    expect(await router.answerDeps.sendKey('a1', '1')).toBe(true)
    expect(await router.answerDeps.sendText('a1', 'blue')).toBe(true)
    expect(exec.calls.map((c) => c[1])).toEqual(['read', 'send', 'send'])
    expect(exec.calls[1]).toContain('1')
    expect(fallback.sendKey).not.toHaveBeenCalled()
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ agentId: 'a1', route: 'orca', what: 'key', value: '1', ok: true }))
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ route: 'orca', what: 'text', value: 'blue', ok: true }))
    expect(router.answerDeps.acquireControl?.(SID)).toBeTypeOf('function')
  })

  it('falls back to the tmux path for a pane row, untouched', async () => {
    const { router, exec, fallback } = setup()
    expect(await router.answerDeps.capture('a2')).toBe('tmux screen')
    expect(await router.answerDeps.sendKey('a2', 'Enter')).toBe(true)
    expect(fallback.sendKey).toHaveBeenCalledWith('a2', 'Enter')
    expect(exec.calls).toHaveLength(0)
  })

  it('refuses to type into an external row with no Orca terminal, and refuses kill keys', async () => {
    const { router, audit } = setup()
    expect(await router.answerDeps.sendKey('a3', '1')).toBe(false)
    expect(await router.answerDeps.sendKey('a1', 'C-c')).toBe(false)
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ agentId: 'a3', ok: false, route: 'none' }))
  })

  it('sends nothing into Orca while answers are switched off, but still reads', async () => {
    const { router, exec } = setup({ answers: false })
    expect(await router.answerDeps.capture('a1')).toBe('❯ 1. Yes')
    expect(await router.answerDeps.sendKey('a1', '1')).toBe(false)
    expect(exec.calls.map((c) => c[1])).toEqual(['read'])
  })

  it('hands upstream\'s native question steps an Orca write for an Orca row, and nothing for a pane row', async () => {
    // core/main.ts question controls (#1040): the engine's own navigation decides the keys; for an Orca row
    // each one is typed into its Orca terminal, audited, and a pane row keeps the stock terminal write.
    const { router, exec, audit, fallback } = setup()
    const orca = router.controlWrite('a1')
    expect(orca).toBeDefined()
    expect(await orca!.key('2')).toBe(true)
    expect(await orca!.text('teal')).toBe(true)
    expect(exec.calls.map((c) => c[1])).toEqual(['send', 'send'])
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ agentId: 'a1', route: 'orca', what: 'key', value: '2', ok: true }))
    expect(router.controlWrite('a2')).toBeUndefined()
    expect(router.controlWrite('unknown')).toBeUndefined()
    expect(fallback.sendKey).not.toHaveBeenCalled()
    // An external row without an Orca terminal still gets a write that refuses, never the pane path.
    expect(await router.controlWrite('a3')!.key('1')).toBe(false)
  })

  it('watcher capture goes through the gate; answer capture is always fresh', async () => {
    const { router, exec } = setup()
    expect(await router.watcherCapture('a1')).toBeNull()          // idle 0, no hint: no read at all
    router.gate.hint(SID)
    expect(await router.watcherCapture('a1')).toBe('❯ 1. Yes')
    expect(await router.watcherCapture('a2')).toBe('tmux screen') // pane rows are never gated
    expect(exec.calls.map((c) => c[1])).toEqual(['read'])
  })
})

describe('engine process liveness', () => {
  const table: Record<number, { comm: string; exe: string; ppid: number; start: string }> = {
    500: { comm: 'bash', exe: '/usr/bin/bash', ppid: 400, start: 's500' },   // the hook's shell
    400: { comm: 'claude', exe: '/home/u/.local/claude/2.1/claude', ppid: 300, start: 's400' },
    300: { comm: 'bash', exe: '/usr/bin/bash', ppid: 200, start: 's300' },
    200: { comm: 'orca-ide', exe: '/tmp/.mount/orca-ide', ppid: 1, start: 's200' },
    700: { comm: 'node', exe: '/usr/bin/node', ppid: 600, start: 's700' },
    600: { comm: 'MainThread', exe: '/opt/codex/bin/codex', ppid: 1, start: 's600' },
  }
  const read = (pid: number) => table[pid] ?? null

  it('walks up from the hook caller to the engine process', async () => {
    const { findEngineAncestor } = await import('./orcaWatch.js')
    expect(findEngineAncestor(500, 'claude', read)).toEqual({ pid: 400, start: 's400' })
    expect(findEngineAncestor(400, 'claude', read)).toEqual({ pid: 400, start: 's400' })
    expect(findEngineAncestor(700, 'codex', read)).toEqual({ pid: 600, start: 's600' }) // matched by exe name
    expect(findEngineAncestor(300, 'claude', read)).toBeNull()
    expect(findEngineAncestor(999, 'claude', read)).toBeNull()
  })

  it('treats a reused pid as dead', async () => {
    const { engineStillRunning } = await import('./orcaWatch.js')
    expect(engineStillRunning({ pid: 400, start: 's400' }, read)).toBe(true)
    expect(engineStillRunning({ pid: 400, start: 'other' }, read)).toBe(false)
    expect(engineStillRunning({ pid: 999, start: 'x' }, read)).toBe(false)
  })
})

// ── herdr (2026-10-08: Fred's host again) ────────────────────────────────────────────────────────────

describe('herdr ids', () => {
  const base = { engine: 'claude', event: 'SessionStart', sessionId: SID, cwd: '/home/u/proj' }
  const good = { pane: 'w4F:p1', tab: 'w4F:t1', workspace: 'w4F', socket: '/home/u/.config/herdr/herdr.sock', bin: '/usr/bin/herdr' }

  it('keeps a well-formed herdr block from the hook, and nothing else in it', () => {
    const r = parseExternalHook({ ...base, herdr: { ...good, token: 'SECRET' } })
    expect(r.ok && r.event.herdr).toEqual(good)
    expect(JSON.stringify(r)).not.toContain('SECRET')
  })

  it('drops the block for a hostile pane id and the field for each hostile value', () => {
    for (const pane of ['w4F:p1; rm -rf /', 'w4F', '../x', 'w4F:p1\n', 'a'.repeat(17) + ':p1', '']) {
      const r = parseExternalHook({ ...base, herdr: { ...good, pane } })
      expect(r.ok && r.event.herdr).toBeNull()
    }
    const r = parseExternalHook({ ...base, herdr: { pane: 'w4F:p1', tab: '$(id)', workspace: 'w4F:t1', socket: 'rel.sock', bin: '/tmp/x/sh' } })
    expect(r.ok && r.event.herdr).toEqual({ pane: 'w4F:p1' })
    expect(parseHerdrRef({ pane: 'w4F:p1', socket: '/a/../../etc/s.sock', bin: '/opt/../usr/bin/herdr' })).toEqual({ pane: 'w4F:p1' })
    expect(parseHerdrRef({ pane: 'w4F:p1', socket: '/run/a\u0007b.sock', bin: '/home/u/.local/bin/herdr' })).toEqual({ pane: 'w4F:p1', bin: '/home/u/.local/bin/herdr' })
    expect(parseHerdrRef('w4F:p1')).toBeNull()
    expect(parseHerdrRef([good])).toBeNull()
  })

  it('reads the same ids from a process environment', () => {
    const vars = new Map(Object.entries({ HERDR_PANE_ID: 'w4F:p1', HERDR_TAB_ID: 'w4F:t1', HERDR_WORKSPACE_ID: 'w4F', HERDR_SOCKET_PATH: good.socket, HERDR_BIN_PATH: good.bin, HERDR_ENV: '1' }))
    expect(herdrRefFromEnv(vars)).toEqual(good)
    expect(herdrRefFromEnv({ HERDR_ENV: '1' })).toBeNull()
  })
})

describe('herdrKeyName', () => {
  it('maps the driver key vocabulary to herdr send-keys names', () => {
    expect(herdrKeyName('Enter')).toBe('enter')
    expect(herdrKeyName('Escape')).toBe('esc')
    expect(herdrKeyName('Tab')).toBe('tab')
    expect(herdrKeyName('BTab')).toBe('shift+tab')
    expect(herdrKeyName('Up')).toBe('up')
    expect(herdrKeyName('Down')).toBe('down')
    expect(herdrKeyName('Left')).toBe('left')
    expect(herdrKeyName('Right')).toBe('right')
    expect(herdrKeyName('BSpace')).toBe('backspace')
    expect(herdrKeyName('Space')).toBe('space')
    expect(herdrKeyName('C-u')).toBe('ctrl+u')
    expect(herdrKeyName('7')).toBe('7')
  })
  it('refuses kill keys, keys herdr 0.9 cannot send, and anything unknown', () => {
    for (const k of ['C-c', 'C-d', 'Home', 'End', 'DC', 'PPage', 'NPage', 'rm -rf', 'enter', '']) expect(herdrKeyName(k)).toBeNull()
  })
})

describe('selectExternalHost', () => {
  const orca = { terminal: TERM }
  const herdr = { pane: 'w4F:p1' }
  it('herdr only, Orca only', () => {
    expect(selectExternalHost({ orca: null, herdr })).toBe('herdr')
    expect(selectExternalHost({ orca, herdr: null })).toBe('orca')
    expect(selectExternalHost({ orca: null, herdr: null })).toBeNull()
    expect(selectExternalHost(null)).toBeNull()
  })
  it('both: the innermost host wins; herdr when the parent chain is unknown', () => {
    expect(selectExternalHost({ orca, herdr, inner: 'herdr' })).toBe('herdr')
    expect(selectExternalHost({ orca, herdr, inner: 'orca' })).toBe('orca')
    expect(selectExternalHost({ orca, herdr, inner: null })).toBe('herdr')
  })
  it('never types into an outer host: tmux innermost, or the innermost host without its ref', () => {
    expect(selectExternalHost({ orca, herdr, inner: 'tmux' })).toBeNull()
    expect(selectExternalHost({ orca, herdr: null, inner: 'herdr' })).toBeNull()
    expect(selectExternalHost({ orca: null, herdr, inner: 'orca' })).toBeNull()
  })
})

const HSOCK = '/tmp/hh/herdr.sock'
const HBIN = '/opt/herdr/bin/herdr'
function herdrPane(over: Record<string, unknown> = {}) {
  return { pane_id: 'w4F:p1', tab_id: 'w4F:t1', workspace_id: 'w4F', agent: 'claude', agent_session: { agent: 'claude', kind: 'id', source: 'herdr:claude', value: SID }, ...over }
}
function fakeHerdr(state: { panes: Array<Record<string, unknown>>; screen?: string; failSend?: boolean } = { panes: [herdrPane()] }) {
  const calls: Array<{ bin: string; args: string[]; env: NodeJS.ProcessEnv }> = []
  const exec: HerdrExec = async (bin, args, env) => {
    calls.push({ bin, args, env })
    const [noun, verb, id] = args
    if (noun === 'pane' && verb === 'get') {
      const p = state.panes.find((x) => x.pane_id === id)
      if (!p) throw new Error('{"error":{"code":"pane_not_found"}}')
      return JSON.stringify({ id: 'cli:pane:get', result: { pane: p, type: 'pane_info' } })
    }
    if (noun === 'pane' && verb === 'list') return JSON.stringify({ id: 'cli:pane:list', result: { panes: state.panes, type: 'pane_list' } })
    if (noun === 'pane' && verb === 'read') return `${state.screen ?? '❯ 1. Yes\n  2. No'}\n\n`
    if (noun === 'pane' && (verb === 'send-text' || verb === 'send-keys')) {
      if (state.failSend || !state.panes.some((x) => x.pane_id === id)) throw new Error('pane_not_found')
      return ''
    }
    if (noun === 'workspace' && verb === 'list') return JSON.stringify({ result: { workspaces: [{ workspace_id: 'w4F', label: 'Blip:gus:herdr' }, { workspace_id: 'w9', label: 'flea' }] } })
    if (noun === 'tab' && verb === 'list') return JSON.stringify({ result: { tabs: [{ tab_id: 'w4F:t1', label: '1' }, { tab_id: 'w4F:t2', label: 'review' }] } })
    throw new Error(`unexpected ${args.join(' ')}`)
  }
  return { exec, calls, state }
}

describe('HerdrCli', () => {
  it('runs herdr as argv against the row\'s own socket and binary, never the daemon\'s HERDR_* env', async () => {
    const h = fakeHerdr()
    const cli = new HerdrCli({ exec: h.exec, env: { PATH: '/usr/bin', HERDR_SOCKET_PATH: '/home/fred/.config/herdr/herdr.sock', HERDR_PANE_ID: 'w1:p1' } })
    const ref = { pane: 'w4F:p1', socket: HSOCK, bin: HBIN }
    expect(await cli.sendText(ref, 'hello; rm -rf /')).toBe(true)
    expect(await cli.sendKey(ref, 'enter')).toBe(true)
    expect(await cli.read(ref)).toBe('❯ 1. Yes\n  2. No')
    expect(await cli.read(ref, 40)).toBe('❯ 1. Yes\n  2. No')
    expect(h.calls.map((c) => [c.bin, ...c.args])).toEqual([
      [HBIN, 'pane', 'send-text', 'w4F:p1', 'hello; rm -rf /'],
      [HBIN, 'pane', 'send-keys', 'w4F:p1', 'enter'],
      [HBIN, 'pane', 'read', 'w4F:p1', '--source', 'visible', '--format', 'text'],
      [HBIN, 'pane', 'read', 'w4F:p1', '--source', 'recent', '--lines', '40', '--format', 'text'],
    ])
    for (const c of h.calls) {
      expect(c.env.HERDR_SOCKET_PATH).toBe(HSOCK)
      expect(c.env.HERDR_PANE_ID).toBeUndefined()
      expect(c.env.PATH).toBe('/usr/bin')
    }
  })
  it('without a socket on the row, no HERDR_SOCKET_PATH is passed at all (herdr uses its default)', async () => {
    const h = fakeHerdr()
    const cli = new HerdrCli({ exec: h.exec, env: { HERDR_SOCKET_PATH: '/elsewhere.sock' } })
    await cli.paneGet({ pane: 'w4F:p1', bin: HBIN })
    expect(h.calls[0]!.env.HERDR_SOCKET_PATH).toBeUndefined()
  })
  it('reads pane identity, and reports failure as null/false', async () => {
    const h = fakeHerdr()
    const cli = new HerdrCli({ exec: h.exec, bin: HBIN })
    expect(await cli.paneGet({ pane: 'w4F:p1' })).toEqual({ pane: 'w4F:p1', workspace: 'w4F', tab: 'w4F:t1', agent: 'claude', agentSession: SID })
    expect(await cli.paneGet({ pane: 'w9:p9' })).toBeNull()
    expect(await cli.sendText({ pane: 'w9:p9' }, 'x')).toBe(false)
    expect(await new HerdrCli({ bin: null }).sendText({ pane: 'w4F:p1' }, 'x')).toBe(false)
  })
})

describe('herdrRowName', () => {
  const labels = (panes: HerdrPaneInfo[]) => ({ workspaces: new Map([['w4F', 'Blip:gus:herdr']]), tabs: new Map([['w4F:t1', '1'], ['w4F:t2', 'review']]), panes })
  const p = (pane: string, tab: string, session: string | null): HerdrPaneInfo => ({ pane, workspace: 'w4F', tab, agent: 'claude', agentSession: session })
  it('is the workspace label for the only agent in its workspace', () => {
    expect(herdrRowName(SID, { pane: 'w4F:p1' }, labels([p('w4F:p1', 'w4F:t1', SID)]))).toBe('Blip:gus:herdr')
  })
  it('adds the tab label, or the pane id when the tab is only numbered, when agents share the workspace', () => {
    const two = labels([p('w4F:p1', 'w4F:t1', SID), p('w4F:p2', 'w4F:t2', 'other')])
    expect(herdrRowName(SID, { pane: 'w4F:p1' }, two)).toBe('Blip:gus:herdr · p1')
    expect(herdrRowName('other', { pane: 'w4F:p2' }, two)).toBe('Blip:gus:herdr · review')
  })
  it('follows a moved pane by its session, and is null with no label', () => {
    expect(herdrRowName(SID, { pane: 'w1:p1', workspace: 'w1' }, labels([p('w4F:p3', 'w4F:t1', SID)]))).toBe('Blip:gus:herdr')
    expect(herdrRowName(SID, { pane: 'w1:p1', workspace: 'w1' }, labels([]))).toBeNull()
  })
})

describe('ExternalTerminalRouter: herdr rows', () => {
  const herdrRef = { pane: 'w4F:p1', workspace: 'w4F', tab: 'w4F:t1', socket: HSOCK, bin: HBIN }
  function setup(opts: { answers?: boolean; panes?: Array<Record<string, unknown>>; row?: Record<string, unknown> } = {}) {
    const h = fakeHerdr({ panes: opts.panes ?? [herdrPane()] })
    const orcaExec = fakeExec(['orca screen'])
    const audit = vi.fn()
    const fallback = { capture: vi.fn(async () => 'tmux screen'), sendText: vi.fn(async () => true), sendKey: vi.fn(async () => true), acquireControl: vi.fn(() => () => {}) }
    const row = { agentId: 'h1', sessionId: SID, engine: 'claude', hosted: 'external' as const, external: { orca: null, herdr: { ...herdrRef }, inner: 'herdr' as const }, ...opts.row }
    const rows: Record<string, unknown> = { h1: row, [SID]: row }
    const router = new ExternalTerminalRouter({
      resolve: (id) => rows[id] as never,
      orca: new OrcaCli({ bin: 'orca', exec: orcaExec }),
      herdr: new HerdrCli({ exec: h.exec, env: {} }),
      answersEnabled: () => opts.answers ?? true,
      gate: new ExternalCaptureGate({ idleCaptureMs: 0, now: () => 0 }),
      fallback,
      audit,
    })
    const verbs = () => h.calls.map((c) => `${c.args[0]} ${c.args[1]}`)
    return { router, h, orcaExec, audit, fallback, row, verbs }
  }

  it('reads, answers with keys and text, each checked against the pane first and audited', async () => {
    const { router, h, audit, fallback, orcaExec, verbs } = setup()
    expect(await router.answerDeps.capture('h1')).toBe('❯ 1. Yes\n  2. No')
    expect(await router.answerDeps.sendKey('h1', 'Down')).toBe(true)
    expect(await router.answerDeps.sendKey('h1', 'Escape')).toBe(true)
    expect(await router.answerDeps.sendText('h1', 'blue\u0007')).toBe(true)
    expect(verbs()).toEqual(['pane get', 'pane read', 'pane get', 'pane send-keys', 'pane get', 'pane send-keys', 'pane get', 'pane send-text'])
    expect(h.calls[3]!.args).toEqual(['pane', 'send-keys', 'w4F:p1', 'down'])
    expect(h.calls[5]!.args).toEqual(['pane', 'send-keys', 'w4F:p1', 'esc'])
    expect(h.calls[7]!.args).toEqual(['pane', 'send-text', 'w4F:p1', 'blue'])
    expect(h.calls.every((c) => c.bin === HBIN && c.env.HERDR_SOCKET_PATH === HSOCK)).toBe(true)
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ agentId: 'h1', route: 'herdr', what: 'key', value: 'Down', ok: true, terminal: 'w4F:p1' }))
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ route: 'herdr', what: 'text', ok: true }))
    expect(fallback.sendKey).not.toHaveBeenCalled()
    expect(orcaExec.calls).toHaveLength(0)
    expect(router.hostOf('h1')).toBe('herdr')
    expect(router.answerDeps.acquireControl?.(SID)).toBeTypeOf('function')
  })

  it('sends nothing at all while answers are off (no herdr call), but still reads', async () => {
    const { router, audit, verbs } = setup({ answers: false })
    expect(await router.answerDeps.sendKey('h1', '1')).toBe(false)
    expect(await router.prompt('h1', 'hi')).toBe(false)
    expect(verbs()).toEqual([])
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ route: 'herdr', ok: false, reason: 'answers_off' }))
    expect(await router.answerDeps.capture('h1')).toContain('Yes')
  })

  it('refuses kill keys and keys herdr cannot send, without touching the pane', async () => {
    const { router, audit, verbs } = setup()
    expect(await router.answerDeps.sendKey('h1', 'C-c')).toBe(false)
    expect(await router.answerDeps.sendKey('h1', 'PPage')).toBe(false)
    expect(verbs()).toEqual([])
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ ok: false, reason: 'key_refused' }))
  })

  it('refuses cleanly when the pane is gone', async () => {
    const { router, audit, verbs } = setup({ panes: [] })
    expect(await router.answerDeps.sendKey('h1', '1')).toBe(false)
    expect(await router.answerDeps.capture('h1')).toBeNull()
    expect(verbs()).toEqual(['pane get', 'pane list', 'pane get', 'pane list'])
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ route: 'herdr', ok: false, reason: 'pane_gone', terminal: 'w4F:p1' }))
  })

  it('refuses a pane that now runs another session (or no agent at all)', async () => {
    const other = herdrPane({ agent_session: { value: '11111111-2222-4333-8444-555555555555' } })
    const { router, audit, verbs } = setup({ panes: [other] })
    expect(await router.answerDeps.sendText('h1', 'yes')).toBe(false)
    expect(verbs()).toEqual(['pane get', 'pane list'])
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ ok: false, reason: 'pane_mismatch' }))
    const shell = setup({ panes: [herdrPane({ agent: undefined, agent_session: undefined })] })
    expect(await shell.router.prompt('h1', 'rm -rf ~')).toBe(false)
    expect(shell.verbs()).toEqual(['pane get', 'pane list'])
  })

  it('accepts a pane with no reported session when herdr sees the same engine in it', async () => {
    const { router } = setup({ panes: [herdrPane({ agent_session: undefined })] })
    expect(await router.answerDeps.sendKey('h1', '2')).toBe(true)
    const codex = setup({ panes: [herdrPane({ agent: 'codex', agent_session: undefined })] })
    expect(await codex.router.answerDeps.sendKey('h1', '2')).toBe(false)
  })

  it('follows a pane herdr moved, by its session, and remembers the new id', async () => {
    const { router, h, row } = setup({ panes: [herdrPane({ pane_id: 'w9:p2', workspace_id: 'w9', tab_id: 'w9:t1' })] })
    expect(await router.answerDeps.sendKey('h1', '1')).toBe(true)
    expect(h.calls.at(-1)!.args).toEqual(['pane', 'send-keys', 'w9:p2', '1'])
    expect(row.external.herdr).toMatchObject({ pane: 'w9:p2', workspace: 'w9', tab: 'w9:t1', socket: HSOCK, bin: HBIN })
  })

  it('types a prompt as text then Enter, keeping its line breaks', async () => {
    const { router, h, audit } = setup()
    expect(await router.prompt('h1', 'line one\nline two\u0007')).toBe(true)
    expect(h.calls.filter((c) => c.args[1] !== 'get').map((c) => c.args)).toEqual([
      ['pane', 'send-text', 'w4F:p1', 'line one\nline two'],
      ['pane', 'send-keys', 'w4F:p1', 'enter'],
    ])
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ route: 'herdr', what: 'prompt', ok: true, terminal: 'w4F:p1' }))
  })

  it('hands the question controls a herdr write', async () => {
    const { router, h } = setup()
    const w = router.controlWrite('h1')
    expect(w).toBeDefined()
    expect(await w!.key('3')).toBe(true)
    expect(await w!.key('Enter')).toBe(true)
    expect(h.calls.filter((c) => c.args[1] === 'send-keys').map((c) => c.args[3])).toEqual(['3', 'enter'])
  })

  it('a row with both refs goes where its innermost host is; tmux innermost is watch only', async () => {
    const both = { orca: { terminal: TERM }, herdr: { ...herdrRef } }
    const viaOrca = setup({ row: { external: { ...both, inner: 'orca' } } })
    expect(await viaOrca.router.answerDeps.sendKey('h1', '1')).toBe(true)
    expect(viaOrca.orcaExec.calls.map((c) => c[1])).toEqual(['send'])
    expect(viaOrca.verbs()).toEqual([])
    const viaHerdr = setup({ row: { external: { ...both, inner: 'herdr' } } })
    expect(await viaHerdr.router.answerDeps.sendKey('h1', '1')).toBe(true)
    expect(viaHerdr.orcaExec.calls).toHaveLength(0)
    const viaTmux = setup({ row: { external: { ...both, inner: 'tmux' } } })
    expect(await viaTmux.router.answerDeps.sendKey('h1', '1')).toBe(false)
    expect(await viaTmux.router.answerDeps.capture('h1')).toBeNull()
    expect(viaTmux.audit).toHaveBeenCalledWith(expect.objectContaining({ route: 'none', ok: false, reason: 'no_host' }))
    expect(viaTmux.orcaExec.calls).toHaveLength(0)
    expect(viaTmux.verbs()).toEqual([])
  })

  it('an Orca prompt is the text then a carriage return, as before', async () => {
    const r = setup({ row: { external: { orca: { terminal: TERM }, herdr: null, inner: 'orca' } } })
    expect(await r.router.prompt('h1', 'ship it')).toBe(true)
    expect(r.orcaExec.calls.map((c) => c[5])).toEqual(['ship it', '\r'])
  })
})
