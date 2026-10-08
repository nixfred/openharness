import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// The opt-in gate hook, re-homed from engines/claude/installHooks.ts (deleted upstream by #1045).
describe('gate hook (opt-in PreToolUse)', () => {
  let home = ''
  beforeEach(() => { home = mkdtempSync(join(tmpdir(), 'nixfred-gate-')); vi.stubEnv('HOME', home); vi.resetModules() })
  afterEach(() => { vi.unstubAllEnvs(); rmSync(home, { recursive: true, force: true }) })

  it('installs once beside foreign PreToolUse hooks, is unchanged on a second run, and uninstalls only its own', async () => {
    mkdirSync(join(home, '.claude'), { recursive: true })
    const file = join(home, '.claude', 'settings.json')
    writeFileSync(file, JSON.stringify({ model: 'opus', hooks: { PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: 'my-guard' }] }] } }))
    const gate = await import('./gateHook.js')
    expect(gate.gateHookInstalled()).toBe(false)
    expect(gate.installGateHook(18599)).toBe('installed')
    expect(gate.installGateHook(18599)).toBe('unchanged')
    const after = JSON.parse(readFileSync(file, 'utf8')) as { model: string; hooks: { PreToolUse: Array<{ matcher: string; hooks: Array<{ command: string }> }> } }
    expect(after.model).toBe('opus')
    expect(after.hooks.PreToolUse.map((b) => b.matcher)).toEqual(['Bash', gate.GATE_MATCHER])
    expect(after.hooks.PreToolUse[1]!.hooks[0]!.command).toContain('--port 18599')
    expect(gate.gateHookInstalled()).toBe(true)
    expect(gate.installGateHook(18600)).toBe('updated')
    expect(gate.uninstallGateHook()).toBe('removed')
    const removed = JSON.parse(readFileSync(file, 'utf8')) as { hooks: { PreToolUse: Array<{ hooks: Array<{ command: string }> }> } }
    expect(removed.hooks.PreToolUse.map((b) => b.hooks[0]!.command)).toEqual(['my-guard'])
    expect(gate.uninstallGateHook()).toBe('absent')
  })
})
