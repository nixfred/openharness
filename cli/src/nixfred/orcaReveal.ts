/**
 * nixfred: a tap on the Harness dial takes the desktop to that agent, wherever it runs.
 *
 * The host is read live from the agent process at tap time (no registry plumbing): its environment
 * says which terminal multiplexer or IDE holds it, innermost first:
 *   1. Orca      ORCA_TERMINAL_HANDLE        -> `orca terminal switch --terminal <handle>`
 *   2. tmux      TMUX_PANE (+ TMUX socket)   -> `tmux switch-client -t <pane>` and `select-window`
 *   3. herdr     HERDR_WORKSPACE_ID/TAB_ID   -> `herdr workspace focus`, `herdr tab focus`
 * Then, for ANY terminal or IDE (kitty, Ghostty, Alacritty, WezTerm, foot, VS Code, Cursor, Zed, Orca,
 * herdr's own window...), the process tree is walked up to the first ancestor that owns a Hyprland
 * window, and that window is focused (Omarchy 4 takes a Lua dispatch: hl.dsp.focus({window=...})).
 * Every id is validated before it reaches a command line.
 */
import { execFile } from 'node:child_process'
import { readdirSync, readFileSync } from 'node:fs'
import { findOrcaBin } from './orcaWatch.js'

const ORCA_HANDLE_RE = /^term_[0-9a-f-]{8,64}$/i
const HYPR_ADDR_RE = /^0x[0-9a-f]+$/i
const TMUX_PANE_RE = /^%\d{1,6}$/
const HERDR_ID_RE = /^[A-Za-z0-9]{1,16}(:[A-Za-z0-9]{1,16})?$/

export type Run = (bin: string, args: string[], env?: NodeJS.ProcessEnv) => Promise<string>
const defaultRun: Run = (bin, args, env) => new Promise((resolve, reject) => {
  execFile(bin, args, { timeout: 5_000, maxBuffer: 4 * 1024 * 1024, env: env ?? process.env }, (err, stdout) => (err ? reject(err) : resolve(String(stdout))))
})

export interface ProcFs {
  environ(pid: number): string | null
  ppid(pid: number): number | null
  /** Pids whose argv is exactly this program with no subcommand (a client, not `herdr server`). */
  clientPids?(prog: string): number[]
}
export const nodeProcFs: ProcFs = {
  environ: (pid) => { try { return readFileSync(`/proc/${pid}/environ`, 'latin1') } catch { return null } },
  ppid: (pid) => {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, 'utf8')
      const v = Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1])
      return Number.isSafeInteger(v) && v > 0 ? v : null
    } catch { return null }
  },
  clientPids: (prog) => {
    const out: number[] = []
    try {
      for (const d of readdirSync('/proc')) {
        if (!/^\d+$/.test(d)) continue
        try {
          const argv = readFileSync(`/proc/${d}/cmdline`, 'latin1').split('\u0000').filter(Boolean)
          if (argv.length === 1 && (argv[0] === prog || argv[0]!.endsWith(`/${prog}`))) out.push(Number(d))
        } catch { /* gone */ }
      }
    } catch { /* no /proc */ }
    return out
  },
}

export interface RevealResult { host: 'orca' | 'tmux' | 'herdr' | 'window' | 'none'; switched: boolean; focused: boolean; window: string | null }

function envVars(raw: string | null): Map<string, string> {
  const m = new Map<string, string>()
  for (const kv of (raw ?? '').split('\u0000')) { const i = kv.indexOf('='); if (i > 0) m.set(kv.slice(0, i), kv.slice(i + 1)) }
  return m
}

