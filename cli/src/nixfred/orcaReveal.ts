/**
 * nixfred: a tap on the Harness dial takes the desktop to that agent, wherever it runs.
 *
 * The host is read live from the agent process at tap time (no registry plumbing): its environment
 * says which terminal multiplexer or IDE holds it, and the parent chain says which one is innermost:
 *   1. herdr     HERDR_WORKSPACE_ID/TAB_ID   -> `herdr workspace focus`, `herdr tab focus`
 *   2. Orca      ORCA_TERMINAL_HANDLE        -> `orca terminal switch --terminal <handle>`
 *   3. tmux      TMUX_PANE (+ TMUX socket)   -> `tmux switch-client -t <pane>` and `select-window`
 * The innermost host always wins. When an agent carries BOTH an Orca handle and herdr ids and the parent
 * chain cannot tell, herdr is the default winner (Fred's host since 2026-10-08) and Orca is left alone.
 * HARNESS_REVEAL_PREFER=orca flips that: Orca switches to its terminal, then herdr focuses the agent's
 * workspace inside it, and if Orca cannot switch (closed, stale handle) herdr takes over.
 * Then, for ANY terminal or IDE (kitty, Ghostty, Alacritty, WezTerm, foot, VS Code, Cursor, Zed, Orca,
 * herdr's own window...), the process tree is walked up to the first ancestor that owns a Hyprland
 * window, and that window is focused (Omarchy 4 takes a Lua dispatch: hl.dsp.focus({window=...})).
 * Every id is validated before it reaches a command line.
 */
import { execFile, spawn } from 'node:child_process'
import { readdirSync, readFileSync } from 'node:fs'
import { HERDR_ID_RE, findOrcaBin } from './orcaWatch.js'

const ORCA_HANDLE_RE = /^term_[0-9a-f-]{8,64}$/i
const HYPR_ADDR_RE = /^0x[0-9a-f]+$/i
const TMUX_PANE_RE = /^%\d{1,6}$/

export type Run = (bin: string, args: string[], env?: NodeJS.ProcessEnv) => Promise<string>
const defaultRun: Run = (bin, args, env) => new Promise((resolve, reject) => {
  execFile(bin, args, { timeout: 5_000, maxBuffer: 4 * 1024 * 1024, env: env ?? process.env }, (err, stdout) => (err ? reject(err) : resolve(String(stdout))))
})

export interface ProcFs {
  environ(pid: number): string | null
  ppid(pid: number): number | null
  /** The process name (/proc/<pid>/comm). Optional: without it the host is chosen from the environment alone. */
  comm?(pid: number): string | null
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
  comm: (pid) => { try { return readFileSync(`/proc/${pid}/comm`, 'utf8').trim() } catch { return null } },
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
/** Open the desktop's default terminal running one program, detached (Omarchy: xdg-terminal-exec under uwsm). */
function defaultOpenTerminal(prog: string, args: string[] = []): void {
  // herdr refuses to start inside another herdr ("nested herdr is disabled"): drop its markers.
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('HERDR_')))
  const child = spawn('uwsm-app', ['--', 'xdg-terminal-exec', prog, ...args], { detached: true, stdio: 'ignore', env })
  child.on('error', () => {})
  child.unref()
}

/**
 * The host that really holds the agent: the NEAREST multiplexer or IDE above it in the process tree.
 * Environment variables are inherited (a tmux started inside Orca carries ORCA_*, an Orca started inside
 * herdr carries HERDR_*), so they cannot say which one is innermost; the parent chain can.
 */
export function innermostHost(pid: number | null, fs: ProcFs): 'tmux' | 'herdr' | 'orca' | null {
  if (!pid || !fs.comm) return null
  for (let p: number | null = fs.ppid(pid), hops = 0; p && p > 1 && hops < 16; p = fs.ppid(p), hops++) {
    const c = fs.comm(p) ?? ''
    if (c.startsWith('tmux')) return 'tmux'
    if (c === 'herdr') return 'herdr'
    if (c === 'orca-ide' || c === 'orca') return 'orca'
  }
  return null
}

