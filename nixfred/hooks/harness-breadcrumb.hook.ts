#!/usr/bin/env bun
/**
 * harness-breadcrumb.hook.ts (Claude Code Stop hook)
 *
 * Writes one small markdown note per finished turn under
 * ~/.claude/MEMORY/BREADCRUMBS/YYYY-MM-DD/HHMMSS-<repo>.md so `git log --grep`, `rg` and
 * `mem search` can find what an agent did, when, where, on which machine. Never blocks.
 */
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { hostname } from 'node:os';
import { basename, join } from 'node:path';

function lastAssistantLine(transcriptPath: string): string {
  try {
    const lines = readFileSync(transcriptPath, 'utf8').trim().split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      const row = JSON.parse(lines[i]);
      const msg = row?.message ?? row;
      if (msg?.role !== 'assistant') continue;
      const parts = Array.isArray(msg.content) ? msg.content : [{ type: 'text', text: String(msg.content ?? '') }];
      const text = parts.filter((p: any) => p?.type === 'text').map((p: any) => p.text).join(' ').replace(/\s+/g, ' ').trim();
      if (text) return text.slice(0, 200);
    }
  } catch { /* unreadable transcript: still leave a breadcrumb */ }
  return '(no assistant text captured)';
}

async function main() {
  try {
    const input = JSON.parse(await Bun.stdin.text() || '{}');
    const cwd: string = input.cwd || process.cwd();
    const repo = basename(cwd) || 'unknown';
    const now = new Date();
    const day = now.toISOString().slice(0, 10);
    const hms = now.toTimeString().slice(0, 8).replace(/:/g, '');
    const dir = join(process.env.HOME || '', '.claude', 'MEMORY', 'BREADCRUMBS', day);
    mkdirSync(dir, { recursive: true });
    const what = input.transcript_path ? lastAssistantLine(input.transcript_path) : '(no transcript path)';
    const tags = repo.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
    const body = [
      '---', `what: ${JSON.stringify(what)}`, `repo: ${repo}`, `machine: ${hostname()}`, 'engine: claude',
      `cwd: ${cwd}`, `session_id: ${input.session_id ?? ''}`, `tags: [${tags.join(', ')}]`, `at: ${now.toISOString()}`, '---', '',
      `${what}`, '',
    ].join('\n');
    writeFileSync(join(dir, `${hms}-${repo}.md`), body);
    const index = join(dir, 'INDEX.md');
    if (!existsSync(index)) writeFileSync(index, `# Breadcrumbs ${day}\n\n`);
    appendFileSync(index, `- ${hms} ${repo} @${hostname()}: ${what.slice(0, 120)}\n`);
  } catch (err) {
    console.error('[harness-breadcrumb]', err);
  }
  process.exit(0);
}

main();
