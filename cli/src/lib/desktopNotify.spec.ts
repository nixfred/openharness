import { describe, expect, it } from 'vitest'
import { notifyAttention, type NotifyDeps } from './desktopNotify.js'

/** A runner that records every call; notify-send answers with `clicked` as its printed action. */
function fakeDeps(opts: { has?: string[]; clicked?: string; luaFails?: boolean } = {}) {
  const calls: Array<[string, string[]]> = []
  const have = new Set(opts.has ?? ['notify-send', 'herdr-goto', 'hyprctl'])
  const deps: NotifyDeps = {
    platform: 'linux',
    has: async (cmd) => have.has(cmd),
    run: async (cmd, args) => {
      calls.push([cmd, args])
      if (cmd === 'notify-send') return { stdout: opts.clicked ?? '', code: 0 }
      if (cmd === 'hyprctl' && opts.luaFails && args[1]?.startsWith('hl.dsp')) return { stdout: '', code: 1 }
      return { stdout: '', code: 0 }
    },
  }
  return { deps, calls }
}

const settle = () => new Promise((r) => setTimeout(r, 0))
const notice = { agentName: 'clarity', machine: 'gus', state: 'waiting' as const, detail: 'Claude is waiting' }

describe('notifyAttention click target', () => {
  it('points an agent in herdr at its pane, through the hint and the default action', async () => {
    const { deps, calls } = fakeDeps({ clicked: 'default' })
    expect(await notifyAttention({ ...notice, herdrPane: 'w4E:p1' }, deps)).toBe('sent')
    await settle()
    const [, args] = calls.find(([c]) => c === 'notify-send')!
    expect(args).toContain('--action=default=Show me')
    expect(args).toContain('--hint=string:omarchy-exec-argv:["herdr-goto","w4E:p1"]')
    expect(args.slice(-3)).toEqual(['--', 'clarity is waiting on you', 'gus: Claude is waiting'])
    expect(calls).toContainEqual(['herdr-goto', ['w4E:p1']])
  })

  it('without herdr-goto installed, sends no hint and a click focuses the Harness window in Lua', async () => {
    const { deps, calls } = fakeDeps({ has: ['notify-send', 'hyprctl'], clicked: 'default' })
    await notifyAttention({ ...notice, herdrPane: 'w4E:p1' }, deps)
    await settle()
    expect(calls.find(([c]) => c === 'notify-send')![1].some((a) => a.startsWith('--hint'))).toBe(false)
    expect(calls).toContainEqual(['hyprctl', ['dispatch', 'hl.dsp.focus({ window = "class:^(harness)$" })']])
    expect(calls.some(([c]) => c === 'herdr-goto')).toBe(false)
  })

  it('falls back to the classic dispatch when Hyprland rejects the Lua form', async () => {
    const { deps, calls } = fakeDeps({ has: ['notify-send', 'hyprctl'], clicked: 'default', luaFails: true })
    await notifyAttention(notice, deps)
    await settle()
    expect(calls).toContainEqual(['hyprctl', ['dispatch', 'focuswindow', 'class:^(harness)$']])
  })

  it('never hands a malformed pane id to herdr-goto', async () => {
    const { deps, calls } = fakeDeps({ clicked: 'default' })
    await notifyAttention({ ...notice, herdrPane: 'w4E:p1; rm -rf ~' }, deps)
    await settle()
    expect(calls.find(([c]) => c === 'notify-send')![1].some((a) => a.startsWith('--hint'))).toBe(false)
    expect(calls.some(([c]) => c === 'herdr-goto')).toBe(false)
  })

  it('does nothing more when the toast closes without a click', async () => {
    const { deps, calls } = fakeDeps({ clicked: '' })
    await notifyAttention({ ...notice, herdrPane: 'w4E:p1' }, deps)
    await settle()
    expect(calls.map(([c]) => c)).toEqual(['notify-send'])
  })
})
