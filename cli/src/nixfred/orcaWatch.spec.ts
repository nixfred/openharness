import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  ExternalCaptureGate,
  ExternalTerminalRouter,
  OrcaCli,
  applyOrcaWatchSwitch,
  attentionForExternalEvent,
  orcaKeyBytes,
  parseExternalHook,
  readOrcaWatchConfig,
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
