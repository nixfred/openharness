import { EventEmitter } from 'node:events'
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { openDaemon, type ClientSocket } from './daemon.js'
import { localSocketPath } from '../lib/localSocket.js'
import { NOT_RUNNING, SANDBOXED } from '../lib/unreachable.js'

/** A socket whose connection fails with [code], as Codex's sandbox refuses the daemon's (2026-10-12). */
function failing(code: string): ClientSocket {
  const socket = new EventEmitter() as unknown as ClientSocket
  setImmediate(() => (socket as unknown as EventEmitter).emit('error', Object.assign(new Error(code), { code })))
  return socket
}

describe('a line to the daemon that cannot open', () => {
  let dataDir: string
  let saved: Record<string, string | undefined>
  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), 'agent-daemon-'))
    // The suite may itself run in Codex's sandbox; these cases are about the error and the pid file alone.
    saved = { CODEX_SANDBOX: process.env.CODEX_SANDBOX, CODEX_SANDBOX_NETWORK_DISABLED: process.env.CODEX_SANDBOX_NETWORK_DISABLED }
    delete process.env.CODEX_SANDBOX
    delete process.env.CODEX_SANDBOX_NETWORK_DISABLED
  })
  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true })
    for (const [name, value] of Object.entries(saved)) if (value !== undefined) process.env[name] = value
  })
  const where = () => ({ port: 1, dataDir, machineId: 'm1' })
  /** The pid file of the daemon the line is to: this test's own process, which exists. */
  const running = () => writeFileSync(join(dataDir, 'adapter.pid'), `${process.pid}\n`)

  it('says a sandbox keeps it out when the connection was not permitted, and never to start Harness', async () => {
    running()
    await expect(openDaemon(where(), 'm1', () => failing('EPERM'))).rejects.toMatchObject({ code: 'DAEMON_UNREACHABLE', message: SANDBOXED })
  })

  it('says to start Harness when nothing answers, or when nothing is there behind a refusal', async () => {
    running()
    await expect(openDaemon(where(), 'm1', () => failing('ECONNREFUSED'))).rejects.toMatchObject({ code: 'DAEMON_UNREACHABLE', message: NOT_RUNNING })
    // The pid file of the daemon the line is to decides: seatbelt refuses a port nobody listens on with EPERM too.
    rmSync(join(dataDir, 'adapter.pid'))
    await expect(openDaemon(where(), 'm1', () => failing('EPERM'))).rejects.toMatchObject({ code: 'DAEMON_UNREACHABLE', message: NOT_RUNNING })
  })

  // Root opens a socket whatever its mode, so the refusal cannot be made there.
  it.skipIf(process.getuid?.() === 0)('reads a real refused socket as a sandbox\'s, through the real connect', async () => {
    running()
    const path = localSocketPath(dataDir, 1)!
    const server = createServer((socket) => socket.end())
    await new Promise<void>((done) => server.listen(path, done))
    try {
      // A socket this process may not open answers EACCES, as one a sandbox refuses does.
      chmodSync(path, 0)
      await expect(openDaemon(where())).rejects.toMatchObject({ code: 'DAEMON_UNREACHABLE', message: SANDBOXED })
    } finally { await new Promise((done) => server.close(done)) }
  })
})
