import { describe, expect, it } from 'vitest'
import { revealOrcaTerminal, revealSession } from './orcaReveal.js'

describe('revealOrcaTerminal', () => {
  it('switches the Orca tab, then focuses the Orca window by address', async () => {
    const calls: string[][] = []
    const run = async (bin: string, args: string[]) => {
      calls.push([bin, ...args])
      if (args[0] === 'terminal') return '{ "ok": true }'
      if (args[0] === '-j') return JSON.stringify([{ class: 'kitty', address: '0x1' }, { class: 'orca', address: '0xabc' }])
      return 'ok'
    }
    const r = await revealOrcaTerminal('term_c07405a6-d443', run, '/usr/bin/orca')
    expect(r).toEqual({ switched: true, focused: true })
    expect(calls[0]).toEqual(['/usr/bin/orca', 'terminal', 'switch', '--terminal', 'term_c07405a6-d443', '--json'])
    expect(calls[2]).toEqual(['hyprctl', 'dispatch', 'hl.dsp.focus({ window = "address:0xabc" })'])
  })
  it('refuses a handle that is not an Orca terminal id', async () => {
    let ran = false
    const r = await revealOrcaTerminal('term_x; rm -rf /', async () => { ran = true; return '' }, '/usr/bin/orca')
    expect(r).toEqual({ switched: false, focused: false })
    expect(ran).toBe(false)
  })
  it('herdr: focuses the workspace and tab from the agent environment, then the owning window', async () => {
    const calls: string[][] = []
    const run = async (bin: string, args: string[]) => {
      calls.push([bin, ...args])
      if (args[0] === '-j') return JSON.stringify([{ class: 'kitty', address: '0xa1', pid: 50 }])
      return 'ok'
    }
    const fs = { environ: () => 'HERDR_WORKSPACE_ID=w2T\u0000HERDR_TAB_ID=w2T:t1\u0000HERDR_BIN_PATH=/usr/bin/herdr\u0000', ppid: (p: number) => (p === 900 ? 120 : p === 120 ? 50 : null) }
    const r = await revealSession(900, null, { run, fs, orcaBin: null, openTerminal: null })
    expect(r).toMatchObject({ host: 'herdr', switched: true, focused: true, window: 'kitty' })
    expect(calls[0]).toEqual(['/usr/bin/herdr', 'workspace', 'focus', 'w2T'])
    expect(calls[1]).toEqual(['/usr/bin/herdr', 'tab', 'focus', 'w2T:t1'])
    expect(calls.at(-1)).toEqual(['hyprctl', 'dispatch', 'hl.dsp.focus({ window = "address:0xa1" })'])
  })
  it('plain terminal or IDE: walks up to the window that owns the agent', async () => {
    const run = async (_b: string, args: string[]) => (args[0] === '-j' ? JSON.stringify([{ class: 'code', address: '0xc', pid: 7 }]) : 'ok')
    const fs = { environ: () => 'HOME=/h\u0000', ppid: (p: number) => (p === 30 ? 7 : null) }
    expect(await revealSession(30, null, { run, fs, orcaBin: null })).toMatchObject({ host: 'window', focused: true, window: 'code' })
  })
  it('herdr with no local window opens a terminal running herdr', async () => {
    const opened: string[] = []
    const run = async (_b: string, args: string[]) => (args[0] === '-j' ? '[]' : 'ok')
    const fs = { environ: () => 'HERDR_WORKSPACE_ID=w2T\u0000HERDR_BIN_PATH=/usr/bin/herdr\u0000', ppid: () => null, clientPids: () => [] }
    const r = await revealSession(900, null, { run, fs, orcaBin: null, openTerminal: (p) => { opened.push(p) } })
    expect(opened).toEqual(['/usr/bin/herdr'])
    expect(r).toMatchObject({ host: 'herdr', window: 'new-terminal' })
  })
})
