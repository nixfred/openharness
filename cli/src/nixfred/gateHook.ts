/**
 * nixfred: the opt-in destructive-action gate hook for Claude Code (`harness gate install`).
 *
 * Upstream #1045 turned Claude Code's session hooks into a declared contract (engines/claude/hookContract.ts)
 * applied by one kit installer, and deleted engines/claude/installHooks.ts, where the fork kept this gate
 * installer beside upstream's. The session hooks (with the fork's Notification event for watch mode) are
 * upstream's contract now; the gate stays its own small installer here, because it is opt-in and must never
 * run at `harness start`. Unchanged from the 2026-10-08 sync: same file, same block, same matcher.
 */
import { mkdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { homedir } from 'node:os'
import { command, isOurs, writeJsonAtomic, type Settings } from '../engines/kit/notifyHooks.js'

const SETTINGS_PATH = join(homedir(), '.claude', 'settings.json')

/**
 * The destructive-action gate for Claude Code (nixfred): a PreToolUse hook on the tools that can change the
 * world. OPT-IN (`harness gate install`), never part of `harness start`: it edits a person's own Claude
 * settings, and the gate only earns its place once a policy has been read and agreed to. The same
 * notify script serves it; the daemon answers with a `permissionDecision` the engine understands.
 */
export const GATE_EVENT = 'PreToolUse'
export const GATE_MATCHER = 'Bash|Write|Edit|MultiEdit|NotebookEdit'

export function installGateHook(port: number): 'installed' | 'updated' | 'unchanged' | 'failed' {
  let settings: Settings = {}
  try { settings = JSON.parse(readFileSync(SETTINGS_PATH, 'utf-8')) as Settings } catch { /* start empty */ }
  if (!settings.hooks || typeof settings.hooks !== 'object') settings.hooks = {}
  const cmd = command(port, 'claude')
  const blocks = Array.isArray(settings.hooks[GATE_EVENT]) ? settings.hooks[GATE_EVENT] : []
  const foreign = blocks.filter((b) => !isOurs(b))
  const ours = blocks.filter(isOurs)
  const existingCmd = ours[0]?.hooks?.find((h) => isOurs({ hooks: [h] }))?.command
  const state = ours.length === 0 ? 'installed' : (existingCmd !== cmd || ours[0]?.matcher !== GATE_MATCHER || ours.length > 1) ? 'updated' : 'unchanged'
  if (state === 'unchanged') return state
  settings.hooks[GATE_EVENT] = [...foreign, { matcher: GATE_MATCHER, hooks: [{ type: 'command', command: cmd, timeout: 5 }] }]
  try {
    mkdirSync(dirname(SETTINGS_PATH), { recursive: true })
    writeJsonAtomic(SETTINGS_PATH, settings)
    console.log(`[gate] ${state} Claude PreToolUse gate hook → ${SETTINGS_PATH} (takes effect on the next claude session start)`)
    return state
  } catch (err) {
    console.error('[gate] failed to write settings.json:', err)
    return 'failed'
  }
}

export function uninstallGateHook(): 'removed' | 'absent' | 'failed' {
  let settings: Settings = {}
  try { settings = JSON.parse(readFileSync(SETTINGS_PATH, 'utf-8')) as Settings } catch { return 'absent' }
  const blocks = Array.isArray(settings.hooks?.[GATE_EVENT]) ? settings.hooks![GATE_EVENT] : []
  const foreign = blocks.filter((b) => !isOurs(b))
  if (foreign.length === blocks.length) return 'absent'
  if (foreign.length) settings.hooks![GATE_EVENT] = foreign
  else delete settings.hooks![GATE_EVENT]
  try { writeJsonAtomic(SETTINGS_PATH, settings); return 'removed' } catch (err) { console.error('[gate] failed to write settings.json:', err); return 'failed' }
}

export function gateHookInstalled(): boolean {
  try {
    const settings = JSON.parse(readFileSync(SETTINGS_PATH, 'utf-8')) as Settings
    const blocks = Array.isArray(settings.hooks?.[GATE_EVENT]) ? settings.hooks![GATE_EVENT] : []
    return blocks.some(isOurs)
  } catch { return false }
}
