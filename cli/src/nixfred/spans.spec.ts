import { describe, expect, it } from 'vitest'
import { JsonlSpanExporter, OtlpHttpSpanExporter, Tracer, hexId, toOtlpJson, type SpanRecord } from './spans.js'

function seq(): () => number { let i = 0; return () => ((i++ * 37) % 16) / 16 }

describe('spans', () => {
  it('generates hex ids of the requested width', () => {
    expect(hexId(seq(), 32)).toMatch(/^[0-9a-f]{32}$/)
    expect(hexId(seq(), 16)).toMatch(/^[0-9a-f]{16}$/)
  })

  it('links children to the parent trace and exports on flush', async () => {
    const got: SpanRecord[][] = []
    let t = 1_700_000_000_000
    const tracer = new Tracer({ rng: seq(), now: () => t, exporter: { export: async (s) => { got.push(s) } }, host: 'gus' }, { batch: 100, flushMs: 60_000 })
    const root = tracer.start('turn', { agent: 'a1' })
    t += 5
    const child = root.child('tool', { name: 'Bash' })
    t += 10
    child.end('ok')
    root.end('error')
    expect(got).toHaveLength(0)
    await tracer.flush()
    expect(got[0]!.map((s) => s.name)).toEqual(['tool', 'turn'])
    const [tool, turn] = got[0]!
    expect(tool!.traceId).toBe(turn!.traceId)
    expect(tool!.parentSpanId).toBe(turn!.spanId)
    expect(tool!.endNs! - tool!.startNs).toBe(10_000_000n)
    expect(turn!.status).toBe('error')
  })

  it('flushes when the batch fills', async () => {
    const got: SpanRecord[][] = []
    const tracer = new Tracer({ rng: seq(), now: () => 1, exporter: { export: async (s) => { got.push(s) } } }, { batch: 2, flushMs: 60_000 })
    tracer.start('a').end(); tracer.start('b').end()
    await Promise.resolve()
    expect(got).toHaveLength(1)
    expect(got[0]).toHaveLength(2)
  })

  it('produces the OTLP/JSON ResourceSpans shape', async () => {
    const rec: SpanRecord = { traceId: 'a'.repeat(32), spanId: 'b'.repeat(16), name: 'x', startNs: 1_000n, endNs: 2_000n, attributes: { agent: 'a1', tokens: 12, ok: true, ratio: 0.5 }, status: 'ok' }
    const body = toOtlpJson([rec], 'openharness-daemon', 'gus') as { resourceSpans: Array<{ resource: { attributes: unknown[] }; scopeSpans: Array<{ spans: Array<Record<string, unknown>> }> }> }
    const rs = body.resourceSpans[0]!
    expect(rs.resource.attributes).toEqual([
      { key: 'service.name', value: { stringValue: 'openharness-daemon' } },
      { key: 'host.name', value: { stringValue: 'gus' } },
    ])
    const span = rs.scopeSpans[0]!.spans[0]!
    expect(span).toMatchObject({ traceId: 'a'.repeat(32), spanId: 'b'.repeat(16), name: 'x', kind: 1, startTimeUnixNano: '1000', endTimeUnixNano: '2000', status: { code: 1 } })
    expect(span.attributes).toEqual([
      { key: 'agent', value: { stringValue: 'a1' } },
      { key: 'tokens', value: { intValue: '12' } },
      { key: 'ok', value: { boolValue: true } },
      { key: 'ratio', value: { doubleValue: 0.5 } },
    ])
    const calls: Array<{ url: string; body: string }> = []
    const exp = new OtlpHttpSpanExporter('http://mind:4318/v1/traces', async (url, init) => { calls.push({ url, body: init.body }); return { ok: true, status: 200 } }, 'openharness-daemon', 'gus')
    await exp.export(Array.from({ length: 120 }, () => rec))
    expect(calls).toHaveLength(3)
    expect(JSON.parse(calls[0]!.body).resourceSpans[0].scopeSpans[0].spans).toHaveLength(50)
    await expect(new OtlpHttpSpanExporter('u', async () => ({ ok: false, status: 500 })).export([rec])).rejects.toThrow('HTTP 500')
  })

  it('writes JSONL with stringified nanoseconds', async () => {
    const out: string[] = []
    const exp = new JsonlSpanExporter(async (_p, d) => { out.push(d) }, '/data')
    await exp.export([{ traceId: 't', spanId: 's', name: 'n', startNs: 5n, endNs: 9n, attributes: {}, status: 'ok' }])
    expect(JSON.parse(out[0]!.trim())).toMatchObject({ startNs: '5', endNs: '9' })
  })
})
