/**
 * How `harness` shows the account's devices: the order, the "last active" wording, and the lines of
 * `devices list|show` and the `status` row. Pure — the clock is passed in — so the same rules the
 * desktop and mobile apps follow (their `relative_time.dart`) are pinned by one spec here.
 */
import type { DevLogFile } from './deviceLogStore.js'
import type { DeviceLogListing } from './deviceLogSyncer.js'

/** The fields of a listing row this module reads. `seq` (log position) and `firstSeen` (when this
 *  machine first applied the add) are the two a device cannot choose for itself; both optional so a
 *  daemon that predates them still lists, just without `new`. */
export type DeviceRow = Pick<DeviceLogListing['members'][number], 'pub' | 'label' | 'machineId' | 'addedAt' | 'fingerprint' | 'self'> & {
  kind: string
  seq?: number
  firstSeen?: number
}

const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR
/** A device seen this recently reads as "active now" rather than "5 minutes ago". */
const ACTIVE_NOW_MS = 5 * MIN
/** A device this machine first learned of this recently, that is not this machine, is flagged `new`. */
const NEW_DEVICE_MS = 7 * DAY

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/** What to do to check a device's key code. Shown under `devices show`. */
export const COMPARE_HINT =
  'To check it is really that device: open Your devices on it — the code under "This device" must match. On a computer, `harness status` shows it too.'

const plural = (n: number, unit: string): string => `${n} ${unit}${n === 1 ? '' : 's'} ago`

/** "2 days ago". Coarse on purpose: the person is deciding "do I recognise this", not auditing a log. */
export function relativeAgo(at: number, now: number): string {
  const d = Math.max(0, now - at)
  if (d < MIN) return 'just now'
  if (d < HOUR) return plural(Math.floor(d / MIN), 'minute')
  if (d < DAY) return plural(Math.floor(d / HOUR), 'hour')
  if (d < 2 * DAY) return 'yesterday'
  const days = Math.floor(d / DAY)
  if (days < 14) return `${days} days ago`
  if (days < 60) return `${Math.floor(days / 7)} weeks ago`
  if (days < 365) return `${Math.floor(days / 30)} months ago`
  return 'over a year ago'
}