export async function revealSession(pid: number | null, orcaHandle: string | null = null, deps: { run?: Run; fs?: ProcFs; orcaBin?: string | null; openTerminal?: ((prog: string, args?: string[]) => void) | null; prefer?: 'orca' | 'herdr' } = {}): Promise<RevealResult> {
  const run = deps.run ?? defaultRun
  const fs = deps.fs ?? nodeProcFs
  if (!pid && !(orcaHandle && ORCA_HANDLE_RE.test(orcaHandle))) return { host: 'none', switched: false, focused: false, window: null }
  const vars = pid ? envVars(fs.environ(pid)) : new Map<string, string>()
  const handle = orcaHandle ?? vars.get('ORCA_TERMINAL_HANDLE') ?? null
  let host: RevealResult['host'] = 'none'
  let switched = false
  let tmuxClients: number[] = []
  let tmuxAttach: string[] | null = null

  const herdrWs = vars.get('HERDR_WORKSPACE_ID') ?? ''
  const hasHerdr = HERDR_ID_RE.test(herdrWs)
  const hasOrca = !!handle && ORCA_HANDLE_RE.test(handle)
  const prefer = (deps.prefer ?? process.env.HARNESS_REVEAL_PREFER ?? 'herdr') === 'orca' ? 'orca' : 'herdr'
  const focusHerdr = async (): Promise<boolean> => {
    const tab = vars.get('HERDR_TAB_ID') ?? ''
    const env = { ...process.env, ...(vars.get('HERDR_SOCKET_PATH')?.startsWith('/') ? { HERDR_SOCKET_PATH: vars.get('HERDR_SOCKET_PATH')! } : {}) }
    const bin = vars.get('HERDR_BIN_PATH')?.startsWith('/') ? vars.get('HERDR_BIN_PATH')! : 'herdr'
    let ok = false
    try { await run(bin, ['workspace', 'focus', herdrWs], env); ok = true } catch { /* herdr down */ }
    if (HERDR_ID_RE.test(tab)) { try { await run(bin, ['tab', 'focus', tab], env) } catch { /* old herdr */ } }
    return ok
  }

  const inner = innermostHost(pid, fs)
  const hasTmux = TMUX_PANE_RE.test(vars.get('TMUX_PANE') ?? '')
  if (inner === 'herdr' && hasHerdr) {
    host = 'herdr'
    switched = await focusHerdr()
  } else if (inner !== 'tmux' && hasOrca && !(hasHerdr && prefer === 'herdr' && inner !== 'orca')) {
    host = 'orca'
    const bin = deps.orcaBin === undefined ? findOrcaBin() : deps.orcaBin
    if (bin) { try { switched = /"ok"\s*:\s*true/.test(await run(bin, ['terminal', 'switch', '--terminal', handle!, '--json'])) } catch { /* Orca down */ } }
    // Orca won. A herdr inside that terminal still gets moved to the agent's workspace; if Orca could not
    // switch at all, herdr becomes the host so the tap still lands somewhere.
    if (hasHerdr) {
      const h = await focusHerdr()
      if (!switched && h) { host = 'herdr'; switched = true }
    }
  } else if (hasTmux) {
    host = 'tmux'
    const pane = vars.get('TMUX_PANE')!
    const socket = (vars.get('TMUX') ?? '').split(',')[0]
    const sock = socket && socket.startsWith('/') ? ['-S', socket] : []
    try { await run('tmux', [...sock, 'select-window', '-t', pane]); await run('tmux', [...sock, 'select-pane', '-t', pane]); switched = true } catch { /* no server */ }
    try { await run('tmux', [...sock, 'switch-client', '-t', pane]) } catch { /* no attached client is fine */ }
    // The tmux server is detached from any window: the window that shows this pane is the terminal of an
    // attached client. Remember those clients' pids for the window walk below; with none, open one.
    try {
      const out = await run('tmux', [...sock, 'list-clients', '-t', pane, '-F', '#{client_pid}'])
      tmuxClients = out.split('\n').map((l) => Number(l.trim())).filter((n) => Number.isSafeInteger(n) && n > 1)
    } catch { tmuxClients = [] }
    tmuxAttach = [...sock, 'attach-session', '-t', pane]
  } else if (hasHerdr) {
    host = 'herdr'
    switched = await focusHerdr()
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
    // tmux: walk up from each attached client to its terminal window.
    if (!addr && host === 'tmux') {
      for (const cp of tmuxClients) {
        for (let p: number | null = cp, hops = 0; p && p > 1 && hops < 40; p = fs.ppid(p), hops++) {
          const c = byPid.get(p)
          if (c?.address) { addr = c.address; window = c.class ?? null; break }
        }
        if (addr) break
      }
    }
    if (!addr && host === 'tmux' && tmuxAttach && deps.openTerminal !== null) {
      try { (deps.openTerminal ?? defaultOpenTerminal)('tmux', tmuxAttach); window = 'new-terminal'; focused = true } catch { /* no launcher */ }
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
    // No local herdr window at all (its only viewer may be over SSH): open one. A bare `herdr` attaches to
    // the persistent session, which is already on the agent's workspace; the next tap finds this window.
    if (!addr && host === 'herdr' && deps.openTerminal !== null) {
      try { (deps.openTerminal ?? defaultOpenTerminal)(vars.get('HERDR_BIN_PATH')?.startsWith('/') ? vars.get('HERDR_BIN_PATH')! : 'herdr'); window = 'new-terminal'; focused = true } catch { /* no launcher */ }
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

/** The pid of the process in a tmux pane (the agent the Harness daemon itself started), or null. */
export async function tmuxPanePid(pane: string, run: Run = defaultRun): Promise<number | null> {
  if (!TMUX_PANE_RE.test(pane)) return null
  try {
    const v = Number((await run('tmux', ['display-message', '-p', '-t', pane, '#{pane_pid}'])).trim())
    return Number.isSafeInteger(v) && v > 1 ? v : null
  } catch { return null }
}

/** Focus the Harness desktop app if it is open. True when a window was focused. */
export async function focusHarnessApp(run: Run = defaultRun): Promise<boolean> {
  try {
    const clients = JSON.parse(await run('hyprctl', ['-j', 'clients'])) as Array<{ class?: string; address?: string }>
    const addr = clients.find((c) => c.class === 'com.autonomous.harness')?.address
    if (!addr || !HYPR_ADDR_RE.test(addr)) return false
    return (await run('hyprctl', ['dispatch', `hl.dsp.focus({ window = "address:${addr}" })`])).trim() === 'ok'
  } catch { return false }
}
