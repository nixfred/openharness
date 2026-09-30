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
  it('finds a live Claude in an Orca terminal and skips one outside Orca', () => {
    const found = discoverOrcaClaudes('/h/.claude', fakeFs())
    expect(found).toHaveLength(1)
    expect(found[0]).toMatchObject({ pid: 100, sessionId: SID, cwd: '/w/a.b', orca: { terminal: 'term_c07405a6-d443-408b', tab: 't1' } })
    expect(found[0]!.transcriptPath).toBe(`/h/.claude/projects/-w-a-b/${SID}.jsonl`)
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
})