/** `1 Oct 2026, 14:05` in local time — spelled out so it reads the same in every locale. */
export function fullDateTime(at: number): string {
  const d = new Date(at)
  const pad = (n: number): string => String(n).padStart(2, '0')
  return `${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()}, ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

/** `active now` / `last active 2 days ago` / `added 3 weeks ago` (no session ever recorded for it). */
export function activityPhrase(lastSeen: number | undefined, addedAt: number, now: number): string {
  if (lastSeen === undefined) return `added ${relativeAgo(addedAt, now)}`
  return now - lastSeen < ACTIVE_NOW_MS ? 'active now' : `last active ${relativeAgo(lastSeen, now)}`
}

/** `new` rests on when THIS machine applied the add, never the entry's `at`: the adding device picks
 *  that itself, and a backdated one would hide exactly the device the flag is for. */
export function isNewDevice(row: Pick<DeviceRow, 'self' | 'firstSeen'>, now: number): boolean {
  return !row.self && row.firstSeen !== undefined && now - row.firstSeen < NEW_DEVICE_MS
}

/** Log order — the order devices were added, which only shifts when one is removed. The `#` of
 *  `list`, `show` and `remove` is the position here, so a number read from the list still names that
 *  device when activity reorders the display or a device is added before the person types it. */
export function logOrder<T extends DeviceRow>(members: T[]): T[] {
  return members.map((m, i) => ({ m, i })).sort((a, b) => (a.m.seq ?? a.i) - (b.m.seq ?? b.i) || a.i - b.i).map((x) => x.m)
}

/** This machine first, then the new ones (newest log entry first), then the rest by last activity.
 *  Ties keep log order. Display only — numbering is `logOrder`. */
export function orderDevices<T extends DeviceRow>(members: T[], lastSeen: Record<string, number> | undefined, now: number): T[] {
  const indexed = logOrder(members).map((m, i) => ({ m, i }))
  const rank = (m: T): number => (m.self ? 0 : isNewDevice(m, now) ? 1 : 2)
  // The log position is the unforgeable "when" for the new group; activity (else the add date) for the rest.
  const when = (x: { m: T; i: number }): number => (rank(x.m) === 2 ? lastSeen?.[x.m.pub] ?? x.m.addedAt : x.i)
  indexed.sort((a, b) => rank(a.m) - rank(b.m) || when(b) - when(a) || a.i - b.i)
  return indexed.map((x) => x.m)
}

/** Whether `devices remove` goes ahead, asks first, or refuses, given how the selector resolved:
 *  `byNumber` when it named a list number, else `key` is the key-code start it matched (normalised:
 *  upper case, no spaces or separators). A number is a guess about what the person last read, and a
 *  removal cannot be undone (the key is spent): it is echoed and confirmed at a terminal, and without
 *  one it needs `--yes`. A key-code start of 4 or more characters names the device and needs neither,
 *  digits or not ("1111" that is not a list number is the start of 1111·…); one under 4 ("1A") is as
 *  much a guess as a number and is treated like it.
 *  `interactive` means someone can both see the question and answer it (stdin AND stdout a TTY). */
export function removeConfirmation(
  sel: { byNumber: boolean; key: string },
  opts: { yes: boolean; interactive: boolean },
): 'go' | 'ask' | 'refuse' {
  if (opts.yes || (!sel.byNumber && sel.key.length >= 4)) return 'go'
  return opts.interactive ? 'ask' : 'refuse'
}

/** The answer to `remove`'s `[y/N]`: only an explicit yes removes. */
export const confirmsRemoval = (answer: string): boolean => /^y(es)?$/i.test(answer.trim())

export type DeviceRegistration = 'active' | 'removed' | 'unregistered'

/** Whether the account's device log holds this machine's key. No key on disk but a retired one means
 *  this machine was signed out of the account; neither means there is nothing to say. */
export function deviceRegistration(pub: string | null, file: DevLogFile, spent: boolean): DeviceRegistration | null {
  if (!pub) return spent ? 'removed' : null
  if (file.state?.active[pub]) return 'active'
  if (file.state?.removed.includes(pub)) return 'removed'
  return 'unregistered'
}

/** The text after `device     ` in `harness status`, or null for no row. */
export function deviceStatusValue(fp: string | null, reg: DeviceRegistration | null): string | null {
  if (!reg) return null
  const note = reg === 'active' ? 'in your account' : reg === 'removed' ? 'removed — run harness login' : 'not registered yet'
  return fp ? `${fp}  (${note})` : `(${note})`
}

const nameOf = (row: Pick<DeviceRow, 'label'>): string => row.label || '(no name)'
const kindOf = (row: Pick<DeviceRow, 'kind' | 'machineId'>): string => (row.kind === 'machine' ? `computer ${row.machineId.slice(0, 8)}` : 'app')

/** The lines of `harness devices list`: shown in `orderDevices` order, each row keeping its `logOrder`
 *  number. `selfFallback` is this machine's own
 *  key code for when the log has no row for it yet. */
export function formatDeviceList(
  listing: { members: DeviceRow[]; lastSeen?: Record<string, number> },
  now: number,
  selfFallback?: { label: string; fp: string },
): string[] {
  const numbers = new Map(logOrder(listing.members).map((m, i) => [m.pub, i + 1]))
  const rows = orderDevices(listing.members, listing.lastSeen, now)
  const lines: string[] = ['']
  const self = rows.find((r) => r.self)
  if (self) lines.push(`  This machine: ${nameOf(self)}  ${self.fingerprint}`, '')
  else if (selfFallback) lines.push(`  This machine: ${selfFallback.label}  ${selfFallback.fp}  (not registered yet)`, '')
  lines.push('  Devices on this account — each one trusts every other:', '')
  rows.forEach((m) => {
    const flag = m.self ? '  (this machine)' : isNewDevice(m, now) ? '  new' : ''
    lines.push(`   ${String(numbers.get(m.pub)).padStart(2)}. ${nameOf(m)}  ${kindOf(m)}  ${m.fingerprint}  ${activityPhrase(listing.lastSeen?.[m.pub], m.addedAt, now)}${flag}`)
  })
  // `remove` takes the key code here, not a number: a code names one device however the list moves.
  lines.push('', '  Details: harness devices show <#|fingerprint>   Not yours? harness devices remove <fingerprint>', '')
  return lines
}

/** The lines of `harness devices show`: everything known about one device, and how to check it. */
export function formatDeviceDetail(row: DeviceRow, lastSeen: number | undefined, now: number): string[] {
  const lines = ['', `  ${nameOf(row)}${row.self ? '  (this machine)' : ''}`, '']
  lines.push(`    kind         ${row.kind === 'machine' ? 'Computer' : 'App'}`)
  lines.push(`    added        ${fullDateTime(row.addedAt)} (${relativeAgo(row.addedAt, now)})`)
  lines.push(`    last active  ${lastSeen === undefined ? 'unknown' : `${relativeAgo(lastSeen, now)} (${fullDateTime(lastSeen)})`}`)
  if (row.kind === 'machine') lines.push(`    machine      ${row.machineId.slice(0, 8)}`)
  lines.push(`    key code     ${row.fingerprint}`, '')
  lines.push(`  ${COMPARE_HINT}`, '')
  lines.push(row.self ? '  This is this machine.' : `  Not yours? harness devices remove ${row.fingerprint}`, '')
  return lines
}
