#!/usr/bin/env bun
/**
 * harness-blip-question.hook.ts (Claude Code Notification hook, and PostToolUse on AskUserQuestion)
 *
 * When an agent stops to ask Fred something, send the question to his own iMessage thread through
 * Blip (`imsg-send --self --yes`), prefixed with the machine name, so he sees it away from the desk.
 * Reply by hand with nixfred/bin/harness-blip-answer <pane> "<text>". Never blocks; exits 0 always.
 * Only runs when ~/.config/blip/bridge.conf exists (Blip bridge configured on this host).
 */
import { existsSync } from 'node:fs';
import { hostname } from 'node:os';
import { join } from 'node:path';

const MAX = 600;

function questionText(input: any): string {
  if (input?.hook_event_name === 'PostToolUse' || input?.tool_name === 'AskUserQuestion') {
    const qs = input?.tool_input?.questions;
    if (Array.isArray(qs)) {
      return qs.map((q: any) => {
        const opts = Array.isArray(q?.options) ? q.options.map((o: any) => o?.label).filter(Boolean).join(' / ') : '';
        return `${q?.question ?? ''}${opts ? ` [${opts}]` : ''}`;
      }).join('\n');
    }
  }
  return [input?.title, input?.message].filter(Boolean).join(': ');
}

async function main() {
  try {
    if (!existsSync(join(process.env.HOME || '', '.config', 'blip', 'bridge.conf'))) process.exit(0);
    const input = JSON.parse(await Bun.stdin.text() || '{}');
    const text = questionText(input).replace(/\s+/g, ' ').trim();
    if (!text) process.exit(0);
    const msg = `[harness ${hostname()}] ${text}`.slice(0, MAX);
    // argv, not stdin: --file-stdin payloads arrive empty over the ssh shim.
    const proc = Bun.spawn(['imsg-send', '--self', '--yes', msg], { stdout: 'ignore', stderr: 'pipe' });
    const timer = setTimeout(() => proc.kill(), 8000);
    await proc.exited;
    clearTimeout(timer);
  } catch (err) {
    console.error('[harness-blip-question]', err);
  }
  process.exit(0);
}

main();
