import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Nixfred, type NixfredDeps, type NixfredSessionLike } from './nixfredWiring.js'

vi.mock('./lib/desktopNotify.js', () => ({ notifyAttention: vi.fn(async () => 'skipped') }))
vi.mock('./lib/hooks.js', () => ({ installGateHook: () => 'installed', uninstallGateHook: () => 'removed', gateHookInstalled: () => false }))

const session = (agentId: string, extra: Partial<NixfredSessionLike> = {}): NixfredSessionLike => ({
  agentId, sessionId: `s-${agentId}`, engine: 'claude', active: true, tmuxPane: '%3', cwd: '/tmp/proj', name: agentId, model: 'claude-sonnet', ...extra,
})

describe('Nixfred wiring', () => {
  let dir: string
  let sent: Array<{ type: string; payload: Record<string, unknown> }>
  let errors: string[]
  let cancelled: string[]
  let sessions: NixfredSessionLike[]
  let tokens: number
  let nix: Nixfred
  let now: number

  const deps = (): NixfredDeps => ({
    dataDir: dir,
    machineId: () => 'm-1',
    machineName: () => 'gus',
    sessions: () => sessions,
    sendLocal: (f) => { sent.push(f) },
    sendError: (_a, _s, m) => { errors.push(m) },
    cancelAgent: async (id) => { cancelled.push(id); return true },
    tokenUsage: () => ({ totalTokens: tokens }),
    hookPort: () => 18473,
    now: () => now,
  })

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'nixfred-'))
    sent = []; errors = []; cancelled = []; tokens = 0; now = Date.UTC(2026, 8, 26, 16, 0)
    sessions = [session('a'), session('b')]
    nix = new Nixfred(deps())
  })
  afterEach(() => { rmSync(dir, { recursive: true, force: true }) })

  it('turns attention changes into a local frame with a summary and glyphs', () => {
    nix.attention.turnStarted('a', 'fix login')
    nix.attention.question('b', true, 'Bash: git push')
    const last = sent.at(-1)!
    expect(last.type).toBe('attention')
    const p = last.payload as { hostname: string; summary: { state: string; agentId: string }; agents: Array<{ agentId: string; state: string; glyph: string }> }
    expect(p.hostname).toBe('gus')
    expect(p.summary).toMatchObject({ state: 'permission', agentId: 'b' })
    expect(p.agents.map((a) => `${a.agentId}:${a.state}:${a.glyph}`)).toEqual(['b:permission:!', 'a:working:~'])
  })

  it('gate asks on a push, allows a plain command, and journals the verdict', async () => {
    expect(nix.gate('s-a', 'a', 'Bash', { command: 'git status' }).decision).toBe('allow')
    const v = nix.gate('s-a', 'a', 'Bash', { command: 'git push origin main' })
    expect(v).toMatchObject({ decision: 'ask', rule: 'git push' })
    expect(nix.attention.get('a')?.state).toBe('permission')
    await new Promise((r) => setTimeout(r, 20))
    const journal = readFileSync(join(dir, 'audit.jsonl'), 'utf8')
    expect(journal).toMatch(/"kind":"gate"/)
    expect(journal).toMatch(/"decision":"ask"/)
  })

  it('spend brake pauses the pane once the per-agent cap is hit and tells the web', () => {
    nix.spendSet({ perAgentUsd: 1, perDayUsd: null })
    tokens = 100_000
    expect(nix.spendCheck(session('a')).action).toBe('run')
    tokens = 400_000 // sonnet: 320k in * 3 + 80k out * 15 per M = 0.96 + 1.2 = 2.16 USD
    const v = nix.spendCheck(session('a'))
    expect(v.action).toBe('pause')
    expect(errors[0]).toMatch(/Spend brake paused: agent at \$2\.16 of \$1/)
    expect(nix.attention.get('a')).toMatchObject({ state: 'waiting' })
    expect(JSON.parse(readFileSync(join(dir, 'spend-caps.json'), 'utf8')).perAgentUsd).toBe(1)
  })

  it('loopCheck lets a plain message through and defers a /loop in quiet hours', async () => {
    now = Date.UTC(2026, 8, 27, 4, 0) // 00:00 New York, inside 23:00-07:00 quiet hours
    expect(await nix.loopCheck(session('a'), 'hello')).toEqual({ run: true })
    const held = await nix.loopCheck(session('a'), '/loop every 9am check deploys')
    expect(held.run).toBe(false)
    expect(errors.at(-1)).toMatch(/loop deferred/)
  })

  it('stopAll cancels every active agent but the one kept', async () => {
    const out = await nix.stopAll('b')
    expect(out.cancelled).toEqual(['a'])
    expect(cancelled).toEqual(['a'])
    expect(nix.attention.get('a')?.state).toBe('idle')
  })

  it('raises a collision alert when two agents edit the same file, and it rides on the attention payload', async () => {
    nix.gate('s-a', 'a', 'Edit', { file_path: '/tmp/proj/src/bridge.ts', old_string: 'x', new_string: 'y' })
    nix.gate('s-b', 'b', 'Edit', { file_path: '/tmp/proj/src/bridge.ts', old_string: 'y', new_string: 'z' })
    const alerts = (await nix.command('collisions', {}) as { alerts: Array<{ kind: string; detail: string }> }).alerts
    expect(alerts).toHaveLength(1)
    expect(alerts[0]).toMatchObject({ kind: 'file', detail: 'b and a on file /tmp/proj/src/bridge.ts' })
    const payload = sent.at(-1)!.payload as { alerts: unknown[] }
    expect(payload.alerts).toHaveLength(1)
    await new Promise((r) => setTimeout(r, 20))
    expect(readFileSync(join(dir, 'audit.jsonl'), 'utf8')).toMatch(/"kind":"tool"/)
  })

  it('locks a branch for one agent and reports another agent on it', async () => {
    const lock = await nix.command('lock', { repo: '/tmp/proj', branch: 'feature', agentId: 'a' }) as { holderName: string }
    expect(lock.holderName).toBe('a')
    await expect(nix.command('lock', { repo: '/tmp/proj', branch: 'feature', agentId: 'b' })).rejects.toThrow(/held by a/)
    expect(JSON.parse(readFileSync(join(dir, 'branch-locks.json'), 'utf8'))).toHaveLength(1)
    nix.collisions.noteBranch({ agentId: 'b', agentName: 'b' }, '/tmp/proj', 'feature')
    const alerts = (await nix.command('collisions', {}) as { alerts: Array<{ kind: string }> }).alerts
    expect(alerts.map((a) => a.kind)).toEqual(['lock'])
    expect(await nix.command('unlock', { repo: '/tmp/proj', branch: 'feature' })).toEqual({ removed: true })
  })

  it('dispatches a job over a relay link and reads the result off the worker text', async () => {
    type F = { type: string; payload: Record<string, unknown> }
    const sentFrames: F[] = []
    const link: { push: ((f: F) => void) | null } = { push: null }
    nix.setRelayLink(async () => ({
      send: async (f) => {
        sentFrames.push(f)
        if (f.type === 'agent_create') setTimeout(() => link.push?.({ type: 'agent_create_result', payload: { requestId: f.payload.requestId, creationId: f.payload.creationId, agentId: 'remote-1' } }), 5)
      },
      onFrame: (cb) => { link.push = cb; return () => { link.push = null } },
      close: () => {},
    }))
    const rec = await nix.dispatch('m-2', { machineId: 'm-2', brief: 'add a README badge', repo: '/srv/proj', engine: 'claude', branchName: 'badge' })
    expect(rec.finishedAt).toBeNull()
    await new Promise((r) => setTimeout(r, 40))
    expect(sentFrames[0]?.type).toBe('agent_create')
    expect(String(sentFrames[0]?.payload.prompt)).toContain('DISPATCH_RESULT:')
    link.push?.({ type: 'text_delta', payload: { agentId: 'remote-1', content: 'Done. DISPATCH_RESULT: {"branch":"badge","diffStat":"1 file changed","summary":"README badge added","ok":true}\n' } })
    link.push?.({ type: 'turn_ended', payload: { agentId: 'remote-1' } })
    await new Promise((r) => setTimeout(r, 40))
    const listed = (await nix.command('dispatches', {}) as { dispatches: Array<typeof rec> }).dispatches
    expect(listed[0]?.agentId).toBe('remote-1')
    expect(listed[0]?.result).toMatchObject({ ok: true, branch: 'badge', summary: 'README badge added' })
    expect(listed[0]?.finishedAt).not.toBeNull()
  })

  it('exposes the local command surface', async () => {
    const status = await nix.command('gate-status', {}) as { enabled: boolean; rules: number; installed: boolean }
    expect(status).toMatchObject({ enabled: true, installed: false })
    expect(status.rules).toBeGreaterThan(10)
    const caps = await nix.command('spend-set', { perDayUsd: 42 }) as { caps: { perDayUsd: number } }
    expect(caps.caps.perDayUsd).toBe(42)
    await expect(nix.command('nope', {})).rejects.toThrow(/unknown nixfred action/)
    const att = await nix.command('attention', {}) as { agents: unknown[] }
    expect(att.agents).toHaveLength(2)
  })
})
