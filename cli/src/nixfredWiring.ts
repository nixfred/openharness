/**
 * The nixfred additions, wired as one object the daemon calls at a handful of points. Everything here
 * is built from pure modules (lib/attention, lib/actionPolicy, lib/spendBrake, lib/machineCapabilities,
 * nixfred/*) so the daemon's own files change as little as possible:
 *
 *   attention   turn/question/cancel taps → `attention` frames to local windows, desktop notice, recap
 *   gate        tool-start → policy verdict (Claude PreToolUse permissionDecision)
 *   spend       submit → pause when caps are hit; ledger persisted per day
 *   loops       `/loop` submits deferred on battery, lid, busy GPU, quiet hours; one machine holds a lease
 *   audit/spans every tool, turn, gate and spend decision in an append-only redacted journal + OTLP spans
 *   commands    the `harness nixfred ...` local API: capabilities, checkpoint, bundle, record, pin, spend, gate
 */
import { execFile } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { promises as fsp } from 'node:fs'
import { hostname } from 'node:os'
import { join } from 'node:path'
import { env } from './config/env.js'
import { AttentionTracker, summarizeAttention, type AttentionRow, type AttentionState } from './lib/attention.js'
import { DEFAULT_POLICY, evaluateToolCall, parsePolicy, type ActionPolicy, type GateVerdict } from './lib/actionPolicy.js'
import { DEFAULT_CAPS, decideSpend, emptyLedger, parseCaps, recordUsage, type BrakeVerdict, type SpendCaps, type SpendLedger } from './lib/spendBrake.js'
import { decidePlacement, describeCapabilities, readMachineCapabilities, type MachineCapabilities, type PlacementRequest } from './lib/machineCapabilities.js'
import { notifyAttention } from './lib/desktopNotify.js'
import { adoptPane, forgetPane, loadAdoptedPanes } from './lib/adoptedPanes.js'
import { AuditJournal, type AuditEntry } from './nixfred/auditJournal.js'
import { JsonlSpanExporter, OtlpHttpSpanExporter, Tracer, type Span, type SpanExporter } from './nixfred/spans.js'
import { DEFAULT_LOOP_POLICY, LoopLeaseStore, shouldDeferLoop, type LoopPolicy } from './nixfred/loopLease.js'
import { buildCheckpoint, listCheckpoints, restoreCheckpoint, describeCheckpoint } from './nixfred/taskCheckpoint.js'
import { buildReviewBundle } from './nixfred/reviewBundle.js'
import { listPins, pin, startRecording, stopRecording, toAsciicast } from './nixfred/sessionRecorder.js'
import { installGateHook, uninstallGateHook, gateHookInstalled } from './lib/hooks.js'

export interface NixfredSessionLike {
  agentId: string
  sessionId: string
  engine: string
  active: boolean
  tmuxPane?: string
  cwd?: string
  transcriptPath?: string
  model?: string | null
  name: string
}

export interface NixfredDeps {
  dataDir?: string
  machineId: () => string
  machineName: () => string
  sessions: () => NixfredSessionLike[]
  /** Push a frame to every local window (desktop). */
  sendLocal: (frame: { type: string; payload: Record<string, unknown> }) => void
  /** Push an error message frame to the web for one agent. */
  sendError: (agentId: string, sessionId: string, message: string) => void
  cancelAgent: (agentId: string, confirmed: boolean) => Promise<boolean>
  tokenUsage: (s: NixfredSessionLike) => { totalTokens: number | null } | null
  /** Ask discovery to look at a pane now (adoption). */
  rediscover?: () => void
  hookPort: () => number
  now?: () => number
}

const exec = (cmd: string, args: string[], opts: { cwd?: string } = {}, timeout = 15_000): Promise<string> =>
  new Promise((resolve, reject) => {
    execFile(cmd, args, { cwd: opts.cwd, timeout, maxBuffer: 8 << 20 }, (err, stdout) => (err ? reject(err) : resolve(String(stdout))))
  })

function readJson<T>(file: string): T | null {
  try { return JSON.parse(readFileSync(file, 'utf8')) as T } catch { return null }
}
function writeJson(file: string, value: unknown): void {
  mkdirSync(join(file, '..'), { recursive: true })
  const tmp = `${file}.${process.pid}.tmp`
  writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n')
  renameSync(tmp, file)
}

