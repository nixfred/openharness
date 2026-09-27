/**
 * Minimal OpenTelemetry-shaped tracing without the SDK: spans for model calls, tool runs, shell
 * commands, edits, approvals and retries, exported either as JSONL on disk or as OTLP/JSON over
 * HTTP to a collector (Grafana on mind or blu). The wire shape follows the OTLP ResourceSpans
 * JSON encoding closely enough for a stock collector; ids are 32/16 hex chars, times are
 * nanosecond strings.
 */
export type SpanStatus = 'ok' | 'error' | 'unset'

export interface SpanRecord {
  traceId: string
  spanId: string
  parentSpanId?: string
  name: string
  startNs: bigint
  endNs?: bigint
  attributes: Record<string, string | number | boolean>
  status: SpanStatus
}

export interface SpanExporter {
  export(spans: SpanRecord[]): Promise<void>
}

export interface TracerDeps {
  rng?: () => number
  now?: () => number
  exporter: SpanExporter
  service?: string
  host?: string
}

const HEX = '0123456789abcdef'
export function hexId(rng: () => number, chars: number): string {
  let s = ''
  for (let i = 0; i < chars; i++) s += HEX[Math.floor(rng() * 16) % 16]
  return s
}

export class Span {
  constructor(private readonly tracer: Tracer, readonly record: SpanRecord) {}
  get traceId(): string { return this.record.traceId }
  get spanId(): string { return this.record.spanId }
  set(key: string, value: string | number | boolean): this { this.record.attributes[key] = value; return this }
  child(name: string, attrs: Record<string, string | number | boolean> = {}): Span {
    return this.tracer.start(name, attrs, this)
  }
  end(status: SpanStatus = 'ok'): void {
    if (this.record.endNs !== undefined) return
    this.record.endNs = this.tracer.nowNs()
    this.record.status = status
    this.tracer.enqueue(this.record)
  }
}

export class Tracer {
  private readonly rng: () => number
  private readonly now: () => number
  private queue: SpanRecord[] = []
  private timer: ReturnType<typeof setTimeout> | null = null
  readonly service: string
  readonly host: string

  constructor(private readonly deps: TracerDeps, private readonly opts: { batch?: number; flushMs?: number } = {}) {
    this.rng = deps.rng ?? Math.random
    this.now = deps.now ?? Date.now
    this.service = deps.service ?? 'openharness-daemon'
    this.host = deps.host ?? 'unknown'
  }

  nowNs(): bigint { return BigInt(this.now()) * 1_000_000n }

  start(name: string, attributes: Record<string, string | number | boolean> = {}, parent?: Span): Span {
    const record: SpanRecord = {
      traceId: parent ? parent.traceId : hexId(this.rng, 32),
      spanId: hexId(this.rng, 16),
      ...(parent ? { parentSpanId: parent.spanId } : {}),
      name, startNs: this.nowNs(), attributes: { ...attributes }, status: 'unset',
    }
    return new Span(this, record)
  }

  enqueue(record: SpanRecord): void {
    this.queue.push(record)
    const batch = this.opts.batch ?? 50
    if (this.queue.length >= batch) { void this.flush(); return }
    if (!this.timer) this.timer = setTimeout(() => { void this.flush() }, this.opts.flushMs ?? 5000)
  }

  async flush(): Promise<void> {
    if (this.timer) { clearTimeout(this.timer); this.timer = null }
    if (this.queue.length === 0) return
    const spans = this.queue
    this.queue = []
    await this.deps.exporter.export(spans)
  }
}

const attr = (k: string, v: string | number | boolean) => ({
  key: k,
  value: typeof v === 'string' ? { stringValue: v } : typeof v === 'boolean' ? { boolValue: v } : Number.isInteger(v) ? { intValue: String(v) } : { doubleValue: v },
})

/** OTLP/JSON `ExportTraceServiceRequest` body for one batch. */
export function toOtlpJson(spans: SpanRecord[], service: string, host: string): unknown {
  return {
    resourceSpans: [{
      resource: { attributes: [attr('service.name', service), attr('host.name', host)] },
      scopeSpans: [{
        scope: { name: 'openharness.nixfred' },
        spans: spans.map((s) => ({
          traceId: s.traceId,
          spanId: s.spanId,
          ...(s.parentSpanId ? { parentSpanId: s.parentSpanId } : {}),
          name: s.name,
          kind: 1,
          startTimeUnixNano: s.startNs.toString(),
          endTimeUnixNano: (s.endNs ?? s.startNs).toString(),
          attributes: Object.entries(s.attributes).map(([k, v]) => attr(k, v)),
          status: { code: s.status === 'ok' ? 1 : s.status === 'error' ? 2 : 0 },
        })),
      }],
    }],
  }
}

export class JsonlSpanExporter implements SpanExporter {
  constructor(private readonly append: (path: string, data: string) => Promise<void>, private readonly dataDir: string) {}
  async export(spans: SpanRecord[]): Promise<void> {
    const lines = spans.map((s) => JSON.stringify({ ...s, startNs: s.startNs.toString(), endNs: s.endNs?.toString() })).join('\n') + '\n'
    await this.append(`${this.dataDir}/spans.jsonl`, lines)
  }
}

export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body: string }) => Promise<{ ok: boolean; status: number }>

export class OtlpHttpSpanExporter implements SpanExporter {
  constructor(private readonly url: string, private readonly fetchImpl: FetchLike, private readonly service = 'openharness-daemon', private readonly host = 'unknown') {}
  async export(spans: SpanRecord[]): Promise<void> {
    for (let i = 0; i < spans.length; i += 50) {
      const body = JSON.stringify(toOtlpJson(spans.slice(i, i + 50), this.service, this.host))
      const res = await this.fetchImpl(this.url, { method: 'POST', headers: { 'content-type': 'application/json' }, body })
      if (!res.ok) throw new Error(`OTLP export failed: HTTP ${res.status}`)
    }
  }
}
