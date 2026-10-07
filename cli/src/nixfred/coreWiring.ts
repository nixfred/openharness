/**
 * The nixfred fork's daemon side, as the core's process runs it (upstream's harnessd re-architecture,
 * docs/design/2026-10-06-core-boundary-next.md).
 *
 * Before upstream split the daemon, all of this was inline in cli.ts `runForeground`. Upstream moved that
 * body into core/main.ts and then into core modules (input, questions, attach, the event funnel, turn
 * hooks, cancel) and services in their own processes, and holds `runForeground` to a line budget
 * (architecture.spec.ts). So the fork's wiring lives here, built by one call from runForeground, and
 * reaches the core modules only through the optional dependencies the fork added to them:
 *
 * - core/input.ts `externalPrompt` (a typed or spoken prompt for an Orca row goes into its Orca terminal)
 *   and `brake` (the spend cap, then the loop policy, before anything is typed);
 * - core/questions.ts `route` (a dialog on an Orca row is read and answered in its Orca terminal) and
 *   `attention` (a question asked, a permission prompt, an answer);
 * - core/transcripts/attach.ts: a hosted row attaches without a terminal, and Hermes finds a late profile;
 * - the event funnel and the turn hooks, wrapped in core/main.ts: attention follows every turn, and the
 *   destructive-action gate answers each tool start.
 *
 * The dial's `nixfred.*` frames go to the devices through their port (core/api.ts `DevicesPort.nixfred`),
 * wherever the devices run. `clip_push` is a request served through the service host, in this process,
 * beside the shell service (nixfred/clipPush.ts).
 *
 * Fork-only: upstream closed autonomous-ai/openharness#621 (watch mode) as not planned.
 */
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { GateVerdict } from '../lib/actionPolicy.js'
import type { AskQuestionDeps, QuestionAnswerPayload, QuestionAnswerResult } from '../lib/askQuestion.js'
import { agentTokenUsage } from '../lib/agentTokenUsage.js'
import { isRecentlyDeleted } from '../lib/deletedSessions.js'
import { transcriptIsFirstTurn } from '../lib/firstTurnReplay.js'
import { HermesSessionBackend, hermesSessionBackendConfig } from '../lib/hermesSessionBackend.js'
import { sid } from '../lib/log.js'
import { projectDisplayName, registry, type RegisteredSession } from '../lib/registry.js'
import type { ServiceRequests, WindowRelay } from '../core/api.js'
import { statBirthMs } from '../core/agents/bind.js'
import { Nixfred, type NixfredSessionLike } from '../nixfredWiring.js'
import { CLIP_REQUESTS, clipPushRequest } from './clipPush.js'
import { discoverOrcaClaudes, transcriptAgeSec } from './orcaDiscovery.js'
import {
  ExternalCaptureGate, ExternalTerminalRouter, OrcaCli, applyOrcaWatchSwitch, attentionForExternalEvent, engineStillRunning,
  findEngineAncestor, findOrcaBin, notificationOpensDialog, parseExternalHook, readOrcaWatchConfig, type OrcaSwitch,
} from './orcaWatch.js'

export { CLIP_REQUESTS }

type Frame = { type: string; payload: Record<string, unknown> }
type LiveEvent = { type: string; payload: Record<string, unknown> }
type AnswerDeps = Pick<AskQuestionDeps, 'capture' | 'sendText' | 'sendKey' | 'acquireControl'>

/** What the fork reads of the core. Every member is called late (never while this is being built), so
 *  core/main.ts may hand over pieces it declares further down. */