export class Nixfred {
  readonly attention: AttentionTracker
  readonly audit: AuditJournal
  readonly tracer: Tracer
  private readonly dataDir: string
  private policy: ActionPolicy
  private caps: SpendCaps
  private ledger: SpendLedger
  private loopPolicy: LoopPolicy
  private capsCache: { at: number; value: MachineCapabilities } | null = null
  private readonly turnSpans = new Map<string, Span>()
  private readonly leases: LoopLeaseStore
  private readonly now: () => number

  constructor(private readonly deps: NixfredDeps) {
    this.now = deps.now ?? Date.now
    this.dataDir = deps.dataDir ?? env.ADAPTER_DATA_DIR
    mkdirSync(this.dataDir, { recursive: true })
    this.attention = new AttentionTracker(this.now)
    this.audit = new AuditJournal({
      appendFile: (p, d) => fsp.appendFile(p, d), readFile: (p) => fsp.readFile(p, 'utf8'),
      stat: async (p) => ({ size: (await fsp.stat(p)).size }), rename: (a, b) => fsp.rename(a, b),
      unlink: (p) => fsp.unlink(p), mkdir: async (p) => { await fsp.mkdir(p, { recursive: true }) },
      exists: async (p) => existsSync(p),
    }, this.dataDir)
    const exporters: SpanExporter[] = [new JsonlSpanExporter((p, d) => fsp.appendFile(p, d), this.dataDir)]
    const otlp = process.env.OTEL_EXPORTER_OTLP_ENDPOINT
    if (otlp) exporters.push(new OtlpHttpSpanExporter(`${otlp.replace(/\/$/, '')}/v1/traces`, (url, init) => fetch(url, init).then((r) => ({ ok: r.ok, status: r.status })), 'openharness-daemon', deps.machineName()))
    this.tracer = new Tracer({ exporter: { export: async (spans) => { for (const e of exporters) await e.export(spans) } }, service: 'openharness-daemon', host: deps.machineName() })
    this.policy = this.loadPolicy()
    this.caps = this.loadCaps()
    this.ledger = readJson<SpendLedger>(this.file('spend-ledger.json')) ?? emptyLedger(this.now())
    this.loopPolicy = readJson<LoopPolicy>(this.file('loop-policy.json')) ?? DEFAULT_LOOP_POLICY
    this.leases = new LoopLeaseStore({ readFile: (p) => fsp.readFile(p, 'utf8'), writeFile: (p, d) => fsp.writeFile(p, d), now: this.now, dataDir: this.dataDir })
    this.attention.onChange((entry, previous) => this.onAttentionChange(entry.agentId, entry.state, previous, entry.detail))
  }

  private file(name: string): string { return join(this.dataDir, name) }

  /** Append to the audit journal with the machine and time filled in; never throws, never awaited. */
  private log(e: Omit<AuditEntry, 'at' | 'machine' | 'agentId'> & { agentId?: string }): void {
    void this.audit.append({ ...e, agentId: e.agentId ?? 'daemon', at: this.now(), machine: this.deps.machineName() }).catch(() => {})
  }

  // ── attention ───────────────────────────────────────────────────────────────────────────────────

  snapshot(): AttentionRow[] { return this.attention.snapshot(this.deps.sessions(), this.deps.machineName()) }

  attentionPayload(): Record<string, unknown> {
    const agents = this.snapshot()
    return { machineId: this.deps.machineId(), hostname: this.deps.machineName(), at: this.now(), summary: summarizeAttention(agents), agents }
  }

  private onAttentionChange(agentId: string, state: AttentionState, previous: AttentionState | null, detail: string): void {
    const payload = this.attentionPayload()
    this.deps.sendLocal({ type: 'attention', payload })
    const row = (payload.agents as AttentionRow[]).find((r) => r.agentId === agentId)
    const name = row?.name ?? agentId
    this.log({ kind: 'turn', agentId, name: `attention ${previous ?? 'none'} -> ${state}`, detail })
    if (state === 'waiting' || state === 'permission' || state === 'failed') {
      void notifyAttention({ agentName: name, machine: this.deps.machineName(), state, detail }).catch(() => {})
    }
    if (state === 'done' && row) this.exportRecap(row)
    if (state === 'working') {
      this.turnSpans.get(agentId)?.end('ok')
      this.turnSpans.set(agentId, this.tracer.start('agent.turn', { agentId, name, engine: row?.engine ?? '' }))
    } else if (state !== 'idle' || previous === 'working') {
      const span = this.turnSpans.get(agentId)
      if (span) { span.end(state === 'failed' ? 'error' : 'ok'); this.turnSpans.delete(agentId) }
    }
  }

