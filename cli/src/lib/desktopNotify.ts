import { execFile } from 'node:child_process'

/**
 * Desktop notification when an agent needs a person: `notify-send` on Linux, `osascript` on macOS. A click
 * takes you to the agent: its herdr pane through `herdr-goto` when the agent runs in herdr and that helper is
 * installed, else the Harness window. Never steals focus on its own (Fred's rule: a notification takes you
 * there only when you click it). Best effort: a desktop without a notification daemon just logs. Injected
 * runner so the daemon's tests never spawn anything.
 */
export interface NotifyDeps {
  run: (cmd: string, args: string[], timeoutMs: number) => Promise<{ stdout: string; code: number }>
  platform: NodeJS.Platform
  has: (cmd: string) => Promise<boolean>
}

const runReal: NotifyDeps['run'] = (cmd, args, timeoutMs) => new Promise((resolve) => {
  execFile(cmd, args, { timeout: timeoutMs }, (err, stdout) => {
    resolve({ stdout: String(stdout ?? ''), code: err ? 1 : 0 })
  })
})

export const systemNotifyDeps: NotifyDeps = {
  run: runReal,
  platform: process.platform,
  has: async (cmd) => (await runReal('sh', ['-c', `command -v ${cmd}`], 2000)).code === 0,
}

export interface AttentionNotice {
  agentName: string
  machine: string
  state: 'waiting' | 'permission' | 'failed'
  detail: string
  /** The herdr pane the agent runs in (nixfred watch mode), the click target when herdr-goto is installed. */
  herdrPane?: string | null
}

/** The only pane id shape handed to herdr-goto, which checks it again. */
const HERDR_PANE = /^[A-Za-z0-9_-]{1,40}(:[A-Za-z0-9_-]{1,40}){1,2}$/

const TITLE: Record<AttentionNotice['state'], string> = {
  waiting: 'is waiting on you', permission: 'needs permission', failed: 'failed',
}

/** The window class to focus on Show; a setting because the class differs per build. */
export const HARNESS_WINDOW_CLASS = process.env.HARNESS_WINDOW_CLASS ?? 'harness'

export async function notifyAttention(n: AttentionNotice, deps: NotifyDeps = systemNotifyDeps): Promise<'sent' | 'skipped'> {
  const title = `${n.agentName} ${TITLE[n.state]}`
  const body = `${n.machine}${n.detail ? `: ${n.detail}` : ''}`.slice(0, 200)
  if (deps.platform === 'darwin') {
    await deps.run('osascript', ['-e', `display notification ${JSON.stringify(body)} with title ${JSON.stringify(title)}`], 3000)
    return 'sent'
  }
  if (!(await deps.has('notify-send'))) return 'skipped'
  const urgency = n.state === 'permission' || n.state === 'failed' ? 'critical' : 'normal'
  const pane = n.herdrPane && HERDR_PANE.test(n.herdrPane) && await deps.has('herdr-goto') ? n.herdrPane : null
  // `default` is the action a click on the toast's body invokes. Omarchy runs the omarchy-exec-argv hint
  // instead and keeps it with the toast in its history, so that click still works once this process is gone.
  const args = ['--app-name=Harness', `--urgency=${urgency}`, '--action=default=Show me', '--wait', '--expire-time=15000']
  if (pane) args.push(`--hint=string:omarchy-exec-argv:${JSON.stringify(['herdr-goto', pane])}`)
  // --wait blocks until the notification closes and prints the chosen action id; run it detached
  // from the caller's await so a notification left on screen never holds the daemon.
  void deps.run('notify-send', [...args, '--', title, body], 20_000)
    .then(async (r) => {
      if (r.stdout.trim() !== 'default') return
      if (pane) await deps.run('herdr-goto', [pane], 5000)
      else if (await deps.has('hyprctl')) await focusHarnessWindow(deps)
    })
    .catch(() => {})
  return 'sent'
}

/** Hyprland 0.56+ (Lua config) takes a Lua dispatch and rejects the classic form; older builds the reverse. */
async function focusHarnessWindow(deps: NotifyDeps): Promise<void> {
  const selector = `class:^(${HARNESS_WINDOW_CLASS})$`
  const lua = await deps.run('hyprctl', ['dispatch', `hl.dsp.focus({ window = ${JSON.stringify(selector)} })`], 3000)
  if (lua.code !== 0) await deps.run('hyprctl', ['dispatch', 'focuswindow', selector], 3000)
}
