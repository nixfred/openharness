/**
 * A harness another agent started says so in the pull requests it opens: one line beside the engine's own
 * ("🤖 Generated with Claude Code"), so every reader of the pull request, and their agents, sees it was made in
 * Harness (docs/design/2026-10-11-agent-client.md, "Pull requests"). A harness a person started is not marked.
 *
 * Who started a harness is its row's (`startedBy`, sent by `harness new` when an agent runs it); how each engine is
 * told is its launch contract's (`EngineLaunch.attribution`, engines/launches.ts `attributionArgs`). The person turns
 * it on for the account with `harness settings pull-request-line on` or in Settings ▸ Experimental (lib/agentSettings.ts),
 * read at each launch, so a relaunch follows it too.
 */
import { env } from '../config/env.js'
import { agentInstructionArgs, launchContract, type AttributionPlace } from '../engines/launches.js'
import { readAgentSettings } from './agentSettings.js'

/** The line: short and plain, as the engines' own are, and linked to Harness's site. */
export const AGENT_ATTRIBUTION_LINE = '🤝 Started by another agent in [Harness](https://harness.autonomous.ai) — agents that run agents.'

/** Who started a harness, as `agent_create` takes it and its row keeps it: another agent; absent, the person. */
export type StartedBy = 'agent'

/**
 * What every harness is told as it starts, while the person lets agents start agents (Settings ▸ Experimental): that it runs in
 * Harness, the verbs that hand work to another agent, and when to: every harness started spends the person's tokens, so
 * only for work that gains from it, and closed once answered (owner, October 12). An agent that does not know Harness is
 * there never uses it, and every harness Harness starts is an agent that could (docs/design/2026-10-11-agent-client.md).
 * It is in every system prompt: keep it short.
 */
export const HARNESS_INSTRUCTIONS = 'You are running in Harness, and the person can watch you. You can hand work to other agents '
  + '(Claude Code, Codex) that run in their own harnesses: `harness new`, `harness wait`, `harness show`, `harness close` '
  + '(see `harness --help`). Start one only for work that can run in parallel, needs another model, or takes long; '
  + 'do quick work yourself, and close each one once you have its answer. Only use or close harnesses you started.'

/**
 * A launch's argv for what Harness tells the agent: the instructions above while agents may start agents, and the pull
 * request line for a harness another agent started while the person has that on. Read at each launch, so a relaunch
 * follows the switches as they are then.
 */
export function agentLaunchArgs(engine: string, startedBy: StartedBy | null | undefined, place: AttributionPlace,
  dataDir: string = env.ADAPTER_DATA_DIR): string[] {
  const settings = readAgentSettings(dataDir)
  return agentInstructionArgs(engine, {
    instructions: settings.agentsStartAgents ? HARNESS_INSTRUCTIONS : null,
    prLine: startedBy === 'agent' && settings.pullRequestLine ? AGENT_ATTRIBUTION_LINE : null,
  }, place)
}

/**
 * [args] with every appended system prompt joined into one, for an engine that takes Harness's instructions that way:
 * a grid launch and a store harness append their own (lib/gridWebMcp.ts, the DSH's `contextArgs`), and an engine that
 * keeps only the last of a repeated flag would drop the others.
 */
export function joinedInstructions(engine: string, args: readonly string[]): string[] {
  const told = launchContract(engine)?.harnessInstructions
  if (told?.kind !== 'append') return [...args]
  const flag = told.args[0]
  const texts: string[] = []
  const rest: string[] = []
  for (let i = 0; i < args.length; i++) {
    if (args[i] === flag && i + 1 < args.length) { texts.push(args[++i]); continue }
    rest.push(args[i])
  }
  return texts.length ? [...rest, flag, texts.join('\n\n')] : rest
}