  /** The stable per-turn recap line the breadcrumb hook and `mem search` can read without parsing transcripts. */
  private exportRecap(row: AttentionRow): void {
    const s = this.deps.sessions().find((x) => x.agentId === row.agentId)
    const line = JSON.stringify({ at: new Date(this.now()).toISOString(), machine: this.deps.machineName(), agentId: row.agentId, name: row.name, engine: row.engine, cwd: s?.cwd ?? null, detail: row.detail })
    const dir = this.file('recaps')
    mkdirSync(dir, { recursive: true })
    const day = new Date(this.now()).toISOString().slice(0, 10)
    void fsp.appendFile(join(dir, `${day}.jsonl`), line + '\n').catch(() => {})
  }

  // ── gate ────────────────────────────────────────────────────────────────────────────────────────

  private loadPolicy(): ActionPolicy {
    const raw = readJson<unknown>(this.file('action-policy.json'))
    if (raw === null) return DEFAULT_POLICY
    const parsed = parsePolicy(raw)
    if (parsed.ok) return parsed.policy
    console.error(`[gate] action-policy.json ignored: ${parsed.problems.join('; ')}`)
    return DEFAULT_POLICY
  }

  gate(sessionId: string, agentId: string, toolName: string, input: unknown): GateVerdict {
    const verdict = evaluateToolCall(this.policy, toolName, input)
    if (verdict.decision !== 'allow') {
      console.log(`[gate] ${agentId} ${toolName} → ${verdict.decision} (${verdict.rule})`)
      this.log({ kind: 'gate', agentId, sessionId, name: toolName, detail: verdict.reason, decision: verdict.decision })
      if (verdict.decision === 'ask') this.attention.question(agentId, true, verdict.reason)
    }
    return verdict
  }

  gateStatus(): Record<string, unknown> {
    return { installed: gateHookInstalled(), enabled: this.policy.enabled, rules: this.policy.rules.length, file: this.file('action-policy.json'), fileExists: existsSync(this.file('action-policy.json')) }
  }

  gateInit(): string { const f = this.file('action-policy.json'); if (!existsSync(f)) writeJson(f, DEFAULT_POLICY); this.policy = this.loadPolicy(); return f }

  // ── spend ───────────────────────────────────────────────────────────────────────────────────────

  private loadCaps(): SpendCaps {
    const raw = readJson<unknown>(this.file('spend-caps.json'))
    if (raw === null) return DEFAULT_CAPS
    const parsed = parseCaps(raw)
    if (parsed.ok) return parsed.caps
    console.error(`[spend] spend-caps.json ignored: ${parsed.problems.join('; ')}`)
    return DEFAULT_CAPS
  }

  /** Record what this agent has used so far, then decide whether its next turn may run. */
  spendCheck(s: NixfredSessionLike): BrakeVerdict {
    const usage = this.deps.tokenUsage(s)
    const total = usage?.totalTokens ?? 0
    // The engines report a total; treat a fifth as output, which is where most of the money goes.
    this.ledger = recordUsage(this.ledger, { agentId: s.agentId, model: s.model ?? null, input: Math.round(total * 0.8), output: Math.round(total * 0.2), now: this.now() })
    writeJson(this.file('spend-ledger.json'), this.ledger)
    const verdict = decideSpend(this.caps, this.ledger, s.agentId)
    if (verdict.action !== 'run') {
      console.log(`[spend] ${s.agentId} ${verdict.action}: ${verdict.reason}`)
      this.log({ kind: 'spend', agentId: s.agentId, sessionId: s.sessionId, name: verdict.action, detail: verdict.reason })
    }
    if (verdict.action === 'pause') {
      this.attention.question(s.agentId, false, `spend brake: ${verdict.reason}`)
      this.deps.sendError(s.agentId, s.sessionId, `Spend brake ${verdict.reason}. Raise the cap with "harness spend set" to continue.`)
    }
    return verdict
  }

  spendStatus(): Record<string, unknown> {
    return { caps: this.caps, day: this.ledger.day, agents: Object.values(this.ledger.agents).map((a) => ({ agentId: a.agentId, model: a.model, tokens: a.input + a.output, usd: Number(a.usd.toFixed(4)) })) }
  }

  spendSet(patch: Partial<SpendCaps>): SpendCaps {
    const next = { ...this.caps, ...patch, version: 1 as const }
    const parsed = parseCaps(next)
    if (!parsed.ok) throw new Error(parsed.problems.join('; '))
    this.caps = parsed.caps
    writeJson(this.file('spend-caps.json'), this.caps)
    return this.caps
  }