export interface NixfredCoreDeps {
  dataDir: string
  machineId: () => string
  machineName: () => string
  agentIdFor: (sessionId: string) => string
  /** The windows on this computer (`backend.sendLocal`) and the app's frames (`backend.send`). */
  sendLocal: (frame: Frame) => void
  send: (frame: Frame & { agentId?: string; dbSessionId?: string }) => void
  cancelAgent: (agentId: string, confirmed: boolean) => Promise<boolean>
  submitAgent: (agentId: string, text: string) => void
  hookPort: () => number
  /** A `nixfred.*` frame for every plugged-in dial, through the devices' port. */
  toDial: (msg: { t: string; [key: string]: unknown }) => void
  /** The stock pane functions an Orca router falls back to for every pane-backed row. */
  terminal: AnswerDeps
  attachSession: (session: RegisteredSession, reset?: boolean, replayCursorFromStart?: boolean, replayFromStart?: boolean) => Promise<boolean>
  syncRecapPool: () => void
  announceSession: (session: RegisteredSession) => void
  questionWatcher: () => { start(sessionId: string): void; stop(sessionId: string): void }
  openQuestion: (sessionId: string) => Record<string, unknown> | undefined
  answerQuestion: (payload: QuestionAnswerPayload) => Promise<QuestionAnswerResult>
  showAwaitingAnswer: (sessionId: string) => void
  /** The Hermes readers and turn states (core/transcripts/normalizers.ts), for a hosted row that retires. */
  hermes: () => { readers: Map<string, { stop(): void }>; turnStates: Map<string, unknown> }
  /** The gateway's sessions to the owner's other machines (`gateway.windowRelay`), for the dispatcher. */
  relay: () => Pick<WindowRelay, 'acquire'>
  autonomousEnv: () => string
}

export function nixfredSession(s: RegisteredSession): NixfredSessionLike {
  return {
    agentId: s.agentId, sessionId: s.sessionId, engine: s.engine, active: s.active, tmuxPane: s.tmuxPane,
    cwd: s.cwd ?? undefined, transcriptPath: s.transcriptPath ?? undefined, model: (s as { model?: string | null }).model ?? null, name: projectDisplayName(s),
    external: s.hosted === 'external',
  }
}

