/**
 * Agent Messages out of the core's process: in the edge host (`harness __service …,messages`, harnessd/services.ts),
 * or, under a master from before 2026-10-12, in a process of its own (`harness __service messages`) that the core
 * asks for as it starts. The same service as in the core's process (services/messages.ts, messages/service.ts), on
 * the core's API as a process reaches it (services/processCoreApi.ts), asking only what core/messagesLink.ts answers
 * it, and what a mailbox in another process needs besides:
 * - The core asks in line, as it writes a typed delivery, whether it may still be written. This process tells the
 *   core which may (`writable`), before each is handed over and whenever that can change, each for a few seconds
 *   at a time: a process that stops telling, hung or gone, leaves none writable, and a delivery waits rather than
 *   being written against its mailbox's word.
 * - The agents it reads as the apps are shown them, asked again as each request starts and whenever its
 *   mailbox reads them and they are a second old.
 * - Whether this daemon is signed in, as the core says it with its address: signed out, the service runs nothing.
 *   A core from before says nothing of it, and is taken as signed in, as the service took every core then.
 * - That the core's copy of the account's switch changed (`service_event` kind `settings`), which a core from before
 *   never says: off, the service then hears it only from the setting's file.
 */
import type { BackendNotice, DaemonAddress } from '../core/api.js'
import { startAgentMessages } from '../messages/service.js'
import { runServiceProcess, type CoreConnection, type ServiceProcess } from './process.js'
import { agentsIn, daemonIn, processCoreApi, type ShownAgent } from './processCoreApi.js'
import { turnsLink } from './turnsLink.js'

type Payload = Record<string, unknown>

/** How long a delivery the core is told may be written stays so without being told again. */
export const WRITABLE_FOR_MS = 3_000
/** How often what may be written is told again while any may: within this, a deadline passing is heard. */
export const WRITABLE_EVERY_MS = 1_000
/** The most deliveries this process watches the writing of. */
export const WATCHED = 1_000
/** How old the agents it read may be before its mailbox's next look asks again. */
export const AGENTS_FRESH_MS = 1_000

export interface MessagesServiceOptions {
  dataDir: string
  socketPath: string
  machineId: string
  token: string
  /** Swapped in tests for one that does not touch the real socket or process. */
  run?: typeof runServiceProcess
  /** Swapped in tests for a service that keeps nothing on disk and polls no account. */
  start?: typeof startAgentMessages
  now?: () => number
  setTimer?: (run: () => void, ms: number) => unknown
  clearTimer?: (timer: unknown) => void
}

