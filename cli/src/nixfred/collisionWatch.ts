/**
 * The drift alarm. "Agents drift quietly towards grabbing things solo": two agents editing the same
 * file, the same folder, or working the same branch inside an hour is the moment a person wants to
 * be told, not the moment the merge conflict lands. Pure: the daemon feeds tool calls and branch
 * observations, and reads back alerts. A lock store lets a person (or an agent) claim a branch so the
 * alarm fires the instant someone else touches it.
 */
export type CollisionKind = 'file' | 'folder' | 'branch' | 'lock'

export interface Touch { agentId: string; agentName: string; at: number }

export interface CollisionEvent {
  kind: CollisionKind
  key: string
  at: number
  agents: Array<{ agentId: string; agentName: string }>
  detail: string
}

export interface BranchLock { key: string; repo: string; branch: string; holderAgentId: string; holderName: string; machineId: string; at: number }

export interface CollisionWatcherOptions {
  windowMs?: number
  now?: () => number
  /** Folders under which a shared touch is not a collision (node_modules, dist, caches). */
  ignore?: RegExp
}

const DEFAULT_IGNORE = /(^|\/)(node_modules|dist|build|\.git|\.cache|target|\.next|coverage)(\/|$)/

const ABS_PATH_RE = /(?:^|\s|=|["'`])(\/(?:[\w.@-]+\/)+[\w.@-]+)/g

/** Paths a tool call is about: file_path fields for edit tools, absolute paths inside Bash commands. */
export function pathsFromToolInput(toolName: string, input: unknown, cwd?: string): string[] {
  if (!input || typeof input !== 'object') return []
  const o = input as Record<string, unknown>
  const out = new Set<string>()
  for (const k of ['file_path', 'path', 'notebook_path']) if (typeof o[k] === 'string' && (o[k] as string).startsWith('/')) out.add(o[k] as string)
  if (toolName === 'Bash' && typeof o.command === 'string') {
    for (const m of (o.command as string).matchAll(ABS_PATH_RE)) out.add(m[1]!)
    // A Bash call with no absolute path still lands somewhere: its working folder.
    if (out.size === 0 && cwd) out.add(cwd + '/')
  }
  return [...out].filter((p) => !DEFAULT_IGNORE.test(p))
}

export class CollisionWatcher {
  private readonly windowMs: number
  private readonly now: () => number
  private readonly ignore: RegExp
  private readonly touches = new Map<string, Touch[]>() // path -> touches
  private readonly branches = new Map<string, Touch[]>() // repo::branch -> touches
  private readonly alerted = new Map<string, number>()   // kind:key -> last alert
  private readonly events: CollisionEvent[] = []
  private readonly locks = new Map<string, BranchLock>()
  private readonly listeners = new Set<(e: CollisionEvent) => void>()

  constructor(opts: CollisionWatcherOptions = {}) {
    this.windowMs = opts.windowMs ?? 60 * 60 * 1000
    this.now = opts.now ?? Date.now
    this.ignore = opts.ignore ?? DEFAULT_IGNORE
  }

  onCollision(cb: (e: CollisionEvent) => void): () => void { this.listeners.add(cb); return () => { this.listeners.delete(cb) } }

  /** Feed one tool call. Returns any new events it caused. */
  noteTool(agent: { agentId: string; agentName: string }, toolName: string, input: unknown, cwd?: string): CollisionEvent[] {
    const out: CollisionEvent[] = []
    for (const p of pathsFromToolInput(toolName, input, cwd)) {
      if (this.ignore.test(p)) continue
      const isFolder = p.endsWith('/')
      const key = isFolder ? p : p
      const list = this.prune(this.touches, key)
      this.push(list, agent)
      const others = this.otherAgents(list, agent.agentId)
      if (others.length) out.push(...this.raise(isFolder ? 'folder' : 'file', key, agent, others, `${isFolder ? 'folder' : 'file'} ${key}`))
      // Two agents in the same folder within the window is worth a word even when the files differ.
      if (!isFolder) {
        const folder = p.slice(0, p.lastIndexOf('/') + 1)
        const flist = this.prune(this.touches, folder)
        this.push(flist, agent)
        const fothers = this.otherAgents(flist, agent.agentId)
        if (fothers.length && !others.length) out.push(...this.raise('folder', folder, agent, fothers, `folder ${folder}`))
      }
    }
    return out
  }

  /** Feed one branch observation (which repo and branch an agent's cwd is on). */
  noteBranch(agent: { agentId: string; agentName: string }, repo: string, branch: string): CollisionEvent[] {
    if (!repo || !branch) return []
    const key = `${repo}::${branch}`
    const list = this.prune(this.branches, key)
    this.push(list, agent)
    const out: CollisionEvent[] = []
    const others = this.otherAgents(list, agent.agentId)
    if (others.length) out.push(...this.raise('branch', key, agent, others, `branch ${branch} in ${repo}`))
    const lock = this.locks.get(key)
    if (lock && lock.holderAgentId !== agent.agentId) {
      out.push(...this.raise('lock', key, agent, [{ agentId: lock.holderAgentId, agentName: lock.holderName }], `branch ${branch} is locked by ${lock.holderName}`))
    }
    return out
  }

  lock(input: { repo: string; branch: string; holderAgentId: string; holderName: string; machineId: string }): BranchLock | { error: string } {
    const key = `${input.repo}::${input.branch}`
    const existing = this.locks.get(key)
    if (existing && existing.holderAgentId !== input.holderAgentId) return { error: `held by ${existing.holderName} since ${new Date(existing.at).toISOString()}` }
    const lock: BranchLock = { key, ...input, at: this.now() }
    this.locks.set(key, lock)
    return lock
  }
  unlock(repo: string, branch: string): boolean { return this.locks.delete(`${repo}::${branch}`) }
  listLocks(): BranchLock[] { return [...this.locks.values()] }
  /** Replace the lock table (loaded from disk). */
  setLocks(locks: BranchLock[]): void { this.locks.clear(); for (const l of locks) this.locks.set(l.key, l) }

  /** Events inside the window, newest first. */
  recent(): CollisionEvent[] {
    const cut = this.now() - this.windowMs
    return this.events.filter((e) => e.at >= cut).sort((a, b) => b.at - a.at)
  }

  private prune(map: Map<string, Touch[]>, key: string): Touch[] {
    const cut = this.now() - this.windowMs
    const list = (map.get(key) ?? []).filter((t) => t.at >= cut)
    map.set(key, list)
    return list
  }
  private push(list: Touch[], agent: { agentId: string; agentName: string }): void {
    const i = list.findIndex((t) => t.agentId === agent.agentId)
    const touch = { ...agent, at: this.now() }
    if (i >= 0) list[i] = touch; else list.push(touch)
  }
  private otherAgents(list: Touch[], agentId: string): Array<{ agentId: string; agentName: string }> {
    return list.filter((t) => t.agentId !== agentId).map((t) => ({ agentId: t.agentId, agentName: t.agentName }))
  }
  /** One alert per kind+key per window, so a busy pair does not page a person every keystroke. */
  private raise(kind: CollisionKind, key: string, agent: { agentId: string; agentName: string }, others: Array<{ agentId: string; agentName: string }>, detail: string): CollisionEvent[] {
    const id = `${kind}:${key}`
    const last = this.alerted.get(id)
    if (last !== undefined && this.now() - last < this.windowMs) return []
    this.alerted.set(id, this.now())
    const e: CollisionEvent = { kind, key, at: this.now(), agents: [{ agentId: agent.agentId, agentName: agent.agentName }, ...others], detail: `${[agent.agentName, ...others.map((o) => o.agentName)].join(' and ')} on ${detail}` }
    this.events.push(e)
    if (this.events.length > 200) this.events.splice(0, this.events.length - 200)
    for (const cb of this.listeners) cb(e)
    return [e]
  }
}
