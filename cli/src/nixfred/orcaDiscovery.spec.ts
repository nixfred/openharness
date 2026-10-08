import { describe, expect, it } from 'vitest'
import { claudeProjectSlug, discoverOrcaClaudes, type DiscoveryFs } from './orcaDiscovery.js'

const SID = '6d47de34-dfc6-450a-8ac4-a8d92cb6830f'
function fakeFs(over: Partial<DiscoveryFs> = {}): DiscoveryFs {
  return {
    listSessionFiles: () => ['/h/.claude/sessions/100.json', '/h/.claude/sessions/200.json'],
    readText: (p) => p.endsWith('100.json')
      ? JSON.stringify({ pid: 100, sessionId: SID, cwd: '/w/a.b', procStart: '42', kind: 'interactive' })
      : JSON.stringify({ pid: 200, sessionId: SID.replace('6d47', '7e58'), cwd: '/w/c', procStart: '7', kind: 'interactive' }),
    environ: (pid) => pid === 100 ? 'HOME=/h\u0000ORCA_TERMINAL_HANDLE=term_c07405a6-d443-408b\u0000ORCA_TAB_ID=t1\u0000' : 'HOME=/h\u0000',
    procStart: (pid) => (pid === 100 ? '42' : '7'),
    exists: () => true,
    ...over,
  }
}

describe('discoverOrcaClaudes', () => {
  it('finds live Claudes in Orca and outside it (herdr, tmux, plain terminals, IDEs)', () => {
    const found = discoverOrcaClaudes('/h/.claude', fakeFs())
    expect(found).toHaveLength(2)
    expect(found[1]).toMatchObject({ pid: 200, orca: null })
    expect(found[0]).toMatchObject({ pid: 100, sessionId: SID, cwd: '/w/a.b', orca: { terminal: 'term_c07405a6-d443-408b', tab: 't1' } })
    expect(found[0]!.transcriptPath).toBe(`/h/.claude/projects/-w-a-b/${SID}.jsonl`)
  })
  it('picks up a herdr pane from the process environment, validated, and nothing else', () => {
    const env = 'HOME=/h\u0000HERDR_ENV=1\u0000HERDR_PANE_ID=w4F:p1\u0000HERDR_TAB_ID=w4F:t1\u0000HERDR_WORKSPACE_ID=w4F\u0000HERDR_SOCKET_PATH=/h/.config/herdr/herdr.sock\u0000HERDR_BIN_PATH=/usr/bin/herdr\u0000SECRET_TOKEN=x\u0000'
    const found = discoverOrcaClaudes('/h/.claude', fakeFs({ environ: (pid) => (pid === 200 ? env : 'HOME=/h\u0000') }))
    expect(found[1]).toMatchObject({ pid: 200, orca: null, herdr: { pane: 'w4F:p1', tab: 'w4F:t1', workspace: 'w4F', socket: '/h/.config/herdr/herdr.sock', bin: '/usr/bin/herdr' } })
    expect(JSON.stringify(found)).not.toContain('SECRET')
    expect(found[0]!.herdr).toBeNull()
    const hostile = discoverOrcaClaudes('/h/.claude', fakeFs({ environ: () => 'HERDR_PANE_ID=w4F:p1 x\u0000HERDR_BIN_PATH=/bin/sh\u0000' }))
    expect(hostile.every((d) => d.herdr === null)).toBe(true)
  })
  it('ignores a reused pid whose start time does not match', () => {
    expect(discoverOrcaClaudes('/h/.claude', fakeFs({ procStart: () => '99' }))).toHaveLength(0)
  })
  it('ignores a dead pid', () => {
    expect(discoverOrcaClaudes('/h/.claude', fakeFs({ procStart: () => null }))).toHaveLength(0)
  })
  it('slugs a cwd the way Claude names its project folder', () => {
    expect(claudeProjectSlug('/home/pi/Projects/autonomous.harness.device')).toBe('-home-pi-Projects-autonomous-harness-device')
  })
  it('skips the SDK sessions Harness runs itself', () => {
    const fs = fakeFs({ readText: (p) => JSON.stringify({ pid: p.endsWith('100.json') ? 100 : 200, sessionId: SID, cwd: '/h/.harness/cli/data/voice-route-scratch', procStart: p.endsWith('100.json') ? '42' : '7', kind: 'interactive', entrypoint: 'sdk-cli' }) })
    expect(discoverOrcaClaudes('/h/.claude', fs)).toHaveLength(0)
  })
})