  // ── loops ───────────────────────────────────────────────────────────────────────────────────────

  async capabilities(maxAgeMs = 30_000): Promise<MachineCapabilities> {
    if (this.capsCache && this.now() - this.capsCache.at < maxAgeMs) return this.capsCache.value
    const value = await readMachineCapabilities()
    this.capsCache = { at: this.now(), value }
    return value
  }

  /** For a `/loop` submit: defer when the machine should not run batch work, and hold a fleet lease. */
  async loopCheck(s: NixfredSessionLike, content: string): Promise<{ run: true } | { run: false; reason: string }> {
    if (!/^\s*\/loop\b/.test(content)) return { run: true }
    const caps = await this.capabilities()
    const d = shouldDeferLoop(caps, this.loopPolicy, this.now())
    if (d.defer) {
      const reason = `loop deferred: ${d.reason ?? 'machine policy'}`
      this.log({ kind: 'turn', agentId: s.agentId, sessionId: s.sessionId, name: 'loop-defer', detail: reason })
      this.deps.sendError(s.agentId, s.sessionId, `${reason} (retry in ${Math.round((d.retryAfterMs ?? 0) / 60000)} min)`)
      return { run: false, reason }
    }
    const jobKey = `${s.cwd ?? ''}::${content.slice(0, 200)}`
    const lease = await this.leases.acquire(jobKey, this.deps.machineId(), 6 * 60 * 60 * 1000)
    if (!lease.ok) {
      const reason = `loop held by ${lease.holder ?? 'another machine'}`
      this.deps.sendError(s.agentId, s.sessionId, reason)
      return { run: false, reason }
    }
    return { run: true }
  }

  placement(req: PlacementRequest): Promise<{ ok: boolean; reasons: string[]; caps: string }> {
    return this.capabilities().then((caps) => ({ ...decidePlacement(caps, req), caps: describeCapabilities(caps) }))
  }

  // ── panic stop, adoption ───────────────────────────────────────────────────────────────────────

  async stopAll(exceptAgentId: string | null): Promise<{ cancelled: string[] }> {
    const cancelled: string[] = []
    for (const s of this.deps.sessions()) {
      if (!s.active || s.agentId === exceptAgentId) continue
      try { if (await this.deps.cancelAgent(s.agentId, true)) cancelled.push(s.agentId) } catch { /* next */ }
      this.attention.cancelled(s.agentId)
    }
    this.log({ kind: 'command', name: 'stop-all', detail: `cancelled ${cancelled.length}, kept ${exceptAgentId ?? 'none'}` })
    console.log(`[nixfred] panic stop: cancelled ${cancelled.length} agent(s)`)
    return { cancelled }
  }

  async adopt(pane: string, engine: string | null): Promise<{ ok: boolean; detail: string }> {
    let sessionName = ''
    try { sessionName = (await exec('tmux', ['display-message', '-p', '-t', pane, '#{session_name}'], {}, 3000)).trim() } catch { return { ok: false, detail: `tmux does not know pane ${pane}` } }
    if (!sessionName) return { ok: false, detail: `pane ${pane} has no session` }
    adoptPane({ pane, sessionName, engine })
    this.log({ kind: 'command', name: 'adopt', detail: `${pane} in ${sessionName} as ${engine ?? 'auto'}` })
    this.deps.rediscover?.()
    return { ok: true, detail: `adopted ${pane} (session ${sessionName}); discovery will register it on its next pass or the agent's next prompt` }
  }

  unadopt(pane: string): boolean { return forgetPane(pane) }
  adopted() { return loadAdoptedPanes() }

  // ── the local command surface (`harness nixfred <action>`) ─────────────────────────────────────

