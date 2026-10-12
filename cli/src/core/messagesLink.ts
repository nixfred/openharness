/**
 * Agent Messages in a process of its own, as the core sees it (the process's side is services/messagesProcess.ts). It
 * runs in the edge host since 2026-10-12; a master from before runs it in a process of its own, on demand, which this
 * core asks for as it starts (`askForMessages`).
 *
 * - Which of its typed deliveries may be written now. The core asks in line, as it writes a `team:` delivery into
 *   an idle agent's pane (core/input.ts), and never calls into the process or waits on it for that. The process
 *   tells the core instead (`writable`): each delivery it still wants written, until a deadline a few seconds off,
 *   told again while it may. A process that stops telling, hung or gone, leaves none writable, and a delivery
 *   waits rather than being written against its mailbox's word.
 * - What it may ask of the core, and no more (core/api.ts `MESSAGES_QUERIES`). As an experiment it could ask for
 *   anything an experiment acts on the core through (core/experimentQueries.ts); as a service it is given what it
 *   uses: the agents as the apps are shown them, how this daemon is reached and whether it is signed in, the one
 *   backend read of the account's tabs, and its log's change notice for the windows. Writing turns into agents is
 *   core/deliveries.ts's to allow (`TURN_DELIVERERS`).
 * - The account's `desk_changed`, told as the backend announces it: its tabs are read again then.
 * - That its switch changed here (`MessagesPort.settingsChanged`): the core's sync of the account's experiments tells
 *   it (core/experiments.ts `createAgentSettingsSync`), so that turning it on wakes it.
 */
import { MESSAGES_BACKEND_PATH, MESSAGES_WINDOW_FRAME, type BackendNotice, type CoreApi, type MessagesPort } from './api.js'
import { daemonAddress, shownAgents } from './experimentQueries.js'

type Payload = Record<string, unknown>

export interface MessagesLinkDeps {
  core: Pick<CoreApi, 'agents' | 'daemon' | 'account' | 'clients'>
  /** Tell the process something (core/serviceLinks.ts `notify`, for `messages`); false when it is not connected. */
  notify(frame: { type: string; payload: Payload }): boolean
  now?: () => number
}

export function createMessagesLink(deps: MessagesLinkDeps) {
  const now = deps.now ?? Date.now
  const { core } = deps
  /** Each delivery the process says may be written now, and until when. */
  let writable = new Map<string, number>()
  const port: MessagesPort = {
    canWrite: (deliveryId) => (writable.get(deliveryId) ?? 0) > now(),
    // Told, never asked: a process that is down reads the file as it starts anyway.
    settingsChanged: () => { deps.notify({ type: 'service_event', payload: { kind: 'settings' } }) },
  }
  return {
    port,
    /** The core's answers to the process's questions (core/serviceLinks.ts `answer`, for `messages`): those in
     *  `MESSAGES_QUERIES`, each checked, and `UNKNOWN_QUERY` for any other. */
    answer(query: string, payload: Payload): Payload | Promise<Payload> {
      switch (query) {
        case 'writable': {
          const reported = payload.deliveries && typeof payload.deliveries === 'object' ? payload.deliveries as Payload : {}
          writable = new Map(Object.entries(reported).flatMap(([id, until]) => (typeof until === 'number' ? [[id, until] as const] : [])))
          return {}
        }
        case 'shown':
          return shownAgents(core)
        // Signed out, it reads no tabs and runs no timer: there is no account to read them from (messages/service.ts).
        case 'daemon':
          return { ...daemonAddress(core), signedIn: core.account.signedIn() }
        case 'backend':
          if (payload.method !== 'GET' || payload.path !== MESSAGES_BACKEND_PATH) return { error: 'INVALID_REQUEST' }
          return core.account.backend('GET', MESSAGES_BACKEND_PATH).then((answer) => ({ ...answer }))
        case 'windows': {
          const frame = payload.frame as Payload | undefined
          // Its log changed, and nothing else: what the windows hear from the core itself is the core's to say.
          if (frame?.type !== MESSAGES_WINDOW_FRAME || !frame.payload || typeof frame.payload !== 'object') return { error: 'INVALID_FRAME' }
          core.clients.windows({ type: MESSAGES_WINDOW_FRAME, payload: frame.payload as Payload })
          return {}
        }
        default:
          return { error: 'UNKNOWN_QUERY' }
      }
    },
    /** The backend announced a change to the account: the desk's is the one Agent Messages reads its tabs again for. */
    notice(notice: BackendNotice): void {
      if (notice.type === 'desk_changed') deps.notify({ type: 'service_event', payload: { kind: 'notice', notice } })
    },
  }
}

/**
 * Ask the master for Agent Messages as the core starts, when it runs out of the core's process. This build's master
 * runs it in the edge host, which is always running, so the ask starts nothing. A master from before runs it in a
 * process of its own that starts only when asked: a core is left under one when that master could not re-execute on
 * the update (harnessd/reexec.ts), and without the ask no agent would get its note, and no waiting message would
 * move, until a request came. Asked whether it is on or off: off, it runs no timer either way (messages/service.ts).
 */
export function askForMessages(outOfProcess: ReadonlySet<string>, want: (service: string) => void): boolean {
  if (!outOfProcess.has('messages')) return false
  want('messages')
  return true
}
