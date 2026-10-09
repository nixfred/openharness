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
import { installGateHook, uninstallGateHook, gateHookInstalled } from './nixfred/gateHook.js'
import { CollisionWatcher, type BranchLock, type CollisionEvent } from './nixfred/collisionWatch.js'
import { CiWatcher, parsePrChecks } from './nixfred/ciWatch.js'
import { DISPATCH_RESULT_TYPE, createRemoteAgentBackend, jobPrompt, type DispatchResult, type JobSpec, type MachineLink, type WireFrame } from './nixfred/remoteOrchestratorBackend.js'
import { describeHermesHealth, hermesHealth, stampHermesDoctor } from './nixfred/hermesHealth.js'
import { describeSubscriptions, SubscriptionsService, type ProviderId } from './nixfred/subscriptions/index.js'
import { nodeSubscriptionsDeps } from './nixfred/subscriptions/nodeDeps.js'
import { listHermesHomes } from './engines/hermes/home.js'

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
  /** nixfred watch mode: a session this daemon did not start. */
  external?: boolean
  /** The herdr pane an external session runs in, so its notification can take you there. */
  herdrPane?: string | null
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
  /** Deliver a message into an agent's pane as a new turn (the CI-failure wake). */
  sendToAgent?: (agentId: string, text: string) => void
  hookPort: () => number
  now?: () => number
  /** Write to this machine's clipboard (default: wl-copy, xclip or pbcopy, whichever is present). */
  clipWrite?: (text: string) => Promise<void>
  /** Where pushed files land (default ~/Downloads/harness-drop or HARNESS_DROP_DIR). */
  dropDir?: string
  /** Send a `nixfred.*` frame to every plugged-in dial. Stock firmware counts it unknown and drops it. */
  toDial?: (msg: { t: string; [key: string]: unknown }) => void
}

/** The dial's tone codes, in the order the nixfred firmware's palette reads them. */
const DIAL_TONES: Record<string, number> = { unknown: 0, banked: 1, 'on-pace': 2, amber: 3, red: 4 }

/**
 * The subscriptions block as the dial draws it: one arc per plan, weekly use in permille (0..1000) and
 * a tone code. At most four plans (the rim's plan sector holds four). Null when there is nothing yet.
 */
export function dialPlans(compact: ReturnType<SubscriptionsService['compact']>): { t: 'nixfred.subs'; pick: string; subs: Array<{ id: string; name: string; used: number; tone: number; banked: number }> } | null {
  if (!compact) return null
  const permille = (v: number, lo: number): number => Math.round(Math.min(1, Math.max(lo, Number.isFinite(v) ? v : 0)) * 1000)
  return {
    t: 'nixfred.subs',
    pick: compact.pick,
    // name (9 characters, the dial's label) and banked (signed permille, + under the even pace) feed the
    // nixfred firmware's plans face (slice 3); older nixfred firmware reads only used and tone.
    subs: compact.subs.slice(0, 4).map((s) => ({
      id: s.id,
      name: String(s.name || s.id).slice(0, 9),
      used: permille(s.used, 0),
      tone: DIAL_TONES[s.tone] ?? 0,
      banked: permille(s.bankedSigned, -1),
    })),
  }
}

/** What the attention payload holds that `dialFleet` reads. */
export interface DialFleetSource {
  machineId: string
  agents: Array<{ agentId: string; lane?: string | null; state?: string }>
  alerts: CollisionEvent[]
}

/**
 * `nixfred.fleet`: what the dial cannot see for itself (nixfred firmware slice 3). The local time of day
 * for the ambient clock, each agent's policy lane as one letter, the newest collision inside its hour,
 * and this machine's load, battery and VRAM as permille for its machine tile. Every field is optional on
 * the dial; stock firmware counts the frame unknown and drops it.
 *
 * `perm` (firmware slice 6): the agents whose open question is a PERMISSION prompt, so the hub's suggested
 * next action can put a permission before an ordinary question. Only the ids; the words stay in the inbox.
 */