  async command(action: string, args: Record<string, unknown>): Promise<unknown> {
    const str = (k: string): string => (typeof args[k] === 'string' ? args[k] as string : '')
    const session = (id: string) => this.deps.sessions().find((s) => s.agentId === id || s.sessionId === id)
    const cpDeps = {
      exec: (c: string, a: string[], o: { cwd: string }) => exec(c, a, o), writeFile: (p: string, d: string) => fsp.writeFile(p, d),
      readFile: (p: string) => fsp.readFile(p, 'utf8'), mkdir: async (p: string) => { await fsp.mkdir(p, { recursive: true }) },
      listDir: (p: string) => fsp.readdir(p), now: this.now, dataDir: this.dataDir, machine: this.deps.machineName(),
    }
    const recDeps = { exec: (c: string, a: string[]) => exec(c, a), writeFile: cpDeps.writeFile, readFile: cpDeps.readFile, stat: async (p: string) => ({ size: (await fsp.stat(p)).size }), mkdir: cpDeps.mkdir, now: this.now }
    switch (action) {
      case 'attention': return this.attentionPayload()
      case 'capabilities': return { ...(await this.capabilities(0)), line: describeCapabilities(await this.capabilities()) }
      case 'placement': return this.placement(args as PlacementRequest)
      case 'gate-status': return this.gateStatus()
      case 'gate-init': return { file: this.gateInit() }
      case 'gate-install': return { result: installGateHook(this.deps.hookPort()), ...this.gateStatus() }
      case 'gate-uninstall': return { result: uninstallGateHook(), ...this.gateStatus() }
      case 'gate-reload': this.policy = this.loadPolicy(); return this.gateStatus()
      case 'spend-status': return this.spendStatus()
      case 'spend-set': {
        const patch: Partial<SpendCaps> = {}
        for (const k of ['perAgentUsd', 'perAgentTokens', 'perDayUsd', 'perDayTokens', 'warnAt'] as const) {
          if (args[k] === null) patch[k] = null as never
          else if (typeof args[k] === 'number') patch[k] = args[k] as never
        }
        if (typeof args.enabled === 'boolean') patch.enabled = args.enabled
        return { caps: this.spendSet(patch) }
      }
      case 'stop-all': return this.stopAll(str('except') || null)
      case 'adopt': return this.adopt(str('pane'), str('engine') || null)
      case 'unadopt': return { removed: this.unadopt(str('pane')) }
      case 'adopted': return { panes: this.adopted() }
      case 'audit-tail': return { lines: await this.audit.tail(typeof args.n === 'number' ? args.n : 50) }
      case 'checkpoint': {
        const s = session(str('agentId')); if (!s?.cwd) throw new Error('unknown agent or no cwd')
        const out = await buildCheckpoint(cpDeps, { agentId: s.agentId, cwd: s.cwd, brief: str('brief'), decisions: Array.isArray(args.decisions) ? args.decisions.map(String) : [], notes: str('notes') })
        return { dir: out.dir, summary: describeCheckpoint(out.checkpoint) }
      }
      case 'checkpoints': return { dirs: await listCheckpoints(cpDeps, str('agentId')) }
      case 'restore': return restoreCheckpoint(cpDeps, str('dir'), str('cwd'))
      case 'bundle': {
        const s = session(str('agentId')); if (!s?.cwd) throw new Error('unknown agent or no cwd')
        return buildReviewBundle({ exec: cpDeps.exec, writeFile: cpDeps.writeFile, readFile: cpDeps.readFile, mkdir: cpDeps.mkdir, now: this.now, machine: this.deps.machineName() },
          { agentId: s.agentId, cwd: s.cwd, brief: str('brief'), transcriptPath: s.transcriptPath, auditPath: this.file('audit.jsonl'), checkpointPath: str('checkpoint') || undefined, outDir: str('outDir') || this.file('bundles') })
      }
      case 'record-start': {
        const s = session(str('agentId')); if (!s?.tmuxPane) throw new Error('unknown agent or no tmux pane')
        return startRecording(recDeps, { pane: s.tmuxPane, agentId: s.agentId, dataDir: this.dataDir })
      }
      case 'record-stop': return stopRecording(recDeps, { agentId: str('agentId'), dataDir: this.dataDir })
      case 'pin': return pin(recDeps, { agentId: str('agentId'), dataDir: this.dataDir, label: str('label') || 'pin' })
      case 'pins': return { pins: await listPins(recDeps, { agentId: str('agentId'), dataDir: this.dataDir }) }
      case 'asciicast': {
        const dir = join(this.dataDir, 'recordings', str('agentId'))
        const raw = await fsp.readFile(join(dir, 'raw.log'), 'utf8')
        const sidecar = JSON.parse(await fsp.readFile(join(dir, 'sidecar.json'), 'utf8'))
        const out = join(dir, 'recording.cast')
        await fsp.writeFile(out, toAsciicast(raw, sidecar))
        return { file: out }
      }
      default: throw new Error(`unknown nixfred action: ${action}`)
    }
  }
}

export type { AttentionRow, GateVerdict, BrakeVerdict, AuditEntry }
