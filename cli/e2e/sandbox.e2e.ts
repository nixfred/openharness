/**
 * `harness` in an agent's sandbox, with a daemon that runs and with none (lib/unreachable.ts).
 *
 * Codex runs an agent's commands under seatbelt, marked CODEX_SANDBOX=seatbelt and CODEX_SANDBOX_NETWORK_DISABLED=1. In
 * a clean-VM test of CLI 0.3.75 a Codex harness was told by `harness new` that Harness was not running, ran `harness
 * start` (mkdir EPERM), and asked the person "May I start Harness?" for a Harness that was running (#1213). The sandbox
 * here is sandbox-exec with the refusals `codex sandbox` 0.162.1 was measured making on 2026-10-11: a signal to the
 * daemon (kill EPERM), a connect to its socket or its port, or to a port nobody listens on (EPERM), a write in its data
 * folder (mkdir EPERM). With nothing running, the same sandbox must not be told Harness runs. macOS only.
 */
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, realpathSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, describe, expect, it, onTestFailed } from 'vitest'
import { NOT_RUNNING, SANDBOXED, START_OUTSIDE } from '../src/lib/unreachable.js'
import { CLI_ROOT, IsolatedDaemon } from './harness/daemon.js'

const SANDBOX_EXEC = '/usr/bin/sandbox-exec'

/** Codex's seatbelt, as far as `harness` meets it: no signal outside the sandbox, no network, no writes in the data folder. */
const policy = (dataDir: string) => [
  '(version 1)',
  '(allow default)',
  '(deny network-outbound (remote ip) (remote unix-socket))',
  '(deny signal)',
  '(allow signal (target same-sandbox))',
  `(deny file-write* (subpath ${JSON.stringify(realpathSync(dataDir))}))`,
].join('')

/** `harness <args>` as Codex runs it from its shell tool: sandboxed unless [outside], marked as Codex marks it. */
function harness(d: IsolatedDaemon, args: string[], outside = false): Promise<{ code: number; out: string; err: string }> {
  const cli = [process.execPath, '--import', 'tsx', 'src/cli.ts', ...args]
  const [command, ...argv] = outside ? cli : [SANDBOX_EXEC, '-p', policy(d.dataDir), ...cli]
  return new Promise((done) => {
    const child = spawn(command, argv, {
      cwd: CLI_ROOT,
      env: { ...d.env, TMUX_PANE: '', CODEX_THREAD_ID: 'e2e-codex-thread', ...(outside ? {} : { CODEX_SANDBOX: 'seatbelt', CODEX_SANDBOX_NETWORK_DISABLED: '1' }) },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let out = '', err = ''
    child.stdout.on('data', (chunk) => { out += chunk })
    child.stderr.on('data', (chunk) => { err += chunk })
    child.on('close', (code) => done({ code: code ?? -1, out, err }))
  })
}

const pidIn = (d: IsolatedDaemon): string => existsSync(join(d.dataDir, 'adapter.pid')) ? readFileSync(join(d.dataDir, 'adapter.pid'), 'utf8').trim() : ''

describe.skipIf(process.platform !== 'darwin' || !existsSync(SANDBOX_EXEC))('harness in an agent\'s sandbox', () => {
  let daemon: IsolatedDaemon | undefined
  afterEach(async () => { await daemon?.close(); daemon = undefined })

  it('says Harness runs and the sandbox is in the way, and never starts a second one; says not running only when it is not', async () => {
    const d = await IsolatedDaemon.create()
    daemon = d
    onTestFailed(() => { console.log(`---- daemon log\n${d.log().split('\n').slice(-150).join('\n')}`) })
    await d.start()
    const folder = join(d.projectsDir, 'opinion')
    mkdirSync(folder, { recursive: true })

    // Outside the sandbox (escalated), the verbs reach it.
    const escalated = await harness(d, ['ps'], true)
    expect(escalated.code, escalated.err).toBe(0)

    // Sandboxed: running, and out of reach.
    const ps = await harness(d, ['ps'])
    expect(ps.code).toBe(1)
    expect(ps.err.trim()).toBe(SANDBOXED)
    const made = await harness(d, ['new', 'claude', folder, '--name', 'python-indent-opinion', '--json', '--', 'A second opinion, please.'])
    expect(made.code).toBe(1)
    expect(made.err.trim()).toBe(SANDBOXED)
    const pid = pidIn(d)
    const start = await harness(d, ['start'])
    expect(start.code).toBe(1)
    expect(start.err).toContain(SANDBOXED)
    expect(start.err).not.toContain('EPERM')
    // The daemon that runs is the one there was.
    expect(pidIn(d)).toBe(pid)
    const status = await harness(d, ['status'])
    expect(status.out).toContain('out of reach')

    // Nothing running: not "Harness is running", in the sandbox or out of it; start it, outside the sandbox.
    await d.stop()
    const outside = await harness(d, ['ps'], true)
    expect(outside.err.trim()).toBe(NOT_RUNNING)
    const down = await harness(d, ['ps'])
    expect(down.code).toBe(1)
    expect(down.err.trim()).toBe(START_OUTSIDE)
    const downNew = await harness(d, ['new', 'claude', folder, '--name', 'python-indent-opinion', '--', 'A second opinion, please.'])
    expect(downNew.code).toBe(1)
    expect(downNew.err.trim()).toBe(START_OUTSIDE)
    const downStart = await harness(d, ['start'])
    expect(downStart.code).toBe(1)
    expect(downStart.err).toContain(START_OUTSIDE)
    expect(downStart.err).not.toContain('EPERM')
    const status2 = await harness(d, ['status'])
    expect(status2.out).toContain('○ stopped')
    // No daemon was started from inside the sandbox.
    expect(IsolatedDaemon.alive(Number(pidIn(d)) || null)).toBe(false)
  })
})
