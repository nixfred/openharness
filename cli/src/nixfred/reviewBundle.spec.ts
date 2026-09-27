import { createHash } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import { buildReviewBundle, type BundleDeps } from './reviewBundle.js'

function fake(initial: Record<string, string>, git: Record<string, string> = {}) {
  const files = new Map(Object.entries(initial))
  const calls: string[][] = []
  const deps: BundleDeps = {
    exec: async (cmd, args) => {
      calls.push([cmd, ...args])
      if (cmd === 'tar') return ''
      const key = args.slice(2).join(' ')
      if (key in git) return git[key]!
      throw new Error('no git')
    },
    writeFile: async (p, d) => { files.set(p, d) },
    readFile: async (p) => { const v = files.get(p); if (v === undefined) throw new Error('ENOENT'); return v },
    mkdir: async () => {},
    now: () => 1_700_000_000_000,
    machine: 'gus',
  }
  return { deps, files, calls }
}

describe('buildReviewBundle', () => {
  it('collects patch, diffstat, redacted transcript and audit tail, then tars with a manifest', async () => {
    const transcript = Array.from({ length: 250 }, (_, i) => `line ${i} token=${'c'.repeat(44)}`).join('\n')
    const { deps, files, calls } = fake({ '/t.jsonl': transcript, '/a.jsonl': 'a1\na2\n' }, { 'diff --binary HEAD': '+++ b/x\n', 'diff --stat HEAD': ' x | 1 +\n' })
    const r = await buildReviewBundle(deps, { agentId: 'a1', cwd: '/repo', brief: 'Fix rings', transcriptPath: '/t.jsonl', auditPath: '/a.jsonl', outDir: '/out' })
    expect(r.dir).toBe('/out/review-a1-1700000000000')
    expect(r.tarball).toBe('/out/review-a1-1700000000000.tar.gz')
    expect(files.get(`${r.dir}/README.md`)).toContain('## Brief\nFix rings')
    const t = files.get(`${r.dir}/transcript.txt`)!
    expect(t.split('\n')).toHaveLength(200)
    expect(t).not.toContain('cccccccc')
    expect(r.manifest.redactions).toBe(200)
    expect(Object.keys(r.manifest.files).sort()).toEqual(['README.md', 'audit.jsonl', 'diffstat.txt', 'patch.diff', 'transcript.txt'])
    expect(r.manifest.files['patch.diff']!.sha256).toBe(createHash('sha256').update('+++ b/x\n').digest('hex'))
    expect(calls.at(-1)).toEqual(['tar', 'czf', r.tarball, '-C', '/out', 'review-a1-1700000000000'])
    expect(JSON.parse(files.get(`${r.dir}/manifest.json`)!).machine).toBe('gus')
  })

  it('refuses .ssh/.env sources and private-key content, and records the exclusion', async () => {
    const { deps, files } = fake({ '/home/pi/.ssh/id_ed25519': 'x', '/repo/.env': 'A=1', '/k.txt': '-----BEGIN OPENSSH PRIVATE KEY-----\nabc' })
    const r = await buildReviewBundle(deps, { agentId: 'a1', cwd: '/repo', transcriptPath: '/home/pi/.ssh/id_ed25519', auditPath: '/k.txt', outDir: '/out' })
    expect(files.has(`${r.dir}/transcript.txt`)).toBe(false)
    expect(files.has(`${r.dir}/audit.jsonl`)).toBe(false)
    expect(r.manifest.excluded).toEqual(['/home/pi/.ssh/id_ed25519', '/k.txt'])
    expect(files.get(`${r.dir}/README.md`)).toContain('(no brief recorded)')
  })

  it('falls back to the checkpoint brief and patch when the tree is clean', async () => {
    const cp = { version: 1, agentId: 'a1', machine: 'vic', at: 5, cwd: '/repo', brief: 'From checkpoint', decisions: ['d1'], git: { head: 'abcdef123456789', branch: 'b', status: '' }, patchFile: '/cp/p.patch' }
    const { deps, files } = fake({ '/cp/checkpoint.json': JSON.stringify(cp), '/cp/p.patch': 'PATCH' })
    const r = await buildReviewBundle(deps, { agentId: 'a1', cwd: '/repo', checkpointPath: '/cp/checkpoint.json', outDir: '/out' })
    expect(files.get(`${r.dir}/README.md`)).toContain('From checkpoint')
    expect(files.get(`${r.dir}/README.md`)).toContain('- d1')
    expect(files.get(`${r.dir}/patch.diff`)).toBe('PATCH')
  })
})