/** Bring the agent with this engine pid to the front. `orcaHandle` wins when the registry already knows it. */
export async function revealSession(pid: number | null, orcaHandle: string | null = null, deps: { run?: Run; fs?: ProcFs; orcaBin?: string | null } = {}): Promise<RevealResult> {
  const run = deps.run ?? defaultRun
  const fs = deps.fs ?? nodeProcFs
  if (!pid && !(orcaHandle && ORCA_HANDLE_RE.test(orcaHandle))) return { host: 'none', switched: false, focused: false, window: null }
  const vars = pid ? envVars(fs.environ(pid)) : new Map<string, string>()
  const handle = orcaHandle ?? vars.get('ORCA_TERMINAL_HANDLE') ?? null
  let host: RevealResult['host'] = 'none'
  let switched = false

  if (handle && ORCA_HANDLE_RE.test(handle)) {
    host = 'orca'
    const bin = deps.orcaBin === undefined ? findOrcaBin() : deps.orcaBin
    if (bin) { try { switched = /"ok"\s*:\s*true/.test(await run(bin, ['terminal', 'switch', '--terminal', handle, '--json'])) } catch { /* Orca down */ } }
  } else if (TMUX_PANE_RE.test(vars.get('TMUX_PANE') ?? '')) {
    host = 'tmux'
    const pane = vars.get('TMUX_PANE')!
    const socket = (vars.get('TMUX') ?? '').split(',')[0]
    const sock = socket && socket.startsWith('/') ? ['-S', socket] : []
    try { await run('tmux', [...sock, 'select-window', '-t', pane]); await run('tmux', [...sock, 'select-pane', '-t', pane]); switched = true } catch { /* no server */ }
    try { await run('tmux', [...sock, 'switch-client', '-t', pane]) } catch { /* no attached client is fine */ }
  } else if (HERDR_ID_RE.test(vars.get('HERDR_WORKSPACE_ID') ?? '')) {
    host = 'herdr'
    const ws = vars.get('HERDR_WORKSPACE_ID')!
    const tab = vars.get('HERDR_TAB_ID') ?? ''
    const env = { ...process.env, ...(vars.get('HERDR_SOCKET_PATH')?.startsWith('/') ? { HERDR_SOCKET_PATH: vars.get('HERDR_SOCKET_PATH')! } : {}) }
    const bin = vars.get('HERDR_BIN_PATH')?.startsWith('/') ? vars.get('HERDR_BIN_PATH')! : 'herdr'
    try { await run(bin, ['workspace', 'focus', ws], env); switched = true } catch { /* herdr down */ }
    if (HERDR_ID_RE.test(tab)) { try { await run(bin, ['tab', 'focus', tab], env) } catch { /* old herdr */ } }
  }

  // Generic: the first ancestor of the agent that owns a Hyprland window is its terminal or IDE.
  let window: string | null = null
  let focused = false
  try {
    const clients = JSON.parse(await run('hyprctl', ['-j', 'clients'])) as Array<{ class?: string; address?: string; pid?: number }>
    const byPid = new Map<number, { class?: string; address?: string }>()
    for (const c of clients) if (typeof c.pid === 'number') byPid.set(c.pid, c)
    let addr: string | undefined
    for (let p: number | null = pid, hops = 0; p && p > 1 && hops < 40; p = fs.ppid(p), hops++) {
      const c = byPid.get(p)
      if (c?.address) { addr = c.address; window = c.class ?? null; break }
    }
    // herdr's server is detached: the window showing it is the one running a bare `herdr` client.
    if (!addr && host === 'herdr' && fs.clientPids) {
      for (const cp of fs.clientPids('herdr')) {
        for (let p: number | null = cp, hops = 0; p && p > 1 && hops < 40; p = fs.ppid(p), hops++) {
          const c = byPid.get(p)
          if (c?.address) { addr = c.address; window = c.class ?? null; break }
        }
        if (addr) break
      }
    }
    if (!addr && host === 'orca') { const c = clients.find((x) => x.class === 'orca'); addr = c?.address; window = c ? 'orca' : null }
    if (addr && HYPR_ADDR_RE.test(addr)) {
      focused = (await run('hyprctl', ['dispatch', `hl.dsp.focus({ window = "address:${addr}" })`])).trim() === 'ok'
      if (host === 'none' && focused) host = 'window'
    }
  } catch { /* not Hyprland */ }
  return { host, switched, focused, window }
}

/** Kept for callers from the first cut: reveal by Orca handle alone. */
export async function revealOrcaTerminal(handle: string, run?: Run, orcaBin?: string | null): Promise<{ switched: boolean; focused: boolean }> {
  const r = await revealSession(null, handle, { run, orcaBin })
  return { switched: r.switched, focused: r.focused }
}