export function dialFleet(src: DialFleetSource, caps: MachineCapabilities | null, now: number): Record<string, unknown> & { t: 'nixfred.fleet' } {
  const d = new Date(now)
  const frame: Record<string, unknown> & { t: 'nixfred.fleet' } = {
    t: 'nixfred.fleet',
    clock: d.getHours() * 3600 + d.getMinutes() * 60 + d.getSeconds(),
    lanes: src.agents.filter((a) => typeof a.lane === 'string' && a.lane).slice(0, 16).map((a) => ({ id: a.agentId, lane: a.lane!.charAt(0).toUpperCase() })),
  }
  const perm = src.agents.filter((a) => a.state === 'permission').slice(0, 8).map((a) => a.agentId)
  if (perm.length) frame.perm = perm
  if (caps) {
    const pm = (v: number): number => Math.round(Math.min(1, Math.max(0, v)) * 1000)
    const gpu = caps.gpus[0]
    frame.machine = {
      id: src.machineId,
      load: pm(caps.cpu.cores > 0 ? caps.cpu.load1 / caps.cpu.cores : 0),
      ...(caps.power.batteryPct !== null ? { battery: pm(caps.power.batteryPct / 100) } : {}),
      ...(gpu && gpu.vramTotalMb > 0 ? { vram: pm(gpu.vramUsedMb / gpu.vramTotalMb) } : {}),
    }
  }
  const alert = src.alerts.find((e) => e.agents.length >= 2)
  if (alert) {
    const [a, b] = alert.agents
    frame.alert = { a: a!.agentId, b: b!.agentId, an: a!.agentName, bn: b!.agentName, detail: alert.detail.slice(0, 118), at: alert.at }
  }
  return frame
}

/** A live, E2EE-terminated link to one linked machine, as the daemon's relay pool hands it out. */
export interface RelayLink {
  send(frame: WireFrame): Promise<void>
  onFrame(cb: (frame: WireFrame) => void): () => void
  close(): void
}

export interface DispatchRecord {
  id: string
  machineId: string
  job: JobSpec
  startedAt: number
  finishedAt: number | null
  agentId: string | null
  result: DispatchResult | null
  error: string | null
}

const DISPATCH_RESULT_RE = /DISPATCH_RESULT:\s*(\{[\s\S]*\})/

/**
 * Turn a relay link into the MachineLink the dispatcher library expects, and synthesize the
 * `dispatch_result` frame from the worker's own text: the remote agent prints one
 * `DISPATCH_RESULT: {json}` line, which arrives here as text_delta events; at turn_ended for that
 * agent the line is parsed and re-emitted as if the worker had sent a result frame. No new wire type,
 * no worker-side change, and the relay never sees the plaintext.
 */
