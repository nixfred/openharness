import { describe, expect, it } from 'vitest'
import { AUDIT_ROTATE_BYTES, AuditJournal, type AuditFs } from './auditJournal.js'

function memFs(): AuditFs & { files: Map<string, string>; dirs: Set<string> } {
  const files = new Map<string, string>()
  const dirs = new Set<string>()
  return {
    files, dirs,
    appendFile: async (p, d) => { files.set(p, (files.get(p) ?? '') + d) },
    readFile: async (p) => { const v = files.get(p); if (v === undefined) throw new Error('ENOENT'); return v },
    stat: async (p) => ({ size: Buffer.byteLength(files.get(p) ?? '') }),
    rename: async (a, b) => { files.set(b, files.get(a)!); files.delete(a) },
    unlink: async (p) => { files.delete(p) },
    mkdir: async (p) => { dirs.add(p) },
    exists: async (p) => files.has(p) || dirs.has(p),
  }
}

const entry = (i: number) => ({ at: i, machine: 'gus', agentId: 'a1', kind: 'command' as const, name: `cmd ${i}`, detail: `token=${'b'.repeat(44)} run ${i}` })

describe('AuditJournal', () => {
  it('appends redacted JSON lines and tails them', async () => {
    const fs = memFs()
    const j = new AuditJournal(fs, '/data')
    await j.append(entry(1))
    await j.append(entry(2))
    const lines = fs.files.get('/data/audit.jsonl')!.trim().split('\n')
    expect(lines).toHaveLength(2)
    expect(JSON.parse(lines[0]!).detail).toBe('token=[REDACTED] run 1')
    expect(fs.dirs.has('/data')).toBe(true)
    expect((await j.tail(1))[0]!.name).toBe('cmd 2')
  })

  it('keeps concurrent appends in call order even when the first one is slow to reach the disk', async () => {
    const fs = memFs()
    let first = true
    const stat = fs.stat
    fs.stat = async (p) => { if (first) { first = false; await new Promise((r) => setTimeout(r, 20)) } return stat(p) }
    fs.files.set('/data/audit.jsonl', '')
    const j = new AuditJournal(fs, '/data')
    await Promise.all([j.append(entry(1)), j.append(entry(2)), j.append(entry(3))])
    expect(fs.files.get('/data/audit.jsonl')!.trim().split('\n').map((l) => (JSON.parse(l) as { at: number }).at)).toEqual([1, 2, 3])
  })

  it('searches newest first with a limit', async () => {
    const fs = memFs()
    const j = new AuditJournal(fs, '/data')
    for (let i = 1; i <= 5; i++) await j.append({ ...entry(i), kind: i % 2 ? 'tool' : 'turn' })
    const hits = await j.search((e) => e.kind === 'tool', 2)
    expect(hits.map((e) => e.at)).toEqual([5, 3])
  })

  it('rotates at the size limit and keeps five generations', async () => {
    const fs = memFs()
    const j = new AuditJournal(fs, '/data')
    for (let g = 1; g <= 7; g++) {
      fs.files.set('/data/audit.jsonl', 'x'.repeat(AUDIT_ROTATE_BYTES))
      await j.append(entry(g))
    }
    expect([...fs.files.keys()].sort()).toEqual(['/data/audit.1.jsonl', '/data/audit.2.jsonl', '/data/audit.3.jsonl', '/data/audit.4.jsonl', '/data/audit.5.jsonl', '/data/audit.jsonl'])
    expect(fs.files.get('/data/audit.jsonl')).toContain('"cmd 7"')
  })

  it('skips a torn trailing line', async () => {
    const fs = memFs()
    fs.files.set('/data/audit.jsonl', JSON.stringify(entry(1)) + '\n{"at":2,"mach')
    const j = new AuditJournal(fs, '/data')
    expect((await j.tail(5)).map((e) => e.at)).toEqual([1])
  })
})