export function runMessagesService(options: MessagesServiceOptions): ServiceProcess {
  const now = options.now ?? Date.now
  const setTimer = options.setTimer ?? ((run, ms) => { const timer = setInterval(run, ms); timer.unref?.(); return timer })
  const clearTimer = options.clearTimer ?? ((timer) => clearInterval(timer as ReturnType<typeof setInterval>))
  let core: CoreConnection | null = null
  let live: ShownAgent[] = []
  let readAt = -Infinity
  let daemon: DaemonAddress | null = null
  let signedIn = true
  let reading: Promise<void> | null = null
  const ask = (query: string, payload: Payload): Promise<Payload> =>
    core ? core.query(query, payload) : Promise.reject(new Error('not connected to the core'))
  const deliveries = turnsLink(ask)
  /** The agents as the core shows them now; once at a time. */
  const readAgents = (): Promise<void> => reading ??= ask('shown', {}).then((answer) => {
    live = (agentsIn(answer) as ShownAgent[] | null) ?? live
    readAt = now()
  }, () => {}).finally(() => { reading = null })
  /** The connection the daemon's address was last asked on. */
  let askedOn: CoreConnection | null = null
  /** What a request reads: the agents now, and how this daemon is run, asked once per connection. A core that
   *  cannot say leaves what the last one said. */
  const ready = async (): Promise<void> => {
    await readAgents()
    if (daemon && askedOn === core) return
    const on = core
    const answer = await ask('daemon', {}).catch(() => null)
    daemon = daemonIn(answer) ?? daemon
    if (typeof answer?.signedIn === 'boolean') signedIn = answer.signedIn
    askedOn = on
  }

  const noticeListeners = new Set<(notice: BackendNotice) => void>()
  /** The deliveries handed to the core, newest last: those whose writing this process watches. */
  const handed = new Set<string>()
  let told = ''
  let ticking: unknown = null

  const base = processCoreApi(options.dataDir, 'messages', {
    // Read in line by its mailbox's timer too: a copy a second old is asked for again, for its next look.
    live: () => { if (now() - readAt > AGENTS_FRESH_MS) void readAgents(); return live },
    ask, deliveries, daemon: () => daemon,
    onNotice: (listener) => { noticeListeners.add(listener); return () => { noticeListeners.delete(listener) } },
  })
  const api = {
    ...base,
    account: { ...base.account, signedIn: () => signedIn },
    turns: {
      ...base.turns,
      deliver: (agentId: string, text: string, deliveryId: string) => {
        // The core hears that it may write it before it is handed it, on the same link.
        handed.delete(deliveryId)
        handed.add(deliveryId)
        if (handed.size > WATCHED) handed.delete(handed.values().next().value!)
        tell()
        base.turns.deliver(agentId, text, deliveryId)
      },
      // Nothing is taken back in line here: a delivery the mailbox no longer wants is refused by `writable`.
      cancelDelivery: () => false,
    },
  }
  const build = () => (options.start ?? startAgentMessages)(api, { dataDir: options.dataDir, changed: () => tell() })
  let messages = build()
  /** The machine the running service was started under, and whether it was. */
  let builtFor: string | null = null
  let started = false
  /**
   * The service, started, for the machine this daemon serves as now. One started under another machine goes
   * and a new one starts: a sign-in starts a new core under the account's machine, and what the service
   * keeps is that machine's, while this process outlives the core it started under.
   */
  const current = () => {
    const machine = daemon?.machineId() ?? null
    if (machine === null) return messages
    if (started && builtFor !== machine) {
      messages.stop()
      messages = build()
      started = false
    }
    if (!started) {
      started = true
      builtFor = machine
      messages.start()
    }
    return messages
  }

  /** Tell the core which deliveries may be written now, when that changed or is due again; keep telling while any may. */
  function tell(): void {
    const until = now() + WRITABLE_FOR_MS
    const writable = [...handed].filter((id) => messages.canWrite(id))
    const said = JSON.stringify(writable)
    if (said !== told || writable.length) {
      told = said
      void ask('writable', { deliveries: Object.fromEntries(writable.map((id) => [id, until])) }).catch(() => {})
    }
    if (writable.length && !ticking) ticking = setTimer(tell, WRITABLE_EVERY_MS)
    if (!writable.length && ticking) { clearTimer(ticking); ticking = null }
  }

  const service = (options.run ?? runServiceProcess)({
    name: 'messages',
    socketPath: options.socketPath,
    machineId: options.machineId,
    token: options.token,
    requests: {
      agent_messages: async (payload, asker, closed) => { await ready(); return current().requests.agent_messages(payload, asker, closed) },
    },
    onEvent: (payload) => {
      if (deliveries.heard(payload)) { tell(); return }
      // The core's copy of the account's switch changed: the running service reads it again.
      if (payload.kind === 'settings') { if (started) messages.settingsChanged(); return }
      // Heard once the service runs for a known machine: the tabs it would read are that machine's.
      if (started && payload.kind === 'notice' && payload.notice && typeof payload.notice === 'object') {
        for (const listener of noticeListeners) listener(payload.notice as BackendNotice)
      }
    },
    onConnected: (connection) => {
      core = connection
      told = ''
      // Its queues resume once it knows the agents and the daemon, and the core hears what may be written.
      void ready().then(() => {
        // A core that restarted holds none of the typed attempts handed to the last one, and may be signed in or out.
        current().reconnected?.()
        tell()
      })
    },
    onDisconnected: () => { core = null },
  })
  return {
    stop: () => {
      if (ticking) clearTimer(ticking)
      ticking = null
      messages.stop()
      return service.stop()
    },
  }
}
