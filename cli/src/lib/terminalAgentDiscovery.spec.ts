import { describe, expect, it } from 'vitest'
import type { ProcessRow } from './tmux.js'
import { discoverTerminalAgentsFromSnapshot } from './terminalAgentDiscovery.js'
import { terminalRouteKey } from './terminalRuntime.js'
import type { TerminalRootObservation } from './terminalTypes.js'

const start = 'Sat Aug 15 10:00:00 2026'
const shell = (pid: number, parentPid: number): ProcessRow => ({ pid, parentPid, executable: 'bash', startMarker: start, args: 'bash' })
const claude = (pid: number, parentPid: number): ProcessRow => ({ pid, parentPid, executable: 'claude', startMarker: start, args: 'claude' })

const tmux: TerminalRootObservation = {
  runtime: { backend: 'tmux', paneId: '%1' }, rootPid: 10, cwd: '/work',
}
const nested: TerminalRootObservation = {
  runtime: { backend: 'tmux', paneId: '%2' }, rootPid: 20, cwd: '/work',
}

describe('process discovery', () => {
  it('deduplicates nested roots by engine PID and start marker', () => {
    const result = discoverTerminalAgentsFromSnapshot(
      [tmux, nested],
      [shell(10, 1), shell(20, 10), claude(30, 20)],
      999,
      ['tmux'],
    )
    expect(result.agents).toHaveLength(1)
    expect(result.agents[0].runtimes).toHaveLength(2)
    expect(result.agents[0].primaryRuntimeKey).toBe(terminalRouteKey(nested.runtime))
  })

  it('chooses the nearest root as primary', () => {
    const result = discoverTerminalAgentsFromSnapshot(
      [tmux, nested],
      [shell(20, 1), shell(25, 20), shell(10, 25), claude(30, 10)],
      999,
      ['tmux'],
    )
    expect(result.agents[0].primaryRuntimeKey).toBe(terminalRouteKey(tmux.runtime))
  })
})
