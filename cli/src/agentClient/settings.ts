/**
 * `harness settings`: what the person lets agents do (lib/agentSettings.ts), the account's three experiments in
 * Settings ▸ Experimental, for a terminal or a machine with no window. Each is off until the person turns it on.
 *
 *     harness settings                          every setting and its state
 *     harness settings agents-start-agents on   turn one on or off, for the account
 *
 * It asks this computer's daemon (`/api/agent-settings`), which reads them as this computer keeps them and writes a
 * change through to the account (core/experiments.ts `createAgentSettingsSync`): the copy is the daemon's alone.
 */
import { AGENT_SETTING_NAMES, type AgentSettings } from '../lib/agentSettings.js'
import { daemonUnreachableText } from '../lib/daemonState.js'

export const SETTINGS_USAGE = `Usage: harness settings [<name> on|off]

What agents may do, as Settings ▸ Experimental shows it: experiments of your account, the same on each of its
computers, and each off until you turn it on:
  agents-start-agents   agents may start, wait for and close harnesses of their own, and are told how
  pull-request-line     a harness another agent starts says so in the pull requests it opens: one line beside the
                        engine's own
  agent-messages        agents in the same tab may message each other with harness send`

const ABOUT: Record<keyof AgentSettings, string> = {
  agentsStartAgents: 'agents may start, wait for and close harnesses of their own',
  pullRequestLine: 'a harness another agent starts says so in the pull requests it opens',
  agentMessages: 'agents in the same tab may message each other',
}

export const SETTINGS_SIGNED_OUT = 'Signed out: these are experiments of your account. Sign in (harness login) to turn them on.'

export interface SettingsDeps {
  /** This computer's daemon's port (lib/daemonState.ts `daemonPort`). */
  port: number
  fetch?: typeof fetch
  out?: (line: string) => void
  err?: (line: string) => void
}

type Answer = { status: number; body: Record<string, unknown> }

export async function settingsCommand(argv: readonly string[], deps: SettingsDeps): Promise<number> {
  const out = deps.out ?? console.log
  const err = deps.err ?? console.error
  if (argv.includes('--help') || argv.includes('-h')) { out(SETTINGS_USAGE); return 0 }
  let change: Record<string, boolean> | null = null
  if (argv.length) {
    const [name, value, ...rest] = argv
    const key = AGENT_SETTING_NAMES[name]
    if (!key || (value !== 'on' && value !== 'off') || rest.length) { err(SETTINGS_USAGE); return 2 }
    change = { [key]: value === 'on' }
  }
  let answer: Answer
  try {
    const response = await (deps.fetch ?? fetch)(`http://127.0.0.1:${deps.port}/api/agent-settings`, {
      method: change ? 'PATCH' : 'GET',
      // The local API's CSRF gate: a write must say it comes from this computer.
      headers: { 'x-adapter-local': '1', ...(change ? { 'content-type': 'application/json' } : {}) },
      ...(change ? { body: JSON.stringify(change) } : {}),
      signal: AbortSignal.timeout(20_000),
    })
    answer = { status: response.status, body: (await response.json().catch(() => ({}))) as Record<string, unknown> }
  } catch (error) {
    err(daemonUnreachableText((error as { cause?: unknown }).cause ?? error))
    return 1
  }
  if (answer.status !== 200) {
    const error = answer.body.error as { message?: unknown } | undefined
    err(typeof error?.message === 'string' ? error.message : `Harness could not ${change ? 'change' : 'read'} the settings (${answer.status}).`)
    return 1
  }
  if (change) {
    const [key] = Object.keys(change) as Array<keyof AgentSettings>
    const name = Object.keys(AGENT_SETTING_NAMES).find((each) => AGENT_SETTING_NAMES[each] === key)!
    out(`${name} is ${answer.body[key] === true ? 'on' : 'off'} for your account.`)
    return 0
  }
  out(Object.entries(AGENT_SETTING_NAMES)
    .map(([name, key]) => `${name.padEnd(22)}${answer.body[key] === true ? 'on ' : 'off'}  ${ABOUT[key]}`).join('\n'))
  if (answer.body.signedIn === false) out(SETTINGS_SIGNED_OUT)
  return 0
}
