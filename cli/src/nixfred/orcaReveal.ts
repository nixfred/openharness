/**
 * nixfred: a tap on the Harness dial for an agent running in an Orca terminal takes the desktop there.
 *
 * `orca terminal switch --terminal <handle>` brings that terminal's tab forward inside Orca, then the
 * Orca window is focused through Hyprland (Omarchy 4 takes a Lua dispatch: hl.dsp.focus({window=...})).
 * Only a TAP (cable `open`) calls this. A carousel scroll (`focus`) never moves the desktop.
 */
import { execFile } from 'node:child_process'
import { findOrcaBin } from './orcaWatch.js'

const ORCA_HANDLE_RE = /^term_[0-9a-f-]{8,64}$/i
const HYPR_ADDR_RE = /^0x[0-9a-f]+$/i

type Run = (bin: string, args: string[]) => Promise<string>
const defaultRun: Run = (bin, args) => new Promise((resolve, reject) => {
  execFile(bin, args, { timeout: 5_000, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => (err ? reject(err) : resolve(String(stdout))))
})

export async function revealOrcaTerminal(handle: string, run: Run = defaultRun, orcaBin: string | null = findOrcaBin()): Promise<{ switched: boolean; focused: boolean }> {
  if (!ORCA_HANDLE_RE.test(handle) || !orcaBin) return { switched: false, focused: false }
  let switched = false
  try {
    const out = await run(orcaBin, ['terminal', 'switch', '--terminal', handle, '--json'])
    switched = /"ok"\s*:\s*true/.test(out)
  } catch { /* Orca not running: nothing to switch to */ }
  let focused = false
  try {
    const clients = JSON.parse(await run('hyprctl', ['-j', 'clients'])) as Array<{ class?: string; address?: string }>
    const addr = clients.find((c) => c.class === 'orca')?.address
    if (addr && HYPR_ADDR_RE.test(addr)) {
      const out = await run('hyprctl', ['dispatch', `hl.dsp.focus({ window = "address:${addr}" })`])
      focused = out.trim() === 'ok'
    }
  } catch { /* not Hyprland, or no Orca window */ }
  return { switched, focused }
}
