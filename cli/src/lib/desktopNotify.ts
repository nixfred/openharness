import { execFile } from 'node:child_process'

/**
 * Desktop notification when an agent needs a person: `notify-send` on Linux with a "Show" action that
 * focuses the Harness window, `osascript` on macOS. Never steals focus on its own (Fred's rule: a
 * notification takes you there only when you click it). Best effort: a desktop without a notification
 * daemon just logs. Injected runner so the daemon's tests never spawn anything.
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
}

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
  // --wait blocks until the notification closes and prints the chosen action id; run it detached
  // from the caller's await so a notification left on screen never holds the daemon.
  void deps.run('notify-send', ['--app-name=Harness', `--urgency=${urgency}`, '--action=show=Show me', '--wait', '--expire-time=15000', title, body], 20_000)
    .then(async (r) => {
      if (r.stdout.trim() === 'show' && await deps.has('hyprctl')) {
        await deps.run('hyprctl', ['dispatch', 'focuswindow', `class:^(${HARNESS_WINDOW_CLASS})$`], 3000)
      }
    })
    .catch(() => {})
  return 'sent'
}
