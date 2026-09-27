import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { env } from '../config/env.js'

/**
 * tmux panes the person asked the daemon to treat as agents even though `agent_create` never made them
 * (`harness adopt %12`). Discovery whitelists sessions named `harness-*`; this is the second, explicit
 * whitelist. A pane id is only meaningful for one tmux server lifetime, so each entry also records the
 * session name it was adopted under and is dropped when both stop matching.
 */
export interface AdoptedPane { pane: string; sessionName: string; engine: string | null; adoptedAt: number }

const FILE = () => join(env.ADAPTER_DATA_DIR, 'adopted-panes.json')

let cache: AdoptedPane[] | null = null

export function loadAdoptedPanes(file = FILE()): AdoptedPane[] {
  if (cache) return cache
  try {
    const raw = JSON.parse(readFileSync(file, 'utf8')) as unknown
    cache = Array.isArray(raw) ? raw.filter((r): r is AdoptedPane => !!r && typeof (r as AdoptedPane).pane === 'string') : []
  } catch { cache = [] }
  return cache
}

function save(list: AdoptedPane[], file = FILE()): void {
  cache = list
  mkdirSync(dirname(file), { recursive: true })
  const tmp = `${file}.${process.pid}.tmp`
  writeFileSync(tmp, JSON.stringify(list, null, 2) + '\n')
  renameSync(tmp, file)
}

export function adoptPane(entry: Omit<AdoptedPane, 'adoptedAt'>, now = Date.now(), file = FILE()): AdoptedPane {
  const list = loadAdoptedPanes(file).filter((p) => p.pane !== entry.pane)
  const row = { ...entry, adoptedAt: now }
  save([...list, row], file)
  return row
}

export function forgetPane(pane: string, file = FILE()): boolean {
  const list = loadAdoptedPanes(file)
  const next = list.filter((p) => p.pane !== pane)
  if (next.length === list.length) return false
  save(next, file)
  return true
}

/** Whether discovery should keep this pane: adopted by id, and still in the session it was adopted under. */
export function isAdoptedPane(pane: string, sessionName: string, file = FILE()): boolean {
  return loadAdoptedPanes(file).some((p) => p.pane === pane && p.sessionName === sessionName)
}

export function resetAdoptedPanesCache(): void { cache = null }

export function adoptedPanesFileExists(file = FILE()): boolean { return existsSync(file) }
