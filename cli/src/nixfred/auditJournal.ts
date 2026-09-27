/**
 * Append-only, redacted, per-machine journal of what agents did: one JSON line per event, so a
 * surprising change can be traced with grep instead of five engine-specific transcripts. Rotates by
 * size and keeps a handful of generations. The filesystem is injected so the journal is testable.
 */
import { redactSecrets } from './redact.js'

export type AuditKind = 'tool' | 'turn' | 'command' | 'rpc' | 'gate' | 'spend'

export interface AuditEntry {
  at: number
  machine: string
  agentId: string
  sessionId?: string
  kind: AuditKind
  name: string
  detail?: string
  exit?: number
  decision?: 'allow' | 'ask' | 'deny' | 'pause'
}

export interface AuditFs {
  appendFile(path: string, data: string): Promise<void>
  readFile(path: string): Promise<string>
  stat(path: string): Promise<{ size: number }>
  rename(from: string, to: string): Promise<void>
  unlink(path: string): Promise<void>
  mkdir(path: string): Promise<void>
  exists(path: string): Promise<boolean>
}

export const AUDIT_ROTATE_BYTES = 20 * 1024 * 1024
export const AUDIT_KEEP = 5

export class AuditJournal {
  private readonly file: string
  private ready: Promise<void> | null = null

  constructor(private readonly fs: AuditFs, private readonly dataDir: string) {
    this.file = `${dataDir}/audit.jsonl`
  }

  private ensureDir(): Promise<void> {
    if (!this.ready) this.ready = this.fs.exists(this.dataDir).then((ok) => (ok ? undefined : this.fs.mkdir(this.dataDir)))
    return this.ready
  }

  /** Redacts detail and name before anything touches disk. */
  async append(entry: AuditEntry): Promise<void> {
    await this.ensureDir()
    await this.rotateIfNeeded()
    const safe: AuditEntry = {
      ...entry,
      name: redactSecrets(entry.name).text,
      ...(entry.detail !== undefined ? { detail: redactSecrets(entry.detail).text } : {}),
    }
    await this.fs.appendFile(this.file, JSON.stringify(safe) + '\n')
  }

  private async rotateIfNeeded(): Promise<void> {
    if (!(await this.fs.exists(this.file))) return
    const { size } = await this.fs.stat(this.file)
    if (size < AUDIT_ROTATE_BYTES) return
    const gen = (n: number) => `${this.dataDir}/audit.${n}.jsonl`
    if (await this.fs.exists(gen(AUDIT_KEEP))) await this.fs.unlink(gen(AUDIT_KEEP))
    for (let n = AUDIT_KEEP - 1; n >= 1; n--) {
      if (await this.fs.exists(gen(n))) await this.fs.rename(gen(n), gen(n + 1))
    }
    await this.fs.rename(this.file, gen(1))
  }

  private async readAll(): Promise<AuditEntry[]> {
    if (!(await this.fs.exists(this.file))) return []
    const text = await this.fs.readFile(this.file)
    const out: AuditEntry[] = []
    for (const line of text.split('\n')) {
      if (!line.trim()) continue
      try { out.push(JSON.parse(line) as AuditEntry) } catch { /* a torn last line after a crash */ }
    }
    return out
  }

  async tail(n: number): Promise<AuditEntry[]> {
    const all = await this.readAll()
    return all.slice(Math.max(0, all.length - n))
  }

  async search(predicate: (e: AuditEntry) => boolean, limit = 100): Promise<AuditEntry[]> {
    const all = await this.readAll()
    const out: AuditEntry[] = []
    for (let i = all.length - 1; i >= 0 && out.length < limit; i--) if (predicate(all[i]!)) out.push(all[i]!)
    return out
  }
}
