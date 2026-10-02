import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, describe, expect, it } from 'vitest'
import { DeviceLogStore, type DevLogFile } from './deviceLogStore.js'

const dirs: string[] = []
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }) })
const file = (): string => {
  const dir = mkdtempSync(join(tmpdir(), 'harness-devlog-store-'))
  dirs.push(dir)
  return join(dir, 'devlog.json')
}

const state = { acct: 'acct', head: { seq: 1, hash: 'h' }, hashes: ['h'], active: {}, removed: [] }

describe('DeviceLogStore — firstSeen across versions', () => {
  it('reads a devlog.json written before firstSeen existed, with nothing marked as first seen', () => {
    const path = file()
    writeFileSync(path, JSON.stringify({ state, recent: [], frozen: null, notifiedUpTo: 1 }))
    const read = new DeviceLogStore(path).read()
    expect(read.state).toEqual(state)
    expect(read.notifiedUpTo).toBe(1)
    expect(read.firstSeen).toBeUndefined()
  })

  it('keeps firstSeen through a write and a read', () => {
    const path = file()
    const store = new DeviceLogStore(path)
    const next: DevLogFile = { state: state as DevLogFile['state'], recent: [], frozen: null, notifiedUpTo: 1, firstSeen: { a: 5 } }
    store.write(next)
    expect(store.read().firstSeen).toEqual({ a: 5 })
    // The other fields an older CLI reads are where they always were.
    expect(JSON.parse(readFileSync(path, 'utf-8'))).toMatchObject({ state, recent: [], frozen: null, notifiedUpTo: 1 })
  })

  it('drops a firstSeen that is not an object rather than failing the whole read', () => {
    const path = file()
    writeFileSync(path, JSON.stringify({ state, recent: [], frozen: null, notifiedUpTo: 1, firstSeen: 'junk' }))
    const read = new DeviceLogStore(path).read()
    expect(read.state).toEqual(state)
    expect(read.firstSeen).toBeUndefined()
  })
})
