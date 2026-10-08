import type { HookContract } from '../facets/hooks.js'

/**
 * Claude Code's hooks, declared: data only, which core applies with the kit's installer and rules
 * (engines/hooks.ts). Copied from the former installHooks.ts and hooks.ts of this folder.
 */
export const hooks: HookContract = {
  settings: {
    // The person's own. A home the person moved (CLAUDE_CONFIG_DIR, lib/engineHomes.ts) gets the same block
    // in its own settings.json (core/engines/hooks.ts).
    home: { inHome: '.claude' },
    file: 'settings.json',
    // SessionStart/UserPromptSubmit bind mutable engine-session metadata to the process agent. SessionEnd
    // only asks discovery to reconcile: the process, not the hook, owns the tile lifetime. UserPromptSubmit
    // is the CATCH hook, so a SessionStart missed because the adapter started late is repaired on first input.
    // Stop/StopFailure are the authoritative turn-close signals (Stop = normal finish incl. max_tokens/
    // refusal; StopFailure = turn ended on an API error, where Stop does NOT fire) — they close a turn even
    // when the JSONL-derived turn_ended is missed. Neither supports a matcher (silently ignored).
    // Notification (nixfred watch mode, nixfred/orcaWatch.ts): says a permission or question dialog is open in
    // a session OUTSIDE tmux (a herdr pane, an Orca terminal), where there is no pane of ours to poll.
    // notify.mjs exits at once for it in a tmux pane, and posts nothing at all while watch mode is off.
    events: [{ event: 'SessionStart' }, { event: 'SessionEnd' }, { event: 'UserPromptSubmit' }, { event: 'Stop' }, { event: 'StopFailure' }, { event: 'Notification' }],
    timeout: 5,
    commandNamesHome: false,
    unreadable: 'replace',
    write: 'in-place',
    upToDate: { command: 'first-ours', matcher: false },
    messages: {
      current: '[hooks] Claude session + turn (Stop/StopFailure) hooks already installed',
      installed: '[hooks] installed Claude session + turn (Stop/StopFailure) hooks → {file}',
      updated: '[hooks] updated (path/port changed) → {script} --port {port} in {file}',
      after: '[hooks] (takes effect on the next claude session start)',
      failed: '[hooks] failed to write settings.json:',
    },
  },
  sessionFile: { suffix: '.jsonl' },
  stopClosesTurns: true,
}
