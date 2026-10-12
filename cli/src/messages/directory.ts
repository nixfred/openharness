/**
 * Who may message whom (docs/design/2026-10-10-agent-messages.md, "Who may message whom"): the account's
 * desk tabs, each with its owned panes, read from the backend (`GET /api/agent-messages`). A message goes only
 * between harnesses that share a tab, while the account has Agent Messages on (Settings ▸ Experimental, off by default).
 * Each tab's own flag, which the backend still answers for older windows, is not read: the tab's switch was a chat
 * icon beside its × that was easy to hit by mistake, and the owner made it one setting of the account (2026-10-12).
 *
 * Read every 15 seconds while this computer is signed in with Agent Messages on (`start`, `stop`: service.ts runs it
 * only then), again on the account's `desk_changed`, and fresh before a send. An unreadable directory never clears
 * what was read: a failed read keeps the last one, and before any read nothing may be sent.
 */

export interface Member { machineId: string; agentId: string }
/** `named`: the person named the tab; any other is labelled by the windows themselves (backend lib/agentMessages.ts). */
export interface DirectoryTab { id: string; name: string; named: boolean; panes: Member[] }
export interface Directory { revision: number; machines: ReadonlyMap<string, string | null>; tabs: DirectoryTab[] }

export const POLL_MS = 15_000
/** A read this recent is fresh enough for a send. */
export const FRESH_MS = 2_000

const str = (value: unknown, max: number): string | null => (typeof value === 'string' && value && value.length <= max ? value : null)

/** The backend's answer, checked; null when it is not one. */
export function parseDirectory(value: unknown): Directory | null {
  const v = value as Record<string, unknown> | null
  if (!v || typeof v !== 'object' || !Array.isArray(v.tabs)) return null
  const machines = new Map<string, string | null>()
  for (const m of Array.isArray(v.machines) ? v.machines as Record<string, unknown>[] : []) {
    const id = str(m?.machineId, 128)
    if (id) machines.set(id, str(m.name, 200))
  }
  const tabs: DirectoryTab[] = []
  for (const t of v.tabs as Record<string, unknown>[]) {
    const id = str(t?.id, 64), name = str(t?.name, 200)
    if (!id || name === null || !Array.isArray(t.panes)) continue
    const panes = (t.panes as Record<string, unknown>[]).flatMap((p) => {
      const machineId = str(p?.machineId, 128), agentId = str(p?.agentId, 160)
      return machineId && agentId ? [{ machineId, agentId }] : []
    })
    // A backend from before `named` says nothing: then only the window's own default name is no name.
    tabs.push({ id, name, named: typeof t.named === 'boolean' ? t.named : name !== 'New Tab', panes })
  }
  return { revision: typeof v.revision === 'number' ? v.revision : 0, machines, tabs }
}

const same = (a: Member, b: Member): boolean => a.machineId === b.machineId && a.agentId === b.agentId

export interface DirectoryDeps {
  read(): Promise<unknown>
  /** The directory changed: deliveries and notes may need another look. */
  changed?(): void
  /** Whether Agent Messages are on, as this computer keeps the account's experiment; on when not said. */
  on?(): boolean
  now?(): number
}

export class MessageDirectory {
  private value: Directory | null = null
  private readAt = -Infinity
  private reading: Promise<Directory | null> | null = null
  private timer: ReturnType<typeof setInterval> | null = null
  private wasOn = true
  constructor(private readonly deps: DirectoryDeps) {}
  private now(): number { return this.deps.now?.() ?? Date.now() }

  current(): Directory | null { return this.value }

  /** Whether this computer has Agent Messages on: off, no tab carries a message. */
  on(): boolean { return this.deps.on?.() ?? true }

  /** The directory, read again unless the last read is fresh; a failed read keeps the last one. */
  refresh(force = false): Promise<Directory | null> {
    if (!force && this.value && this.now() - this.readAt < FRESH_MS) return Promise.resolve(this.value)
    return this.reading ??= this.deps.read().then((raw) => {
      const next = parseDirectory(raw)
      if (next) {
        // The setting counts as part of what was read: turned on or off, deliveries and notes get another look.
        const before = JSON.stringify(this.value ? [this.value.revision, this.value.tabs, this.wasOn] : null)
        this.value = next
        this.wasOn = this.on()
        this.readAt = this.now()
        if (JSON.stringify([next.revision, next.tabs, this.wasOn]) !== before) this.deps.changed?.()
      }
      return this.value
    }, () => this.value).finally(() => { this.reading = null })
  }

  start(): void {
    if (this.timer) return
    void this.refresh(true)
    this.timer = setInterval(() => { void this.refresh(true) }, POLL_MS)
    this.timer.unref?.()
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  /** The tabs a harness is in, while Agent Messages are on; none while they are off. */
  tabsOf(member: Member): DirectoryTab[] {
    if (!this.on()) return []
    return (this.value?.tabs ?? []).filter((tab) => tab.panes.some((p) => same(p, member)))
  }

  /** The first tab two harnesses share while Agent Messages are on, or null. */
  shared(a: Member, b: Member): DirectoryTab | null {
    return this.tabsOf(a).find((tab) => tab.panes.some((p) => same(p, b))) ?? null
  }

  /** Everyone a harness may message: the other members of its tabs, once each, while Agent Messages are on. */
  peers(member: Member): Member[] {
    const out: Member[] = []
    for (const tab of this.tabsOf(member)) {
      for (const pane of tab.panes) if (!same(pane, member) && !out.some((p) => same(p, pane))) out.push(pane)
    }
    return out
  }

  machineName(machineId: string): string | null {
    return this.value?.machines.get(machineId) ?? null
  }
}
