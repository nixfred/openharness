import { describe, expect, it } from 'vitest'
import { revealOrcaTerminal } from './orcaReveal.js'

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
})
