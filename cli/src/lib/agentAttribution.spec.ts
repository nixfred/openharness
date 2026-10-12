import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { AGENT_ATTRIBUTION_LINE, agentLaunchArgs, HARNESS_INSTRUCTIONS, joinedInstructions } from './agentAttribution.js'
import { agentSettingsPath } from './agentSettings.js'
import { setAgentSettingsForTest, signedOutForTest } from '../testing/agentSettings.js'

let dataDir = ''
beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), 'agent-attribution-'))
  // The account has turned both on: off by default (lib/agentSettings.ts). A test of the default removes the file.
  setAgentSettingsForTest(dataDir, { agentsStartAgents: true, pullRequestLine: true })
})
afterEach(() => { rmSync(dataDir, { recursive: true, force: true }); signedOutForTest() })

/** A launch that reads no settings: nothing the person set. */
const place = { cwd: null, read: () => null }
const claudeLine = ['--settings', JSON.stringify({ attribution: { pr: `🤖 Generated with [Claude Code](https://claude.com/claude-code)\n${AGENT_ATTRIBUTION_LINE}` } })]
const claudeTold = ['--append-system-prompt', HARNESS_INSTRUCTIONS]
/** Codex is told besides that its sandbox cannot reach Harness (engines/codex/launch.ts). */
const CODEX_TOLD = `${HARNESS_INSTRUCTIONS} Codex's sandbox cannot reach Harness: run each harness command outside it, with escalated permissions.`
/** The pull request line told as an instruction too: a setting alone was dropped once a task spelled out the body. */
const claudePrTold = expect.stringContaining(`its body must include this exact line once, near the end and after any other attribution line: \`${AGENT_ATTRIBUTION_LINE}\``)
const codexValue = (...texts: string[]) => ['-c', `developer_instructions=${JSON.stringify(texts.join('\n\n'))}`]

describe('what Harness tells an agent as it starts', () => {
  it('is the line the owner chose, and the instructions every harness gets', () => {
    expect(AGENT_ATTRIBUTION_LINE).toBe('🤝 Started by another agent in [Harness](https://harness.autonomous.ai) — agents that run agents.')
    expect(HARNESS_INSTRUCTIONS).toBe('You are running in Harness, and the person can watch you. You can hand work to other agents (Claude Code, Codex) that run in their own harnesses: `harness new`, `harness wait`, `harness show`, `harness close` (see `harness --help`). Start one only for work that can run in parallel, needs another model, or takes long; do quick work yourself, and close each one once you have its answer. Only use or close harnesses you started.')
  })

  it('tells every harness how to use Harness, and adds the pull request line only to one another agent started', () => {
    const told = agentLaunchArgs('claude', 'agent', place, dataDir)
    expect(told).toEqual([...claudeLine, '--append-system-prompt', claudePrTold])
    expect(told[3].startsWith(`${HARNESS_INSTRUCTIONS}\n\nWhen you create or update a pull request`)).toBe(true)
    expect(agentLaunchArgs('claude', null, place, dataDir)).toEqual(claudeTold)
    expect(agentLaunchArgs('claude', undefined, place, dataDir)).toEqual(claudeTold)
    // Codex keeps both in one config value: a second -c of the same key would replace the first.
    const instruction = expect.stringContaining(AGENT_ATTRIBUTION_LINE)
    const both = agentLaunchArgs('codex', 'agent', place, dataDir)
    expect(both).toHaveLength(2)
    expect(JSON.parse(both[1].slice('developer_instructions='.length))).toEqual(expect.stringMatching(new RegExp(`^${CODEX_TOLD.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\n\nWhen you create or update a pull request`)))
    expect(both[1]).toEqual(instruction)
    expect(agentLaunchArgs('codex', null, place, dataDir)).toEqual(codexValue(CODEX_TOLD))
    // An engine with no way to be told: nothing.
    expect(agentLaunchArgs('opencode', 'agent', place, dataDir)).toEqual([])
  })

  it('tells an agent nothing of Harness, and adds no line, for an account that never turned either on, or signed out', () => {
    rmSync(agentSettingsPath(dataDir))
    for (const startedBy of ['agent', null] as const) {
      expect(agentLaunchArgs('claude', startedBy, place, dataDir)).toEqual([])
      expect(agentLaunchArgs('codex', startedBy, place, dataDir)).toEqual([])
    }
    setAgentSettingsForTest(dataDir, { agentsStartAgents: true, pullRequestLine: true })
    signedOutForTest()
    expect(agentLaunchArgs('claude', 'agent', place, dataDir)).toEqual([])
  })

  it('follows the person\'s switches: no instructions once agents may not start agents, no line once that is off', () => {
    setAgentSettingsForTest(dataDir, { agentsStartAgents: false })
    expect(agentLaunchArgs('claude', null, place, dataDir)).toEqual([])
    // The pull request line, and its instruction, without Harness's own instructions.
    expect(agentLaunchArgs('claude', 'agent', place, dataDir)).toEqual([...claudeLine, '--append-system-prompt', claudePrTold])
    expect(agentLaunchArgs('claude', 'agent', place, dataDir)[3].startsWith('When you create or update a pull request')).toBe(true)
    expect(agentLaunchArgs('codex', null, place, dataDir)).toEqual([])
    setAgentSettingsForTest(dataDir, { agentsStartAgents: true, pullRequestLine: false })
    expect(agentLaunchArgs('claude', 'agent', { cwd: '/w', read: () => null }, dataDir)).toEqual(claudeTold)
    setAgentSettingsForTest(dataDir, { agentsStartAgents: false })
    expect(agentLaunchArgs('claude', 'agent', { cwd: '/w', read: () => { throw new Error('read nothing') } }, dataDir)).toEqual([])
  })

  it('tells Claude Code nothing of the line where the person hid its attribution', () => {
    const hidden = { cwd: null, read: (path: string) => path.endsWith('settings.json') ? JSON.stringify({ attribution: false }) : null }
    expect(agentLaunchArgs('claude', 'agent', hidden, dataDir)).toEqual(claudeTold)
  })

  it('keeps the person\'s own Codex instructions first, and says nothing they already say', () => {
    const theirs = { cwd: null, read: (path: string) => path.endsWith('config.toml') ? 'developer_instructions = "Be brief."\n' : null }
    expect(agentLaunchArgs('codex', null, theirs, dataDir)).toEqual(codexValue('Be brief.', CODEX_TOLD))
    const said = { cwd: null, read: (path: string) => path.endsWith('config.toml') ? `developer_instructions = ${JSON.stringify(CODEX_TOLD)}\n` : null }
    expect(agentLaunchArgs('codex', null, said, dataDir)).toEqual([])
  })

  it('joins every appended system prompt into one, for Claude Code; leaves other engines\' arguments alone', () => {
    expect(joinedInstructions('claude', ['--system-prompt-snapshot', 'off', '--append-system-prompt', 'grid', '--agent', 'x', '--append-system-prompt', 'ours']))
      .toEqual(['--system-prompt-snapshot', 'off', '--agent', 'x', '--append-system-prompt', 'grid\n\nours'])
    expect(joinedInstructions('claude', ['--agent', 'x'])).toEqual(['--agent', 'x'])
    // A flag with no value after it is left as it is.
    expect(joinedInstructions('claude', ['--append-system-prompt'])).toEqual(['--append-system-prompt'])
    expect(joinedInstructions('codex', ['-c', 'a=1', '-c', 'a=2'])).toEqual(['-c', 'a=1', '-c', 'a=2'])
  })
})