export function machineLinkFromRelay(machineId: string, link: RelayLink): MachineLink & { close(): void } {
  const text = new Map<string, string>()
  const listeners = new Set<(f: WireFrame) => void>()
  const emit = (f: WireFrame): void => { for (const cb of listeners) cb(f) }
  const off = link.onFrame((frame) => {
    const p = frame.payload ?? {}
    const agentId = typeof p.agentId === 'string' ? p.agentId : ''
    if (frame.type === 'text_delta' && agentId && typeof p.content === 'string') {
      text.set(agentId, ((text.get(agentId) ?? '') + p.content).slice(-20_000))
    } else if (frame.type === 'turn_ended' && agentId) {
      const m = DISPATCH_RESULT_RE.exec(text.get(agentId) ?? '')
      text.delete(agentId)
      if (m) {
        let parsed: Record<string, unknown> = {}
        try { parsed = JSON.parse(m[1]!) as Record<string, unknown> } catch { parsed = { summary: 'DISPATCH_RESULT line was not valid JSON', ok: false } }
        emit({ type: DISPATCH_RESULT_TYPE, payload: { agentId, ...parsed } })
      }
    }
    emit(frame)
  })
  return {
    machineId,
    send: (frame) => { void link.send(frame) },
    onFrame: (cb) => { listeners.add(cb); return () => { listeners.delete(cb) } },
    close: () => { off(); link.close() },
  }
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
  readonly collisions: CollisionWatcher
  private branchTimer: NodeJS.Timeout | null = null
  readonly ci: CiWatcher
  private ciTimer: NodeJS.Timeout | null = null
  /** Subscription meters (ported from Burn Bar): weekly used, banked, reset, next plan to use. */
  readonly subs: SubscriptionsService
  private subsTimer: NodeJS.Timeout | null = null
  private relayLink: ((machineId: string) => Promise<RelayLink>) | null = null
  private readonly dispatches = new Map<string, DispatchRecord>()

  /** Installed by the daemon once its relay pool exists (it is built after this object). */
  setRelayLink(fn: (machineId: string) => Promise<RelayLink>): void { this.relayLink = fn }

  // ── clipboard and file drop between paired machines ────────────────────────────────────────────

  private async clipWrite(text: string): Promise<void> {
    if (this.deps.clipWrite) return this.deps.clipWrite(text)
    const { spawn } = await import('node:child_process')
    const candidates: Array<[string, string[]]> = process.platform === 'darwin' ? [['pbcopy', []]] : [['wl-copy', []], ['xclip', ['-selection', 'clipboard']]]
    for (const [cmd, args] of candidates) {
      const ok = await new Promise<boolean>((resolve) => {
        const child = spawn(cmd, args, { stdio: ['pipe', 'ignore', 'ignore'] })
        child.on('error', () => resolve(false))
        child.on('exit', (code) => resolve(code === 0))
        child.stdin.end(text)
      })
      if (ok) return
    }
    throw new Error('no clipboard tool (wl-copy, xclip or pbcopy) worked')
  }

  /** A paired machine pushed text or a file here. Text goes to the clipboard; a file lands in the drop folder. */
  async clipReceive(push: { text?: string; file?: { name: string; base64: string }; from: string }): Promise<{ ok: true; detail: string } | { ok: false; error: string }> {
    try {
      if (push.file) {
        const dir = this.deps.dropDir ?? process.env.HARNESS_DROP_DIR ?? join(process.env.HOME ?? '/tmp', 'Downloads', 'harness-drop')
        await fsp.mkdir(dir, { recursive: true })
        // Basename only, then a conservative character set, then no leading dots: a name can never
        // climb out of the drop folder or hide as a dotfile.
        const base = push.file.name.split(/[\\/]/).filter(Boolean).pop() ?? 'file'
        const safe = base.replace(/[^\w.@ -]+/g, '_').replace(/^\.+/, '').slice(0, 120) || 'file'
        let target = join(dir, safe)
        for (let i = 1; existsSync(target); i += 1) target = join(dir, safe.replace(/(\.[^.]*)?$/, `-${i}$1`))
        await fsp.writeFile(target, Buffer.from(push.file.base64, 'base64'))
        this.log({ kind: 'command', name: 'clip-file', detail: `${push.from} -> ${target}` })
        void notifyAttention({ agentName: `file from ${push.from}`, machine: this.deps.machineName(), state: 'waiting', detail: target }).catch(() => {})
        return { ok: true, detail: target }
      }
      if (push.text !== undefined) {
        await this.clipWrite(push.text)
        this.log({ kind: 'command', name: 'clip-text', detail: `${push.from}: ${push.text.length} chars` })
        return { ok: true, detail: `${push.text.length} chars on the clipboard` }
      }
      return { ok: false, error: 'CLIP_EMPTY' }
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) }
    }
  }

  /** Push text or a file to a linked machine over the relay link; waits for its reply. */
  async clipPush(machineId: string, push: { text?: string; file?: { name: string; base64: string } }, timeoutMs = 15_000): Promise<Record<string, unknown>> {
    if (!this.relayLink) throw new Error('clip push is not available: no relay link')
    const link = await this.relayLink(machineId)
    const requestId = `clip-${this.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`
    try {
      const reply = new Promise<Record<string, unknown>>((resolve, reject) => {
        const timer = setTimeout(() => { off(); reject(new Error(`no reply from ${machineId} in ${timeoutMs} ms`)) }, timeoutMs)
        const off = link.onFrame((f) => {
          if (f.type === 'clip_push_result' && f.payload.requestId === requestId) { clearTimeout(timer); off(); resolve(f.payload) }
        })
      })
      await link.send({ type: 'clip_push', payload: { requestId, ...push, from: this.deps.machineName() } })
      const out = await reply
      this.log({ kind: 'command', name: 'clip-push', detail: `${machineId}: ${push.file ? push.file.name : `${push.text?.length ?? 0} chars`} -> ${out.error ?? out.detail ?? 'ok'}` })
      return out
    } finally { link.close() }
  }

  /** Hand a bounded job to a linked machine; returns at once with a record that fills in as it runs. */
  async dispatch(machineId: string, job: JobSpec): Promise<DispatchRecord> {
    if (!this.relayLink) throw new Error('dispatch is not available: no relay link')
    const id = `d-${this.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`
    job = { ...job, machineId }
    const record: DispatchRecord = { id, machineId, job, startedAt: this.now(), finishedAt: null, agentId: null, result: null, error: null }
    this.dispatches.set(id, record)
    this.log({ kind: 'command', name: 'dispatch', detail: `${id} -> ${machineId}: ${job.brief.slice(0, 120)}` })
    void (async () => {
      let link: (MachineLink & { close(): void }) | null = null
      try {
        link = machineLinkFromRelay(machineId, await this.relayLink!(machineId))
        const backend = createRemoteAgentBackend(link, { now: this.now })
        const created = await backend.create({ engine: job.engine, cwd: job.repo, prompt: jobPrompt(job), branchName: job.branchName, ...(job.dsh ? { dsh: job.dsh } : {}) })
        record.agentId = created.agentId
        record.result = await backend.awaitResult(created.agentId, { timeoutMs: job.timeoutMs ?? 60 * 60 * 1000 })
      } catch (err) {
        record.error = err instanceof Error ? err.message : String(err)
      } finally {
        record.finishedAt = this.now()
        link?.close()
        this.log({ kind: 'command', name: 'dispatch-done', detail: `${id}: ${record.error ?? record.result?.summary ?? ''}`.slice(0, 300) })
        void notifyAttention({ agentName: `dispatch ${id}`, machine: machineId, state: record.error ? 'failed' : 'waiting', detail: (record.error ?? record.result?.summary ?? 'done').slice(0, 120) }).catch(() => {})
        void fsp.appendFile(this.file('dispatches.jsonl'), JSON.stringify(record) + '\n').catch(() => {})
      }
    })()
    return record
  }

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
    // The drift alarm: two agents on one file, folder or branch inside an hour. Locks persist per machine.
    this.collisions = new CollisionWatcher({ now: this.now })
    this.collisions.setLocks(readJson<BranchLock[]>(this.file('branch-locks.json')) ?? [])
    this.collisions.onCollision((e) => this.onCollision(e))
    if (process.env.HARNESS_BRANCH_WATCH !== '0') {
      this.branchTimer = setInterval(() => { void this.pollBranches() }, 60_000)
      this.branchTimer.unref()
    }
    // CI-failure wake: `gh pr checks` per agent branch every five minutes; a newly failing check is
    // delivered into the agent's pane once, with the log tail. Needs gh on PATH and a PR for the branch.
    this.ci = new CiWatcher({
      prChecks: async (cwd, branch) => parsePrChecks(await exec('gh', ['pr', 'checks', branch, '--json', 'name,state,link,bucket'], { cwd }, 20_000)),
      failedLog: async (cwd, check) => {
        const run = /\/actions\/runs\/(\d+)/.exec(check.link ?? '')?.[1]
        if (!run) return ''
        try { return (await exec('gh', ['run', 'view', run, '--log-failed'], { cwd }, 30_000)).slice(-20_000) } catch { return '' }
      },
      now: this.now,
    })
    if (process.env.HARNESS_CI_WATCH !== '0' && deps.sendToAgent) {
      this.ciTimer = setInterval(() => { void this.pollCi() }, Number(process.env.HARNESS_CI_WATCH_MS) || 5 * 60_000)
      this.ciTimer.unref()
    }
    // Subscription meters: one pass a minute (each network provider is asked at most every 4 min),
    // pushed as a local `subscriptions` frame; HARNESS_SUBS_WATCH=0 turns the loop off.
    this.subs = new SubscriptionsService(nodeSubscriptionsDeps(this.dataDir))
    if (process.env.HARNESS_SUBS_WATCH !== '0' && !process.env.VITEST) {
      this.subsTimer = setInterval(() => { void this.pollSubscriptions() }, Number(process.env.HARNESS_SUBS_MS) || 60_000)
      this.subsTimer.unref()
      setTimeout(() => { void this.pollSubscriptions() }, 2_000).unref()
    }
  }

  /** Collect every enabled subscription and push it to local windows. Never throws. */
  async pollSubscriptions(force = false): Promise<unknown> {
    try {
      const payload = await this.subs.collect(force)
      this.deps.sendLocal({ type: 'subscriptions', payload: payload as unknown as Record<string, unknown> })
      const dial = dialPlans(this.subs.compact())
      if (dial) this.deps.toDial?.(dial)
      // Once a minute the dial's clock and this machine's capability arcs are refreshed with the plans.
      try { await this.capabilities(55_000) } catch { /* the frame goes without the machine block */ }
      this.pushFleet()
      return payload
    } catch (e) {
      console.log(`[subs] collect failed: ${e instanceof Error ? e.message : String(e)}`)
      return null
    }
  }

  /** One pass of the CI watcher over every active agent that sits on a branch with a PR. */
  async pollCi(): Promise<number> {
    let wakes = 0
    const seenBranch = new Map<string, string | null>()
    for (const s of this.deps.sessions()) {
      if (!s.active || !s.cwd) continue
      let branch = seenBranch.get(s.cwd)
      if (branch === undefined) {
        try { branch = (await exec('git', ['-C', s.cwd, 'branch', '--show-current'], {}, 4000)).trim() || null } catch { branch = null }
        seenBranch.set(s.cwd, branch)
      }
      if (!branch || branch === 'main' || branch === 'master') continue
      const wake = await this.ci.poll({ agentId: s.agentId, agentName: s.name, cwd: s.cwd, branch })
      if (!wake) continue
      wakes += 1
      console.log(`[ci] ${s.agentId} woken: ${wake.failed.map((c) => c.name).join(', ')} failed on ${branch}`)
      this.log({ kind: 'turn', agentId: s.agentId, sessionId: s.sessionId, name: 'ci-failure', detail: wake.failed.map((c) => c.name).join(', ') })
      this.deps.sendToAgent?.(s.agentId, wake.message)
      void notifyAttention({ agentName: s.name, machine: this.deps.machineName(), state: 'failed', detail: `CI: ${wake.failed.map((c) => c.name).join(', ')}` }).catch(() => {})
    }
    return wakes
  }

  /** `nixfred.fleet` to every plugged-in dial, from the attention payload and the cached capabilities. */
  private pushFleet(payload: Record<string, unknown> = this.attentionPayload()): void {
    if (!this.deps.toDial) return
    try {
      this.deps.toDial(dialFleet(payload as unknown as DialFleetSource, this.capsCache?.value ?? null, this.now()))
    } catch (e) {
      console.log(`[dial] fleet frame skipped: ${e instanceof Error ? e.message : String(e)}`)
    }
  }

  private onCollision(e: CollisionEvent): void {
    console.log(`[collision] ${e.detail}`)
    this.log({ kind: 'turn', agentId: e.agents[0]?.agentId ?? 'daemon', name: `collision ${e.kind}`, detail: e.detail })
    const payload = this.attentionPayload()
    this.deps.sendLocal({ type: 'attention', payload })
    this.pushFleet(payload)
    const herdrPane = this.deps.sessions().find((s) => s.agentId === e.agents[0]?.agentId)?.herdrPane ?? null
    void notifyAttention({ agentName: e.agents.map((a) => a.agentName).join(' and '), machine: this.deps.machineName(), state: 'waiting', detail: e.detail, herdrPane }).catch(() => {})
  }

  /** Which repo and branch each active agent's folder is on, fed to the collision watcher. */
  async pollBranches(): Promise<void> {
    const seen = new Map<string, { repo: string; branch: string } | null>()
    for (const s of this.deps.sessions()) {
      if (!s.active || !s.cwd) continue
      let info = seen.get(s.cwd)
      if (info === undefined) {
        try {
          const repo = (await exec('git', ['-C', s.cwd, 'rev-parse', '--show-toplevel'], {}, 4000)).trim()
          const branch = (await exec('git', ['-C', s.cwd, 'branch', '--show-current'], {}, 4000)).trim()
          info = repo ? { repo, branch } : null
        } catch { info = null }
        seen.set(s.cwd, info)
      }
      if (info?.branch) this.collisions.noteBranch({ agentId: s.agentId, agentName: s.name }, info.repo, info.branch)
    }
  }

  private saveLocks(): void { writeJson(this.file('branch-locks.json'), this.collisions.listLocks()) }

  private hermesDeps() {
    return {
      listHomes: () => listHermesHomes(),
      stat: async (p: string) => { try { const st = await fsp.stat(p); return { size: st.size, mtimeMs: st.mtimeMs } } catch { return null } },
      dirBytes: async (p: string) => { try { return Number((await exec('du', ['-sb', p], {}, 10_000)).split(/\s/)[0]) || 0 } catch { return 0 } },
      writers: async (p: string) => { try { return (await exec('lsof', ['-t', p], {}, 5000)).split(/\s+/).filter(Boolean).map(Number) } catch { return [] } },
      hermesVersion: async () => { try { return (await exec('hermes', ['--version'], {}, 5000)).split('\n')[0]?.trim() || null } catch { return null } },
      readJson: async (p: string) => JSON.parse(await fsp.readFile(p, 'utf8')) as unknown,
      writeJson: async (p: string, v: unknown) => { writeJson(p, v) },
      now: this.now,
      dataDir: this.dataDir,
    }
  }

  private file(name: string): string { return join(this.dataDir, name) }

  /** Append to the audit journal with the machine and time filled in; never throws, never awaited. */
  private log(e: Omit<AuditEntry, 'at' | 'machine' | 'agentId'> & { agentId?: string }): void {
    void this.audit.append({ ...e, agentId: e.agentId ?? 'daemon', at: this.now(), machine: this.deps.machineName() }).catch(() => {})
  }

  /**
   * Watch mode (nixfred/orcaWatch.ts): one journal line for every key or text an answer typed into a
   * terminal this daemon does not own, delivered or not. `harness audit` shows them.
   */
  auditAnswer(e: { agentId: string; sessionId: string; route: string; what: string; value: string; ok: boolean; terminal?: string; reason?: string }): void {
    this.log({
      kind: 'answer', agentId: e.agentId, sessionId: e.sessionId, name: `answer via ${e.route}: ${e.what}`,
      detail: `${JSON.stringify(e.value)}${e.terminal ? ` -> ${e.terminal}` : ''}${e.ok ? '' : e.reason ? ` (not delivered: ${e.reason})` : ' (not delivered)'}`,
      decision: e.ok ? 'allow' : 'deny',
    })
  }

  // ── attention ───────────────────────────────────────────────────────────────────────────────────

  snapshot(): AttentionRow[] { return this.attention.snapshot(this.deps.sessions(), this.deps.machineName()) }

  attentionPayload(): Record<string, unknown> {
    // Each agent carries the name of the first policy lane its name matches (planner, publisher ...),
    // so the bar and the device can show the role beside the state.
    const lanes = this.policy.lanes ?? []
    const agents = this.snapshot().map((row) => {
      const spent = this.ledger.agents[row.agentId]
      const cap = this.caps.enabled ? this.caps.perAgentUsd : null
      // Spend rides on the row so the bar can draw it as the ring's outer arc: fraction of the
      // per-agent cap when one is set, else null (no arc).
      const spend = spent ? { usd: Number(spent.usd.toFixed(2)), tokens: spent.input + spent.output, fraction: cap ? Math.min(1.5, spent.usd / cap) : null } : null
      return { ...row, lane: lanes.find((l) => { try { return new RegExp(l.agent, 'i').test(row.name) } catch { return false } })?.name ?? null, spend }
    })
    return { machineId: this.deps.machineId(), hostname: this.deps.machineName(), at: this.now(), summary: summarizeAttention(agents), agents, alerts: this.collisions.recent(), subscriptions: this.subs?.compact() ?? null }
  }

  private onAttentionChange(agentId: string, state: AttentionState, previous: AttentionState | null, detail: string): void {
    const payload = this.attentionPayload()
    this.deps.sendLocal({ type: 'attention', payload })
    this.pushFleet(payload)
    const row = (payload.agents as AttentionRow[]).find((r) => r.agentId === agentId)
    const name = row?.name ?? agentId
    this.log({ kind: 'turn', agentId, name: `attention ${previous ?? 'none'} -> ${state}`, detail })
    // Battery mode (the ten-year-old travel laptop): only permission and failure interrupt; a
    // waiting agent shows on the bar and the device but does not pop a notification.
    const onBattery = this.capsCache ? !this.capsCache.value.power.onAc : false
    if (state === 'permission' || state === 'failed' || (state === 'waiting' && !onBattery)) {
      const herdrPane = this.deps.sessions().find((s) => s.agentId === agentId)?.herdrPane ?? null
      void notifyAttention({ agentName: name, machine: this.deps.machineName(), state, detail, herdrPane }).catch(() => {})
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
    const session = this.deps.sessions().find((s) => s.agentId === agentId)
    const agentName = session?.name ?? ''
    // Every tool call is journaled and fed to the drift alarm, whatever the gate decides.
    this.log({ kind: 'tool', agentId, sessionId, name: toolName, detail: typeof input === 'object' && input ? JSON.stringify(input).slice(0, 300) : '' })
    this.collisions.noteTool({ agentId, agentName: agentName || agentId }, toolName, input, session?.cwd)
    const verdict = evaluateToolCall(this.policy, toolName, input, agentName)
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
    // Setting a cap is asking for the brake: the default is off (subscription users pay no list price).
    const setsCap = ['perAgentUsd', 'perAgentTokens', 'perDayUsd', 'perDayTokens'].some((k) => typeof (patch as Record<string, unknown>)[k] === 'number')
    const next = { ...this.caps, ...(setsCap && patch.enabled === undefined ? { enabled: true } : {}), ...patch, version: 1 as const }
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
    // The dial's panic face: every ring closes to one red dot.
    this.deps.toDial?.({ t: 'nixfred.panic', stopped: cancelled.length })
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
      case 'collisions': return { alerts: this.collisions.recent(), locks: this.collisions.listLocks() }
      case 'loops': {
        const leases = (await this.leases.list()).filter((l) => l.expiresAt > this.now())
        return { policy: this.loopPolicy, leases, capabilities: describeCapabilities(await this.capabilities()) }
      }
      case 'lock': {
        const s = session(str('agentId'))
        const holder = s ?? { agentId: 'person', name: this.deps.machineName() }
        const out = this.collisions.lock({ repo: str('repo'), branch: str('branch'), holderAgentId: holder.agentId, holderName: holder.name, machineId: this.deps.machineId() })
        if ('error' in out) throw new Error(out.error)
        this.saveLocks(); return out
      }
      case 'unlock': { const removed = this.collisions.unlock(str('repo'), str('branch')); this.saveLocks(); return { removed } }
      case 'locks': return { locks: this.collisions.listLocks() }
      case 'branches': await this.pollBranches(); return { alerts: this.collisions.recent() }
      case 'ci': return { wakes: await this.pollCi() }
      case 'dispatch': {
        const job: JobSpec = { machineId: str('machine'), brief: str('brief'), repo: str('repo'), engine: str('engine') || 'claude', branchName: str('branch') || `dispatch/${this.now().toString(36)}`, ...(str('dsh') ? { dsh: str('dsh') } : {}) }
        if (!job.brief || !job.repo || !str('machine')) throw new Error('dispatch needs machine, repo and brief')
        return this.dispatch(str('machine'), job)
      }
      case 'dispatches': return { dispatches: [...this.dispatches.values()].sort((a, b) => b.startedAt - a.startedAt) }
      case 'clip-push': {
        const file = args.file && typeof args.file === 'object' ? args.file as { name: string; base64: string } : undefined
        const text = typeof args.text === 'string' ? args.text : undefined
        if (!str('machine') || (!file && text === undefined)) throw new Error('clip-push needs machine and text or file')
        return this.clipPush(str('machine'), { ...(text !== undefined ? { text } : {}), ...(file ? { file } : {}) })
      }
      case 'clip-receive': return this.clipReceive({ text: typeof args.text === 'string' ? args.text : undefined, file: args.file && typeof args.file === 'object' ? args.file as { name: string; base64: string } : undefined, from: 'local' })
      case 'hermes-health': { const r = await hermesHealth(this.hermesDeps()); return { ...r, lines: describeHermesHealth(r) } }
      case 'subs': { const r = await this.subs.collect(args.force === true || args.force === 'true'); return { ...r, lines: describeSubscriptions(r) } }
      case 'subs-set': {
        const on = args.enabled === true || args.enabled === 'on' || args.enabled === 'true'
        await this.subs.setEnabled(str('id') as ProviderId, on)
        await this.pollSubscriptions(true)
        const r = await this.subs.collect()
        return { ...r, lines: describeSubscriptions(r) }
      }
      case 'hermes-doctor-done': return stampHermesDoctor(this.hermesDeps())
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
