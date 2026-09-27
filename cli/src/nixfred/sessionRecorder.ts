/**
 * Terminal session replay with pinned moments: `tmux pipe-pane` streams a pane's output to a raw
 * log, a sidecar records the start time and any pins (a label plus the byte offset at that moment).
 * `toAsciicast` turns the pair into asciicast v2 for any player.
 *
 * Timing approximation: pipe-pane gives bytes, not timestamps. Time is interpolated linearly
 * between known anchors (start, each pin, stop), so playback speed inside one segment is even
 * rather than true. Pins therefore double as timing marks: the more you pin, the truer the replay.
 */
export interface RecorderDeps {
  exec(cmd: string, args: string[]): Promise<string>
  writeFile(path: string, data: string): Promise<void>
  readFile(path: string): Promise<string>
  stat(path: string): Promise<{ size: number }>
  mkdir(path: string): Promise<void>
  now(): number
}

export interface Pin { at: number; label: string; offsetBytes: number }

export interface RecordingSidecar {
  version: 1
  agentId: string
  pane: string
  rawFile: string
  startedAt: number
  stoppedAt?: number
  stoppedOffsetBytes?: number
  cols?: number
  rows?: number
  pins: Pin[]
}

const paths = (dataDir: string, agentId: string) => ({
  dir: `${dataDir}/recordings/${agentId}`,
  raw: `${dataDir}/recordings/${agentId}/pane.raw`,
  sidecar: `${dataDir}/recordings/${agentId}/recording.json`,
})

async function readSidecar(deps: RecorderDeps, dataDir: string, agentId: string): Promise<RecordingSidecar> {
  return JSON.parse(await deps.readFile(paths(dataDir, agentId).sidecar)) as RecordingSidecar
}

async function writeSidecar(deps: RecorderDeps, dataDir: string, s: RecordingSidecar): Promise<void> {
  await deps.writeFile(paths(dataDir, s.agentId).sidecar, JSON.stringify(s, null, 2) + '\n')
}

export async function startRecording(deps: RecorderDeps, input: { pane: string; agentId: string; dataDir: string; cols?: number; rows?: number }): Promise<RecordingSidecar> {
  const p = paths(input.dataDir, input.agentId)
  await deps.mkdir(p.dir)
  // -o: only start if no pipe is active, so a second start is a no-op rather than a toggle-off.
  await deps.exec('tmux', ['pipe-pane', '-t', input.pane, '-o', `cat >> '${p.raw}'`])
  const sidecar: RecordingSidecar = { version: 1, agentId: input.agentId, pane: input.pane, rawFile: p.raw, startedAt: deps.now(), pins: [], ...(input.cols ? { cols: input.cols } : {}), ...(input.rows ? { rows: input.rows } : {}) }
  await writeSidecar(deps, input.dataDir, sidecar)
  return sidecar
}

export async function stopRecording(deps: RecorderDeps, input: { agentId: string; dataDir: string }): Promise<RecordingSidecar> {
  const s = await readSidecar(deps, input.dataDir, input.agentId)
  await deps.exec('tmux', ['pipe-pane', '-t', s.pane])
  s.stoppedAt = deps.now()
  try { s.stoppedOffsetBytes = (await deps.stat(s.rawFile)).size } catch { s.stoppedOffsetBytes = 0 }
  await writeSidecar(deps, input.dataDir, s)
  return s
}

export async function pin(deps: RecorderDeps, input: { agentId: string; dataDir: string; label: string }): Promise<Pin> {
  const s = await readSidecar(deps, input.dataDir, input.agentId)
  let offsetBytes = 0
  try { offsetBytes = (await deps.stat(s.rawFile)).size } catch { offsetBytes = 0 }
  const p: Pin = { at: deps.now(), label: input.label, offsetBytes }
  s.pins.push(p)
  await writeSidecar(deps, input.dataDir, s)
  return p
}

export async function listPins(deps: RecorderDeps, input: { agentId: string; dataDir: string }): Promise<Pin[]> {
  try { return (await readSidecar(deps, input.dataDir, input.agentId)).pins } catch { return [] }
}

/** asciicast v2: a JSON header line, then `[time, "o", data]` events. Chunked at 512 bytes. */
export function toAsciicast(raw: string, sidecar: RecordingSidecar, chunk = 512): string {
  const total = Buffer.byteLength(raw)
  const anchors: Array<{ offset: number; at: number }> = [{ offset: 0, at: sidecar.startedAt }]
  for (const p of sidecar.pins) anchors.push({ offset: Math.min(p.offsetBytes, total), at: p.at })
  const endAt = sidecar.stoppedAt ?? (anchors[anchors.length - 1]!.at + 1000)
  anchors.push({ offset: total, at: endAt })
  anchors.sort((a, b) => a.offset - b.offset || a.at - b.at)

  const timeAt = (offset: number): number => {
    for (let i = 1; i < anchors.length; i++) {
      const a = anchors[i - 1]!, b = anchors[i]!
      if (offset <= b.offset) {
        if (b.offset === a.offset) return (b.at - sidecar.startedAt) / 1000
        const f = (offset - a.offset) / (b.offset - a.offset)
        return (a.at + f * (b.at - a.at) - sidecar.startedAt) / 1000
      }
    }
    return (endAt - sidecar.startedAt) / 1000
  }

  const header = {
    version: 2, width: sidecar.cols ?? 120, height: sidecar.rows ?? 40, timestamp: Math.floor(sidecar.startedAt / 1000),
    title: `harness ${sidecar.agentId}`,
    env: { TERM: 'xterm-256color', SHELL: '/bin/sh' },
    ...(sidecar.pins.length ? { markers: sidecar.pins.map((p) => [Number(timeAt(Math.min(p.offsetBytes, total)).toFixed(3)), p.label]) } : {}),
  }
  const lines = [JSON.stringify(header)]
  const buf = Buffer.from(raw)
  for (let off = 0; off < buf.length; off += chunk) {
    const piece = buf.subarray(off, Math.min(off + chunk, buf.length)).toString('utf8')
    lines.push(JSON.stringify([Number(timeAt(off).toFixed(3)), 'o', piece]))
  }
  for (const p of sidecar.pins) lines.push(JSON.stringify([Number(timeAt(Math.min(p.offsetBytes, total)).toFixed(3)), 'm', p.label]))
  return lines.join('\n') + '\n'
}