export function createNixfredCore(deps: NixfredCoreDeps) {
  const nixfred = new Nixfred({
    dataDir: deps.dataDir,
    machineId: () => deps.machineId(),
    machineName: () => deps.machineName(),
    sessions: () => registry.advertised().map(nixfredSession),
    sendLocal: (frame) => deps.sendLocal(frame),
    sendError: (agentId, dbSessionId, message) => deps.send({ type: 'error', agentId, dbSessionId, payload: { message } }),
    cancelAgent: (agentId, confirmed) => deps.cancelAgent(agentId, confirmed),
    tokenUsage: (s) => { const r = registry.resolve(s.agentId); return r ? agentTokenUsage.get(r) : null },
    hookPort: () => deps.hookPort(),
    sendToAgent: (agentId, text) => deps.submitAgent(agentId, text),
    toDial: (msg) => deps.toDial(msg),
  })

  // ── watch mode: sessions this daemon did not start become external rows (orcaWatch.ts) ─────────────
  // An answer to one of them is typed into its Orca terminal. Every pane-backed row goes straight through to
  // the stock functions, unchanged. The router is handed ONLY to the answer controller and the question
  // watcher (core/questions.ts `route`), so nothing else can type into an Orca terminal.
  let orcaWatch = readOrcaWatchConfig(deps.dataDir)
  const orcaCli = new OrcaCli({ bin: findOrcaBin() })
  const externalTerminals = new ExternalTerminalRouter({
    resolve: (id) => registry.resolve(id),
    orca: orcaCli,
    answersEnabled: () => orcaWatch.enabled && orcaWatch.answers,
    gate: new ExternalCaptureGate({ idleCaptureMs: orcaWatch.idleCaptureMs }),
    fallback: deps.terminal,
    audit: (entry) => {
      console.log(`[orca] ${sid(entry.agentId)} answer ${entry.what} via ${entry.route} · ${entry.ok ? 'delivered' : 'NOT delivered'}`)
      nixfred.auditAnswer(entry)
    },
  })

  // A typed or spoken prompt (dial voice, app) for an Orca row goes into its Orca terminal, then Enter.
  // Same switch as answers: watch mode on and answers on. Every send is audited.
  const externalPrompt = async (session: RegisteredSession, text: string): Promise<boolean> => {
    const terminal = session.external?.orca?.terminal
    if (!terminal || !(orcaWatch.enabled && orcaWatch.answers)) return false
    const ok = (await orcaCli.send(terminal, text)) && (await orcaCli.send(terminal, '\r'))
    nixfred.auditAnswer({ agentId: session.agentId, sessionId: session.sessionId ?? '', route: 'orca', what: 'prompt', value: text.slice(0, 200), ok, terminal })
    return ok
  }

  // The brakes, in order: spend cap (pauses the pane and tells the web why), then the loop policy (battery,
  // lid, busy GPU, quiet hours, fleet lease).
  const brake = async (session: RegisteredSession, text: string): Promise<boolean> => {
    const like = nixfredSession(session)
    if (nixfred.spendCheck(like).action === 'pause') return false
    const loop = await nixfred.loopCheck(like, text)
    if (!loop.run) { console.log(`[msg] ${sid(session.sessionId || session.agentId)} held: ${loop.reason}`); return false }
    return true
  }

  // ── external rows from hooks ─────────────────────────────────────────────────────────────────────
  // Attached and announced like the Hermes hosted rows, NOT through the binding path: that path saves the
  // row as a stopped agent, which would let the app later "resume" it into a pane of ours (a move).
  const attachExternal = async (row: RegisteredSession, reset: boolean, hookEvent: string): Promise<void> => {
    const firstTurn = !!row.transcriptPath && transcriptIsFirstTurn(row, await statBirthMs(row.transcriptPath), { rebound: false, now: Date.now() })
    const attached = await deps.attachSession(row, reset, false, firstTurn)
    deps.syncRecapPool()
    deps.announceSession(row)
    if (reset) deps.send({ type: 'session_synced', payload: { sessionId: row.sessionId, agentId: row.agentId, title: projectDisplayName(row), createdAt: new Date(row.boundAt ?? Date.now()).toISOString() } })
    console.log(`[orca] ${sid(row.agentId)} external ${row.engine} ${hookEvent} · attached=${attached} · orca=${row.external?.orca?.terminal ?? 'none'} · cwd=${row.cwd ?? '?'}`)
  }
  const endExternal = (row: RegisteredSession, why: string): void => {
    if (!row.active) return
    registry.setActive(row.agentId, false)
    deps.questionWatcher().stop(row.sessionId)
    externalTerminals.gate.forget(row.sessionId)
    nixfred.attention.offline(row.agentId)
    deps.syncRecapPool()
    deps.announceSession(row)
    console.log(`[orca] ${sid(row.agentId)} external session ended · ${why}`)
  }
  const hooklessExternal = new Set<string>()
  const handleExternalHook = async (raw: unknown): Promise<Record<string, unknown>> => {
    if (!orcaWatch.enabled) return { ignored: true, reason: 'watch_mode_off' }
    const parsed = parseExternalHook(raw)
    if (!parsed.ok) { console.log(`[orca] external hook ignored · ${parsed.reason}`); return { ignored: true, reason: parsed.reason } }
    const e = parsed.event
    if (isRecentlyDeleted(e.sessionId)) return { ignored: true, reason: 'deleted' }
    const existing = registry.bySession(e.sessionId)
    if (existing && existing.hosted !== 'external') return { ignored: true, reason: 'owned_by_this_daemon' }
    if (e.event === 'SessionEnd') {
      if (existing) endExternal(existing, 'SessionEnd hook')
      return { ok: true, ended: !!existing }
    }
    const hadTranscript = existing?.transcriptPath ?? null
    const out = registry.registerExternal({
      engine: e.engine, sessionId: e.sessionId, cwd: e.cwd, title: e.title, transcriptPath: e.transcriptPath,
      codexHome: e.codexHome, model: e.model, orca: e.orca,
      proc: e.callerPid ? findEngineAncestor(e.callerPid, e.engine) : null,
    })
    if (!out) return { ignored: true, reason: 'not_registered' }
    const row = registry.byAgent(out.agentId)
    if (!row) return { ignored: true, reason: 'not_registered' }
    if (out.isNew || out.reactivated || (!hadTranscript && row.transcriptPath)) await attachExternal(row, true, e.event)
    else if (e.event === 'SessionStart') await attachExternal(row, true, e.event)
    // A dialog is open: read the Orca screen fresh until it is answered or the turn moves on.
    if (notificationOpensDialog(e)) { externalTerminals.gate.hint(row.sessionId); deps.questionWatcher().start(row.sessionId) }
    if (e.event === 'UserPromptSubmit' || e.event === 'Stop' || e.event === 'StopFailure') externalTerminals.gate.clear(row.sessionId)
    if (e.event === 'UserPromptSubmit') deps.questionWatcher().start(row.sessionId)
    const attention = attentionForExternalEvent(e)
    if (attention) nixfred.attention.set(row.agentId, attention.state, attention.detail)
    if (e.event !== 'SessionStart') hooklessExternal.delete(row.agentId)
    return { ok: true, agentId: row.agentId, isNew: out.isNew }
  }

  // Orca Claudes that never sent a hook (started before the hook was installed, or the daemon restarted
  // since), registered through the same path as a hook (orcaDiscovery.ts).
  const discoverExternal = async (): Promise<void> => {
    if (!orcaWatch.enabled) return
    const claudeHome = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude')
    for (const d of discoverOrcaClaudes(claudeHome)) {
      const existing = registry.bySession(d.sessionId)
      if (existing && existing.active) {
        if (hooklessExternal.has(existing.agentId)) {
          const age = transcriptAgeSec(existing.transcriptPath ?? d.transcriptPath)
          const cur = nixfred.attention.get(existing.agentId)?.state
          if (age !== null && age < 15 && cur !== 'working' && cur !== 'waiting' && cur !== 'permission') nixfred.attention.set(existing.agentId, 'working', '')
          else if (age !== null && age >= 15 && cur === 'working') nixfred.attention.set(existing.agentId, 'done', '')
        }
        continue
      }
      const res = await handleExternalHook({ engine: 'claude', event: 'SessionStart', sessionId: d.sessionId, cwd: d.cwd, transcriptPath: d.transcriptPath, callerPid: d.pid, orca: d.orca })
      if (res.ok && typeof res.agentId === 'string') {
        hooklessExternal.add(res.agentId)
        console.log(`[orca] ${sid(res.agentId)} discovered claude (no hook yet) · orca=${d.orca?.terminal ?? '-'} · cwd=${d.cwd ?? '?'}`)
      }
    }
  }

  const orcaStatus = (): Record<string, unknown> => ({
    ...orcaWatch,
    orcaCli: orcaCli.available,
    rows: registry.hostedList('external').map((r) => ({
      agentId: r.agentId, sessionId: r.sessionId, engine: r.engine, active: r.active, name: projectDisplayName(r), cwd: r.cwd,
      orcaTerminal: r.external?.orca?.terminal ?? null, orcaWorktree: r.external?.orca?.worktree ?? null,
      state: nixfred.attention.get(r.agentId)?.state ?? (r.active ? 'idle' : 'offline'),
    })),
  })
  const command = async (action: string, args: Record<string, unknown>): Promise<unknown> => {
    if (action === 'orca-status') return orcaStatus()
    if (action === 'orca-set') {
      const change = String(args.change ?? '') as OrcaSwitch
      if (!['on', 'off', 'answers-on', 'answers-off'].includes(change)) throw new Error('orca-set needs change=on|off|answers-on|answers-off')
      orcaWatch = applyOrcaWatchSwitch(deps.dataDir, change)
      externalTerminals.gate.setIdleCaptureMs(orcaWatch.idleCaptureMs)
      if (!orcaWatch.enabled) for (const row of registry.hostedList('external')) endExternal(row, 'watch mode switched off')
      console.log(`[orca] watch mode ${orcaWatch.enabled ? 'ON' : 'OFF'} · answers ${orcaWatch.answers ? 'ON' : 'OFF'} (${orcaWatch.source})`)
      return orcaStatus()
    }
    if (action === 'orca-answer') {
      // An explicit answer typed at this computer: `harness orca answer <agent> <option>`. Same controller,
      // same stale-dialog check, same audit line as an answer from the device or the app.
      const target = String(args.agentId ?? '')
      const row = registry.resolve(target)
      if (!row) throw new Error(`no agent ${target}`)
      const open = deps.openQuestion(row.sessionId) as { payload?: { requestId?: string; questions?: Array<{ key: string; q: string; options: string[] }> } } | undefined
      const requestId = open?.payload?.requestId
      const q = open?.payload?.questions?.[0]
      if (!requestId || !q) throw new Error('that agent has no open question right now')
      // "2" means the second option; anything else is matched as the option's label (or free text).
      const raw = String(args.answer ?? '').trim()
      const picked = /^\d+$/.test(raw) && q.options[Number(raw) - 1] !== undefined ? q.options[Number(raw) - 1]! : raw
      if (!picked) throw new Error(`answer with a number 1-${q.options.length} or an option label: ${q.options.join(' | ')}`)
      deps.showAwaitingAnswer(row.sessionId)
      nixfred.attention.answered(row.agentId)
      const result = await deps.answerQuestion({ agentId: row.agentId, sessionId: row.sessionId, requestId, answers: { [q.key]: picked } })
      return { question: q.q, answer: picked, ...result }
    }
    return nixfred.command(action, args)
  }

  return {
    nixfred,
    externalPrompt,
    brake,
    /** core/questions.ts `route`. */
    route: { answer: externalTerminals.answerDeps, watcherCapture: (target: string, lines?: number) => externalTerminals.watcherCapture(target, lines) },
    /** core/questions.ts `attention`. */
    questionAttention: {
      asked: (sessionId: string, permission: boolean, question: string) => nixfred.attention.question(deps.agentIdFor(sessionId), permission, question),
      answered: (target: string) => nixfred.attention.answered(deps.agentIdFor(target)),
    },
    /** What the event funnel delivered: attention follows every live turn, never a replay. */
    observe(sessionId: string, events: LiveEvent[], opts?: { resumed?: boolean; replay?: boolean }): void {
      if (opts?.resumed || opts?.replay || !registry.bySession(sessionId)?.active) return
      const agentId = deps.agentIdFor(sessionId)
      for (const event of events) {
        if (event.type === 'turn_started') nixfred.attention.turnStarted(agentId, String(event.payload.userMessage ?? ''))
        else if (event.type === 'turn_ended') nixfred.attention.turnEnded(agentId, { aborted: event.payload.aborted === true })
      }
    },
    /** A turn that died inside its engine (the funnel's announceTurnAborted). */
    aborted: (sessionId: string, message: string): void => nixfred.attention.failed(deps.agentIdFor(sessionId), message),
    cancelled: (id: string): void => nixfred.attention.cancelled(registry.resolve(id)?.agentId ?? id),
    seen: (agentId: string): void => nixfred.attention.seen(agentId),
    /** The destructive-action gate: the verdict rides back to the hook script, which turns ask/deny into the
     *  engine's own permission prompt. */
    toolStart: (body: { sessionId: string; toolName: string; input: unknown }): GateVerdict =>
      nixfred.gate(body.sessionId, deps.agentIdFor(body.sessionId), body.toolName, body.input),
    turnStop: (body: { sessionId: string; status?: string }): void => {
      const session = registry.resolve(body.sessionId)
      if (session && body.status === 'error') nixfred.attention.failed(session.agentId, 'engine ended the turn with an error')
    },
    /** The hook server's nixfred routes (hookServer.ts). */
    hookHandlers: {
      onExternalHook: handleExternalHook,
      onAttention: () => nixfred.attentionPayload(),
      onSubscriptions: () => nixfred.subs.collect(),
      onStopAll: (except: string | null) => nixfred.stopAll(except),
      onAdopt: (pane: string, engine: string | null) => nixfred.adopt(pane, engine),
      onNixfred: (action: string, args: Record<string, unknown>) => command(action, args),
    },
    /** `clip_push`, for the service host (nixfred/clipPush.ts). */
    clipRequests: (): ServiceRequests => ({ clip_push: (payload, asker) => clipPushRequest(payload, asker, (push) => nixfred.clipReceive(push)) }),
    /** Everything that runs on its own, started once the core is up. */
    start(): void {
      // A session that simply exits (terminal closed, no SessionEnd) goes offline when its engine process is
      // gone. Checked against the process start time, so a reused pid cannot keep a dead row alive.
      setInterval(() => {
        for (const row of registry.hostedList('external')) {
          const proc = row.external?.proc
          if (row.active && proc && !engineStillRunning(proc)) endExternal(row, 'engine process exited')
        }
      }, 20_000).unref?.()
      setInterval(() => { void discoverExternal().catch(() => {}) }, 10_000).unref?.()
      setTimeout(() => { void discoverExternal().catch(() => {}) }, 3_000).unref?.()
      console.log(`[orca] watch mode ${orcaWatch.enabled ? 'ON' : 'OFF'} · answers ${orcaWatch.answers ? 'ON' : 'OFF'} (${orcaWatch.source}) · orca CLI ${orcaCli.available ? 'found' : 'not found'}`)

      // The fleet dispatcher rides the gateway's sessions to the owner's other machines (the pool a window
      // uses): one E2EE-terminated session per machine, frames fanned out to whoever attached.
      nixfred.setRelayLink(async (machineId) => {
        const listeners = new Set<(frame: { type: string; payload: Record<string, unknown> }) => void>()
        const sink = {
          sendFrame: (frame: Record<string, unknown>) => {
            const payload = (frame.payload && typeof frame.payload === 'object' ? frame.payload : {}) as Record<string, unknown>
            // The event correlator puts agentId on the frame and in the payload; keep it reachable either way.
            const shaped = { type: String(frame.type ?? ''), payload: typeof frame.agentId === 'string' && !payload.agentId ? { ...payload, agentId: frame.agentId } : payload }
            for (const cb of listeners) cb(shaped)
            return true
          },
          sendBinary: () => true,
        }
        const session = await deps.relay().acquire(machineId, deps.autonomousEnv(), { type: 'machine_select', payload: { machineId } }, sink, () => { listeners.clear() })
        return {
          send: (frame) => session.send(frame as unknown as Record<string, unknown>),
          onFrame: (cb) => { listeners.add(cb); return () => { listeners.delete(cb) } },
          close: () => session.detach(),
        }
      })

      // Hermes sessions with no pane (Desktop bots, Bot Mode profiles, gateway): read off every Hermes store
      // and registered as hosted rows, so the whole fleet is on the roster, not just tmux panes. Off with
      // HARNESS_HERMES_SESSIONS=0. A hosted row cannot be typed into from here (no terminal); its turns still
      // stream through the same HermesReader a pane-backed session uses.
      const hermesHosted = hermesSessionBackendConfig()
      if (!hermesHosted.enabled) { console.log('[hermes-store] disabled (HARNESS_HERMES_SESSIONS=0)'); return }
      const hermesStore = new HermesSessionBackend({
        registry,
        idleMs: hermesHosted.idleMs,
        log: (line) => console.log(line),
        onNew: (agentId) => {
          const row = registry.byAgent(agentId)
          if (!row) return
          void deps.attachSession(row).then((attached) => {
            if (!attached) { registry.setActive(agentId, false); return }
            deps.syncRecapPool()
            deps.announceSession(row)
          }).catch((err) => console.error(`[hermes-store] ${sid(agentId)} attach failed:`, err instanceof Error ? err.message : err))
        },
        onRetired: (agentId, sessionId) => {
          const { readers } = deps.hermes()
          readers.get(sessionId)?.stop()
          readers.delete(sessionId)
          const row = registry.byAgent(agentId)
          if (row) deps.announceSession(row)
          console.log(`[hermes-store] ${sid(agentId)} dormant · idle past the window`)
        },
        onVanished: (agentId, sessionId) => {
          const { readers, turnStates } = deps.hermes()
          readers.get(sessionId)?.stop()
          readers.delete(sessionId)
          turnStates.delete(sessionId)
          deps.syncRecapPool()
          console.log(`[hermes-store] ${sid(agentId)} forgotten · gone from every store`)
        },
      })
      hermesStore.start()
      console.log(`[hermes-store] watching every Hermes home for paneless sessions · idle window ${Math.round(hermesHosted.idleMs / 60000)} min`)
    },
  }
}

export type NixfredCore = ReturnType<typeof createNixfredCore>
