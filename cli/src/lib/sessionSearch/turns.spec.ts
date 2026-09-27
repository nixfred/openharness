import { describe, expect, it } from 'vitest'

import type { LiveEvent } from '../normalize.js'
import { ANSWER_MAX, ASK_MAX, TOOLS_MAX, TurnCollector, searchableText, toolText } from './turns.js'

const ask = (text: string): LiveEvent => ({ type: 'turn_started', payload: { userMessage: text } })
const say = (text: string): LiveEvent => ({ type: 'text_delta', payload: { content: text } })
const tool = (name: string, input: unknown): LiveEvent => ({ type: 'tool_start', payload: { id: name, tool: name, input } })

describe('TurnCollector', () => {
  it('folds prompts, answers and tool calls into turns, the last one left open', () => {
    const turns = new TurnCollector(0)
    turns.feed([ask('Port the daemon to Windows')], 0, 1_000)
    turns.feed([say('Reading the tmux backend first.'), tool('Read', { file_path: 'cli/src/lib/tmux.ts' })], 40, 1_100)
    turns.feed([say('It needs a named-pipe transport.'), { type: 'turn_ended', payload: {} }], 90, 1_200)
    turns.feed([ask('ok do it')], 130, 2_000)
    const { closed, open } = turns.finish()
    expect(closed).toEqual([{
      turn: 0, offset: 0, at: 1_000, ask: 'Port the daemon to Windows',
      answer: 'Reading the tmux backend first. It needs a named-pipe transport.',
      tools: 'Read cli/src/lib/tmux.ts',
    }])
    expect(open).toMatchObject({ turn: 1, offset: 130, at: 2_000, ask: 'ok do it', answer: '' })
    expect(turns.next).toBe(2)
  })

  it('counts a prompt announced twice as one turn, and a replayed user_message as a new one', () => {
    const turns = new TurnCollector(5)
    turns.feed([ask('fix the dial scroll'), { type: 'user_message', payload: { content: 'fix the dial scroll' } }], 0, null)
    turns.feed([say('done')], 10, null)
    turns.feed([{ type: 'user_message', payload: { content: 'now the pane title' } }], 20, null)
    const { closed, open } = turns.finish()
    expect(closed.map((turn) => [turn.turn, turn.ask])).toEqual([[5, 'fix the dial scroll']])
    expect(open).toMatchObject({ turn: 6, ask: 'now the pane title' })
  })

  it('keeps text that arrives before any prompt as a turn of its own, and drops empty ones', () => {
    const turns = new TurnCollector(0)
    turns.feed([say('…and the tests pass.')], 0, null)
    turns.feed([ask('')], 10, null)
    turns.feed([ask('next')], 20, null)
    const { closed, open } = turns.finish()
    expect(closed.map((turn) => [turn.ask, turn.answer])).toEqual([['', '…and the tests pass.']])
    expect(open?.ask).toBe('next')
  })

  it('bounds every field, keeping the end of a long answer where the outcome is', () => {
    const turns = new TurnCollector(0)
    turns.feed([ask('x'.repeat(ASK_MAX * 2))], 0, null)
    for (let i = 0; i < 400; i++) turns.feed([say(`step ${i} ${'y'.repeat(200)}`)], i, null)
    turns.feed([say('FINAL OUTCOME')], 500, null)
    for (let i = 0; i < 200; i++) turns.feed([tool('Bash', { command: `echo ${i} ${'z'.repeat(100)}` })], 600 + i, null)
    const { open } = turns.finish()
    expect(open!.ask.length).toBe(ASK_MAX)
    expect(open!.answer.length).toBeLessThanOrEqual(ANSWER_MAX + 3)
    expect(open!.answer.startsWith('step 0 ')).toBe(true)
    expect(open!.answer.endsWith('FINAL OUTCOME')).toBe(true)
    expect(open!.tools.length).toBeLessThanOrEqual(TOOLS_MAX)
  })
})

describe('what the person asked, and what they did not', () => {
  it('files a sub-agent hand-back under the agent, and drops notices', () => {
    const turns = new TurnCollector(0)
    turns.feed([ask('Another Claude session sent a message: <agent-message from="a1">[Subagent hand-back] the dial audit found 3 bugs</agent-message>')], 0, null)
    turns.feed([say('Fixing them now.')], 10, null)
    turns.feed([ask('Your claude.ai usage limit has reset. Continue the task you were working on.')], 20, null)
    turns.feed([ask('now flash it')], 30, null)
    const { closed, open } = turns.finish()
    // The notice leaves nothing behind; the hand-back is the agent's text, not an ask.
    expect(closed).toHaveLength(1)
    expect(closed[0].ask).toBe('')
    expect(closed[0].answer).toContain('the dial audit found 3 bugs')
    expect(closed[0].answer).toContain('Fixing them now.')
    expect(open?.ask).toBe('now flash it')
  })

  it('counts a hand-back announced twice as one turn', () => {
    const turns = new TurnCollector(0)
    const report = 'Another Claude session sent a message: the audit is done'
    turns.feed([ask(report), { type: 'user_message', payload: { content: report } }], 0, null)
    turns.feed([ask('thanks, ship it')], 10, null)
    const { closed } = turns.finish()
    expect(closed).toHaveLength(1)
  })
})

describe('searchableText', () => {
  it('drops harness wrappers, folds whitespace and blanks secrets', () => {
    expect(searchableText('<system-reminder>ignore\nthis</system-reminder>deploy   with\nsk-abcdefghijklmnop', 100))
      .toBe('deploy with sk-<redacted>')
    expect(searchableText('<command-name>/clear</command-name> hello', 100)).toBe('hello')
    expect(searchableText('see <pasted_content id="c200"> https://github.com/x/y/issues/167 </pasted_content id="c200">', 100))
      .toBe('see https://github.com/x/y/issues/167')
  })
})

describe('toolText', () => {
  it('keeps the paths, commands and queries a person would search by', () => {
    expect(toolText('Edit', { file_path: 'desktop/lib/state/swarm_search.dart', old_string: 'a'.repeat(5000) }))
      .toBe('Edit desktop/lib/state/swarm_search.dart')
    expect(toolText('Bash', { command: "python3 - <<'EOF'\nprint(1)\nEOF", description: 'Run the probe' }))
      .toBe("Bash python3 - <<'EOF' Run the probe")
    expect(toolText('WebSearch', '{"query":"fts5 prefix index"}')).toBe('WebSearch fts5 prefix index')
  })

  it('drops encoded blobs, which are never words anybody searches for', () => {
    expect(toolText('Task', { description: `gAAAAB${'q'.repeat(120)} audit onboarding` })).toBe('Task audit onboarding')
  })

  it('names a patch by its files, never its contents', () => {
    const patch = '*** Begin Patch\n*** Update File: cli/src/cli.ts\n@@\n-secret\n+other\n*** Add File: docs/a.md\n*** End Patch'
    expect(toolText('apply_patch', patch)).toBe('apply_patch cli/src/cli.ts docs/a.md')
    expect(toolText('apply_patch', { input: patch })).toBe('apply_patch cli/src/cli.ts docs/a.md')
  })
})
