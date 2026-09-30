import { execFileSync } from 'node:child_process'
import { mkdtemp, mkdir, rm, realpath, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { agentProject, canonicalRepository, createAgentProjectReader, type AgentProject } from './agentProject.js'

const roots: string[] = []
afterEach(async () => { await Promise.all(roots.splice(0).map(path => rm(path, { recursive: true, force: true }))) })
describe('owning-machine project metadata', () => {
  it('canonicalizes transports and strips credentials and URL tokens', () => {
    expect(canonicalRepository('git@github.com:Org/App.git')).toBe('github.com/org/app')
    expect(canonicalRepository('https://user:secret@github.com/Org/App.git?token=secret')).toBe('github.com/org/app')
    expect(canonicalRepository('ssh://git@github.com:22/Org/App.git')).toBe('github.com/org/app')
    expect(canonicalRepository('ssh://git@example.com:2222/Org/App.git')).toBe('example.com:2222/Org/App')
    expect(canonicalRepository('/private/checkouts/app')).toBeNull()
    expect(canonicalRepository('file:///private/checkouts/app')).toBeNull()
    expect(canonicalRepository('ssh://git@example.com/CaseSensitive.git')).toBe('example.com/CaseSensitive')
  })
  it('reads the current checkout and branch, including branch changes after cache expiry', async () => {
    const root = await mkdtemp(join(tmpdir(), 'harness-v2-project-')); roots.push(root)
    const git = (...args: string[]) => execFileSync('git', ['-C', root, ...args], { stdio: 'pipe' })
    git('init', '-b', 'main')
    git('remote', 'add', 'origin', 'git@github.com:Org/App.git')
    await mkdir(join(root, 'nested'))
    const cwd = join(root, 'nested')
    expect(await agentProject(cwd, 100)).toMatchObject({ cwd, root: await realpath(root), remote: 'github.com/org/app', branch: 'main' })
    git('symbolic-ref', 'HEAD', 'refs/heads/feature/real-branch')
    expect(await agentProject(cwd, 20_000)).toMatchObject({ branch: 'feature/real-branch' })
    expect(await agentProject(cwd, 40_000)).toMatchObject({ branch: 'feature/real-branch' })
    git('remote', 'set-url', 'origin', 'git@github.com:Org/Other.git')
    git('symbolic-ref', 'HEAD', 'refs/heads/next')
    expect(await agentProject(cwd, 60_000)).toMatchObject({ remote: 'github.com/org/other', branch: 'next' })
  })
  it('names a linked worktree for its repository rather than its folder', async () => {
    const root = await mkdtemp(join(tmpdir(), 'harness-v2-worktree-')); roots.push(root)
    const repo = join(root, 'app')
    const git = (...args: string[]) => execFileSync('git', ['-C', repo, ...args], { stdio: 'pipe' })
    await mkdir(repo)
    git('init', '-b', 'main')
    git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty', '-m', 'initial')
    const linked = join(root, 'worktrees', 'app', 'claude-0922-1136')
    git('worktree', 'add', '-b', 'harness/claude-0922-1136', linked)
    expect(await agentProject(linked)).toMatchObject({ name: 'app', root: await realpath(linked), branch: 'harness/claude-0922-1136', worktree: true })
    expect(await agentProject(repo)).toMatchObject({ name: 'app', branch: 'main' })
    expect(await agentProject(repo)).not.toHaveProperty('worktree')
    expect(await agentProject(linked)).not.toHaveProperty('branchPending')
    git('config', 'branch.harness/claude-0922-1136.harness', 'placeholder')
    expect(await agentProject(linked, Date.now() + 20_000)).toMatchObject({ branchPending: true })
    git('checkout', '--quiet', '--detach')
    expect((await agentProject(repo, Date.now() + 20_000))?.branch).toMatch(/^Detached [0-9a-f]{7,}$/)
  })
  it('keeps a non-repository project branchless and rejects absent cwd', async () => {
    const root = await mkdtemp(join(tmpdir(), 'harness-v2-folder-')); roots.push(root)
    expect(await agentProject(root)).toMatchObject({ cwd: root, root: null, remote: null, branch: null })
    expect(await agentProject(null)).toBeNull()
    expect(await agentProject('relative')).toBeNull()
    expect(await agentProject('/tmp/unsafe\n')).toBeNull()
  })

  it('checks metadata without running Git again for unchanged historical folders', async () => {
    const root = await mkdtemp(join(tmpdir(), 'harness-v2-project-cache-')); roots.push(root)
    let calls = 0
    const reader = createAgentProjectReader(async cwd => {
      calls++
      return { name: 'folder', cwd, root: null, remote: null, branch: null }
    })
    await reader.read(root, 0)
    await reader.read(root, 20_000) // establish stable inputs across a lookup
    const stable = await reader.read(root, 40_000)
    expect(calls).toBe(2)
    expect(await reader.read(root, 60_000)).toBe(stable)
    expect(calls).toBe(2)
    await reader.read(root, 90_000) // included config files get a bounded full refresh
    expect(calls).toBe(3)
    reader.forget(root)
    await reader.read(root, 90_001)
    expect(calls).toBe(4)
  })

  it('does not extend reuse across a nested repository appearing or a racing checkout', async () => {
    const root = await mkdtemp(join(tmpdir(), 'harness-v2-project-race-')); roots.push(root)
    const cwd = join(root, 'nested'); await mkdir(cwd)
    const marker = join(cwd, '.git')
    let calls = 0
    const reader = createAgentProjectReader(async path => {
      calls++
      if (calls >= 3) {
        await writeFile(join(marker, 'HEAD'), `ref: refs/heads/branch-${calls}\n`)
        return { name: 'nested', cwd: path, root: cwd, remote: null, branch: `branch-${calls - 1}` }
      }
      return { name: 'folder', cwd: path, root: null, remote: null, branch: null }
    })
    await reader.read(cwd, 0)
    await reader.read(cwd, 20_000)
    await reader.read(cwd, 40_000)
    expect(calls).toBe(2)
    await mkdir(marker)
    await writeFile(join(marker, 'HEAD'), 'ref: refs/heads/branch-2\n')
    await reader.read(cwd, 60_000)
    expect(calls).toBe(3)
    await reader.read(cwd, 80_000)
    await reader.read(cwd, 100_000)
    expect(calls).toBe(5) // each lookup changed HEAD; none can become a stable cached fact
  })

  it('shares queued work past TTL and cache capacity instead of duplicating subprocesses', async () => {
    let finish!: () => void
    const gate = new Promise<void>(resolve => { finish = resolve })
    let calls = 0
    const reader = createAgentProjectReader(async cwd => {
      calls++
      await gate
      return { name: 'folder', cwd, root: null, remote: null, branch: null } satisfies AgentProject
    })
    const first = reader.read('/missing/harness-project-0', 0)
    const rest = Array.from({ length: 1050 }, (_, i) => reader.read(`/missing/harness-project-${i + 1}`, 0))
    expect(reader.read('/missing/harness-project-0', 90_000)).toBe(first)
    expect(calls).toBe(1051)
    finish()
    await Promise.all([first, ...rest])
  })
})
