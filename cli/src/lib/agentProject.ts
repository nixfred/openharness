import { execFile } from 'node:child_process'
import { readFile, realpath, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, dirname, isAbsolute, join, resolve } from 'node:path'
import { promisify } from 'node:util'

const exec = promisify(execFile)
export type AgentProject = {
  name: string
  cwd: string
  root: string | null
  remote: string | null
  branch: string | null
  /** Inside a linked worktree rather than the repository's own checkout. */
  worktree?: true
  /** The branch still has the name Harness made up at Start; the session's replaces it. */
  branchPending?: true
}

/** Compare remote repositories without publishing embedded credentials or transport syntax. */
export function canonicalRepository(raw: string | null): string | null {
  if (!raw) return null
  const scp = /^(?:[^@/\s]+@)?([^:/\s]+):([^\s]+)$/.exec(raw)
  try {
    const url = new URL(scp && !raw.includes('://') ? `ssh://${scp[1]}/${scp[2]}` : raw)
    if (!['ssh:', 'https:', 'http:', 'git:'].includes(url.protocol) || !url.hostname) return null
    let path = url.pathname.replace(/^\/+|\/+$/g, '').replace(/\.git$/i, '')
    if (!path || /[\x00-\x20]/.test(path)) return null
    const host = url.hostname.toLowerCase()
    if (host === 'github.com' || host === 'bitbucket.org') path = path.toLowerCase()
    const defaultPort = url.protocol === 'ssh:' ? '22' : url.protocol === 'git:' ? '9418' : ''
    const port = url.port === defaultPort ? '' : url.port
    return `${host}${port ? `:${port}` : ''}/${path}`
  } catch { return null }
}

