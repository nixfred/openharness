import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { adoptPane, forgetPane, isAdoptedPane, loadAdoptedPanes, resetAdoptedPanesCache } from './adoptedPanes.js'

describe('adoptedPanes', () => {
  let dir: string
  let file: string
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'adopted-')); file = join(dir, 'adopted-panes.json'); resetAdoptedPanesCache() })
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); resetAdoptedPanesCache() })

  it('starts empty when the file is missing', () => {
    expect(loadAdoptedPanes(file)).toEqual([])
    expect(isAdoptedPane('%1', 'work', file)).toBe(false)
  })

  it('adopts a pane under its session name, persists atomically, and matches only that pairing', () => {
    const row = adoptPane({ pane: '%12', sessionName: 'larry', engine: 'claude' }, 1000, file)
    expect(row).toEqual({ pane: '%12', sessionName: 'larry', engine: 'claude', adoptedAt: 1000 })
    expect(isAdoptedPane('%12', 'larry', file)).toBe(true)
    expect(isAdoptedPane('%12', 'other', file)).toBe(false) // pane id reused by a new tmux server
    expect(JSON.parse(readFileSync(file, 'utf8'))).toHaveLength(1)
  })

  it('re-adopting the same pane replaces the row; forgetting removes it', () => {
    adoptPane({ pane: '%3', sessionName: 'a', engine: null }, 1, file)
    adoptPane({ pane: '%3', sessionName: 'b', engine: 'codex' }, 2, file)
    expect(loadAdoptedPanes(file)).toEqual([{ pane: '%3', sessionName: 'b', engine: 'codex', adoptedAt: 2 }])
    expect(forgetPane('%3', file)).toBe(true)
    expect(forgetPane('%3', file)).toBe(false)
    expect(loadAdoptedPanes(file)).toEqual([])
  })

  it('ignores a corrupt file instead of throwing', () => {
    adoptPane({ pane: '%1', sessionName: 's', engine: null }, 1, file)
    resetAdoptedPanesCache()
    require('node:fs').writeFileSync(file, '{not json')
    expect(loadAdoptedPanes(file)).toEqual([])
  })
})
