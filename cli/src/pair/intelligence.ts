/** The collection's background reasoning uses its DSH's observed model, never the voice router. */
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { parseRuntimeProfile, type RuntimeProfile } from '../lib/runtimeProfile.js'
import { runClaudeOneShot, runCodexOneShot, type OneShotOptions } from '../lib/oneshot.js'
import type { PairOneShot } from './triage.js'
import type { StartupProfile } from './startupProfile.js'

export interface CompanionRuntime {
  agentId: string
  sessionId: string | null
  engine: string
  profile: string | null
  stopped: boolean
  codexHome?: string | null
  customProvider?: boolean
  startup?: StartupProfile | null
}

export interface IntelligenceStatus {
  state: 'off' | 'unopened' | 'waiting' | 'unsupported' | 'ready'
  agentId?: string
  engine?: string
  model?: string
  effort?: string
}

interface IntelligenceDeps {
  enabled: () => boolean
  current: () => CompanionRuntime | null
  directory: string
  stateFile: string
  run?: (engine: 'claude' | 'codex', options: OneShotOptions) => Promise<{ text: string }>
}

export class CompanionIntelligence {
  private saved: Record<string, { sessionId: string; profile: string }> | null = null
  private readonly calls = new Set<AbortController>()

  constructor(private readonly deps: IntelligenceDeps) {}

  status(): IntelligenceStatus { return this.target().status }
  ready(): boolean { return this.status().state === 'ready' }

  /** Abort on experimental-off/account changes. No worker becomes a discoverable agent. */
  cancel(): void { for (const call of this.calls) call.abort(); this.calls.clear() }

  readonly run: PairOneShot = async (prompt, opts) => {
    const target = this.target()
    if (!target.profile || !target.runtime || target.status.state !== 'ready') return null
    const { runtime, profile } = target
    const engine = runtime.engine as 'claude' | 'codex'
    const controller = new AbortController()
    const abort = (): void => controller.abort()
    opts.signal?.addEventListener('abort', abort, { once: true })
    if (opts.signal?.aborted) controller.abort()
    this.calls.add(controller)
    try {
      mkdirSync(this.deps.directory, { recursive: true, mode: 0o700 })
      const options: OneShotOptions = {
        prompt, cwd: this.deps.directory, model: profile.model,
        ...(profile.effort !== 'auto' ? { effort: profile.effort as OneShotOptions['effort'] } : {}),
        ...(engine === 'codex' && runtime.codexHome ? { codexHome: runtime.codexHome } : {}),
        timeoutMs: opts.timeoutMs, signal: controller.signal,
      }
      const run = this.deps.run ?? ((engine, options) => engine === 'claude' ? runClaudeOneShot(options) : runCodexOneShot(options))
      const result = await run(engine, options)
      const current = this.target()
      // A result from an old model, account, or conversation is never accepted under the new one.
      if (controller.signal.aborted || current.status.state !== 'ready' ||
        current.runtime?.sessionId !== runtime.sessionId || current.profile?.id !== profile.id ||
        (!runtime.sessionId && current.runtime?.startup?.processKey !== runtime.startup?.processKey) ||
        current.runtime?.codexHome !== runtime.codexHome) return null
      return result.text
    } finally {
      opts.signal?.removeEventListener('abort', abort)
      this.calls.delete(controller)
    }
  }

  private target(): { status: IntelligenceStatus; runtime?: CompanionRuntime; profile?: RuntimeProfile } {
    if (!this.deps.enabled()) return { status: { state: 'off' } }
    const runtime = this.deps.current()
    if (!runtime) return { status: { state: 'unopened' } }
    const status: IntelligenceStatus = { state: 'waiting', agentId: runtime.agentId, engine: runtime.engine }
    // Custom provider credentials must not silently fall back to the local subscription.
    if (!['claude', 'codex'].includes(runtime.engine) || runtime.customProvider) return { status: { ...status, state: 'unsupported' } }
    if (!runtime.sessionId && (runtime.stopped || !runtime.startup)) return { status }
    this.load()
    const cached = this.saved![runtime.agentId]
    const value = runtime.sessionId
      ? runtime.profile ?? (runtime.stopped && cached?.sessionId === runtime.sessionId ? cached.profile : null)
      : runtime.startup?.profile
    const profile = parseRuntimeProfile(value)
    const efforts = runtime.engine === 'claude'
      ? ['auto', 'low', 'medium', 'high', 'xhigh', 'max', 'ultracode']
      : ['auto', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra']
    if (!profile || profile.sessionId !== runtime.agentId || profile.engine !== runtime.engine || !efforts.includes(profile.effort)) return { status }
    // Pre-conversation readiness is live evidence, never a durable substitute for a conversation ID.
    if (runtime.sessionId && (cached?.profile !== profile.id || cached.sessionId !== runtime.sessionId)) {
      this.saved![runtime.agentId] = { sessionId: runtime.sessionId, profile: profile.id }
      mkdirSync(dirname(this.deps.stateFile), { recursive: true, mode: 0o700 })
      const tmp = `${this.deps.stateFile}.tmp`
      writeFileSync(tmp, JSON.stringify(this.saved), { mode: 0o600 })
      renameSync(tmp, this.deps.stateFile)
    }
    return { runtime, profile, status: { ...status, state: 'ready', model: profile.model, effort: profile.effort } }
  }

  private load(): void {
    if (this.saved) return
    this.saved = Object.create(null) as Record<string, { sessionId: string; profile: string }>
    try {
      const raw: unknown = JSON.parse(readFileSync(this.deps.stateFile, 'utf8'))
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return
      for (const [id, value] of Object.entries(raw)) {
        if (!value || typeof value !== 'object') continue
        const row = value as { sessionId?: unknown; profile?: unknown }
        if (typeof row.sessionId === 'string' && typeof row.profile === 'string' && parseRuntimeProfile(row.profile)?.sessionId === id) {
          this.saved[id] = { sessionId: row.sessionId, profile: row.profile }
        }
      }
    } catch { /* No selected model has been observed yet. */ }
  }
}
