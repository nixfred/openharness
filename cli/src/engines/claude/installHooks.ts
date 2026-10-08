import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { homedir } from 'node:os'
import { command, HOOK_SCRIPT, isOurs, writeJsonAtomic, type Settings } from '../kit/notifyHooks.js'

const SETTINGS_PATH = join(homedir(), '.claude', 'settings.json')

// SessionStart/UserPromptSubmit bind mutable engine-session metadata to the process agent. SessionEnd
// only asks discovery to reconcile: the process, not the hook, owns the tile lifetime. UserPromptSubmit
// is the CATCH hook, so a SessionStart missed because the adapter started late is repaired on first input.
// Stop/StopFailure are the authoritative turn-close signals (Stop = normal finish incl. max_tokens/
// refusal; StopFailure = turn ended on an API error, where Stop does NOT fire) — they close a turn even
// when the JSONL-derived turn_ended is missed. Neither supports a matcher (silently ignored).
// Notification (nixfred watch mode, nixfred/orcaWatch.ts): says a permission or question dialog is open in
// a session OUTSIDE tmux, where there is no pane to poll. notify.mjs exits at once for it in a tmux pane,
// and posts nothing at all while watch mode is off.
const EVENTS = ['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'Stop', 'StopFailure', 'Notification'] as const

/** `settingsPath`: another Claude Code home's settings, for a home the person moved (lib/engineHomes.ts). */
export function installSessionHooks(port: number, settingsPath: string = SETTINGS_PATH): void {
  let settings: Settings = {}
  try {
    settings = JSON.parse(readFileSync(settingsPath, 'utf-8')) as Settings
  } catch {
    // missing / unreadable → start from empty settings
  }

  if (!settings.hooks || typeof settings.hooks !== 'object') settings.hooks = {}
  const cmd = command(port, 'claude')
  let changed = false
  let updated = false // true when an EXISTING block's command changed (path/port drift)

  for (const event of EVENTS) {
    const blocks = Array.isArray(settings.hooks[event]) ? settings.hooks[event] : []
    // Collapse any duplicate "ours" blocks (e.g. from an earlier path) down to a single one, and
    // keep every non-ours block untouched.
    const foreign = blocks.filter((b) => !isOurs(b))
    const oursBlocks = blocks.filter(isOurs)
    if (oursBlocks.length > 1) changed = true // dropping duplicates is a change

    // The one canonical block for this event with the CURRENT command (path + port). If a prior
    // block existed with a different command (moved checkout / dev↔dist / changed port), this
    // overwrites it in place.
    const existingCmd = oursBlocks[0]?.hooks?.find((h) => isOurs({ hooks: [h] }))?.command
    if (oursBlocks.length === 0) changed = true
    else if (existingCmd !== cmd) { changed = true; updated = true }

    settings.hooks[event] = [...foreign, { hooks: [{ type: 'command', command: cmd, timeout: 5 }] }]
  }

  if (!changed) {
    console.log('[hooks] Claude session + turn (Stop/StopFailure) hooks already installed')
    return
  }

  try {
    mkdirSync(dirname(settingsPath), { recursive: true })
    writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n')
    // Both name the file written: a daemon can write several (every moved home gets its own), and the
    // end-to-end harness checks each one it names is inside its throwaway root.
    console.log(
      updated
        ? `[hooks] updated (path/port changed) → ${HOOK_SCRIPT} --port ${port} in ${settingsPath}`
        : `[hooks] installed Claude session + turn (Stop/StopFailure) hooks → ${settingsPath}`,
    )
    console.log('[hooks] (takes effect on the next claude session start)')
  } catch (err) {
    console.error('[hooks] failed to write settings.json:', err)
  }
}

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