/** Bounded subprocesses, no shell, network, or repository mutation. */
async function git(cwd: string, args: string[]): Promise<string | null> {
  try {
    const environment = { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' }
    for (const key of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_NAMESPACE', 'GIT_PREFIX']) delete (environment as NodeJS.ProcessEnv)[key]
    const { stdout } = await exec('git', ['-C', cwd, ...args], {
      timeout: 1500, maxBuffer: 16 * 1024, encoding: 'utf8',
      env: environment,
    })
    return stdout.trim() || null
  } catch { return null }
}

// Only four folders run Git at once, including cache refreshes.
let running = 0
const waiting: Array<() => void> = []
async function inspect(cwd: string): Promise<AgentProject> {
  if (running >= 4) await new Promise<void>(resolve => waiting.push(resolve))
  else running++
  try {
    const root = await git(cwd, ['rev-parse', '--show-toplevel'])
    if (!root) return { name: basename(cwd) || cwd, cwd, root: null, remote: null, branch: null }
    const remote = await git(cwd, ['config', '--get', 'remote.origin.url'])
    // A checkout on no branch still says where it is, as the desktop's own reader does.
    const branch = await git(cwd, ['symbolic-ref', '--quiet', '--short', 'HEAD'])
      ?? await git(cwd, ['rev-parse', '--short', 'HEAD']).then(sha => sha && `Detached ${sha}`)
    const common = await git(root, ['rev-parse', '--git-common-dir'])
    // A linked worktree is named for its repository, not its folder.
    const main = common && basename(common) === '.git' ? dirname(resolve(root, common)) : root
    const pending = branch && !branch.startsWith('Detached ')
      ? await git(cwd, ['config', '--get', `branch.${branch}.harness`]) === 'placeholder'
      : false
    return {
      name: basename(main), cwd, root, remote: canonicalRepository(remote), branch,
      ...(main !== root ? { worktree: true as const } : {}), ...(pending ? { branchPending: true as const } : {}),
    }
  } finally {
    const next = waiting.shift()
    if (next) next()
    else running--
  }
}

/** Cheap freshness check for known Git metadata, including linked worktrees and
 * nested repositories created under a previously inspected directory. Git still
 * resolves all values; these stamps only avoid repeating it when nothing moved.
 * Untracked config includes are covered by the bounded full-refresh interval. */
async function metadataStamp(cwd: string, project: AgentProject): Promise<string | null> {
  try {
    if (project.root && !project.branch) return null
    const physical = await realpath(cwd)
    const directory = await stat(physical)
    if (!directory.isDirectory()) return null
    const paths = new Set<string>()
    for (let path = physical, depth = 0; depth < 128; depth++) {
      paths.add(join(path, '.git'))
      if (path === project.root || dirname(path) === path) break
      path = dirname(path)
    }
    const smallFile = async (path: string): Promise<string | null> => {
      paths.add(path)
      const info = await stat(path).catch(error => {
        if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return null
        throw error
      })
      if (!info) return null
      if (!info.isFile() || info.size > 16 * 1024) throw new Error('Uncacheable Git metadata')
      return (await readFile(path, 'utf8')).trim()
    }
    if (project.root) {
      const marker = join(project.root, '.git')
      const info = await stat(marker)
      let gitDir = marker
      if (!info.isDirectory()) {
        const markerText = await smallFile(marker)
        if (!markerText?.startsWith('gitdir: ')) return null
        gitDir = resolve(project.root, markerText.slice(8))
      }
      paths.add(join(gitDir, 'HEAD'))
      paths.add(join(gitDir, 'config'))
      paths.add(join(gitDir, 'config.worktree'))
      const common = await smallFile(join(gitDir, 'commondir'))
      if (common) paths.add(join(resolve(gitDir, common), 'config'))
    }
    paths.add(process.env.GIT_CONFIG_GLOBAL || join(homedir(), '.gitconfig'))
    paths.add(join(process.env.XDG_CONFIG_HOME || join(homedir(), '.config'), 'git', 'config'))
    paths.add(process.env.GIT_CONFIG_SYSTEM || '/etc/gitconfig')
    const stamps = await Promise.all([...paths].map(async path => {
      const info = await stat(path).catch(error => {
        if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return null
        throw error
      })
      // Index/lock activity changes the .git directory's mtime without changing
      // this projection. Its identity, HEAD and config are the relevant inputs.
      return [path, !info ? null : info.isDirectory()
        ? [info.dev, info.ino, 'directory']
        : [info.dev, info.ino, info.size, info.mtimeMs, info.ctimeMs]]
    }))
    // A visible .git marker with no resolved repository can mean an unavailable
    // checkout or a failed Git process, not a stable non-repository folder.
    if (!project.root && stamps.some(([path, stamp]) => typeof path === 'string' && path.endsWith('/.git') && stamp !== null)) return null
    return JSON.stringify([physical, directory.dev, directory.ino, stamps])
  } catch { return null }
}

export function createAgentProjectReader(lookup: (cwd: string) => Promise<AgentProject> = inspect) {
  type Entry = { at: number; gitAt: number; pending: boolean; stamp: string | null; value: Promise<AgentProject> }
  const cache = new Map<string, Entry>()
  const trim = () => {
    // Pending work must survive both expiry and eviction, otherwise a slow
    // queue creates duplicate Git subprocesses for the same directory.
    for (const [key, entry] of cache) {
      if (cache.size <= 1024) break
      if (!entry.pending) cache.delete(key)
    }
  }
  const read = (cwd: string | null, now = Date.now()): Promise<AgentProject | null> => {
    if (!cwd || !isAbsolute(cwd) || cwd.length > 4096 || /[\x00-\x1f\x7f]/.test(cwd)) return Promise.resolve(null)
    const found = cache.get(cwd)
    if (found && (found.pending || now - found.at < 15_000)) {
      cache.delete(cwd)
      cache.set(cwd, found)
      return found.value
    }
    const started = Date.now()
    const entry: Entry = { at: now, gitAt: found?.gitAt ?? now, pending: true, stamp: null, value: null! }
    entry.value = (async () => {
      const previous = found ? await found.value : null
      const before = previous ? await metadataStamp(cwd, previous) : null
      if (found?.stamp && before === found.stamp && now - found.gitAt < 60_000) {
        entry.stamp = before
        return previous!
      }
      const value = await lookup(cwd)
      const after = await metadataStamp(cwd, value)
      // Only reuse a snapshot if its inputs stayed stable across the Git read.
      // A first lookup has no resolved Git directory yet and warms this on the
      // next refresh; a checkout racing a lookup never becomes a cached fact.
      entry.stamp = before && before === after ? after : null
      entry.gitAt = now + Math.max(0, Date.now() - started)
      return value
    })().finally(() => {
      entry.pending = false
      entry.at = now + Math.max(0, Date.now() - started)
      trim()
    })
    cache.delete(cwd)
    cache.set(cwd, entry)
    trim()
    return entry.value
  }
  return { read, forget: (cwd: string) => { cache.delete(cwd) } }
}

// Agent lists and push frames share this reader. Branch changes still become
// visible within 15 seconds; unchanged historical paths do not fork Git again.
const projects = createAgentProjectReader()
export const agentProject = projects.read
/** Forget what was read for `cwd`, as after renaming its branch. */
export const forgetAgentProject = projects.forget
