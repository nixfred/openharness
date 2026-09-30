import { mkdtempSync, readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { describe, expect, it, vi } from 'vitest'
import { CableFleet as SourceFleet } from './cableFleet.js'
import { CableSession, type CableHost, type CablePort } from './cableSession.js'
import { CableDecoder, CableType, encodeCableFrame } from './cableFrame.js'
import { DialLog } from './dialLog.js'
import { parseDarwinDialPorts, type DialPort } from './serial.js'

// Run the same two-device scenarios against the staged helper before deployment.
const CableFleet: typeof SourceFleet = process.env.HARNESS_TEST_USB_FLEET
  ? (await import(pathToFileURL(process.env.HARNESS_TEST_USB_FLEET).href)).CableFleet : SourceFleet
const device = (path: string, serialNumber: string): DialPort => ({ path, serialNumber, vendorId: 0x303a, productId: 0x1001 })

class Peer implements CablePort {
  isOpen = true
  sent: Record<string, unknown>[] = []
  private decoder = new CableDecoder()
  constructor(readonly path: string, private onData: (chunk: Buffer) => void, private onClosed: (why: string) => void) {}
  async write(bytes: Uint8Array) { this.decoder.feed(bytes, frame => {
    if (frame.type === CableType.Json) this.sent.push(JSON.parse(Buffer.from(frame.payload).toString()))
  }) }
  async close(why = 'disconnected') { if (this.isOpen) { this.isOpen = false; this.onClosed(why) } }
  say(message: Record<string, unknown>) { this.onData(Buffer.from(encodeCableFrame(CableType.Json, Buffer.from(JSON.stringify(message))))) }
  pcm(value: number) { this.onData(Buffer.from(encodeCableFrame(CableType.Pcm, Buffer.alloc(3200, value)))) }
}

function fixture() {
  let present = [device('/dev/tim', 'AA:01'), device('/dev/tux', 'BB:02')]
  const ports: Peer[] = []
  const host: CableHost = {
    localMachine: () => ({ id: 'local', name: 'Fixture' }),
    listMachines: async () => ({ machines: [], source: 'backend' }),
    selectedMachine: () => 'local', selectMachine: async () => ({ ok: true }),
    listSwarms: () => ({ selected: 'tab', swarms: [], tiles: [] }), listUnread: () => [],
    selectSwarm: vi.fn(), appName: () => 'harness', voiceLang: () => 'en',
    listAgents: async () => [{ id: 'a', name: 'A', engine: 'codex' }], agentTotal: () => 1,
    activeSwarm: () => 'tab', describe: () => ({ name: 'A', engine: 'codex', machine: 'local' }),
    sendTurn: vi.fn(), stopTurn: vi.fn(), scrolled: vi.fn(), answer: vi.fn(), focus: vi.fn(),
    openAgent: vi.fn(), forkAgent: async () => ({ ok: true, agentId: 'fork' }), updateAgent: vi.fn(),
    listModels: async () => [], recentSummaries: async () => [],
    transcribe: vi.fn(async pcm => `audio-${pcm[0]}`),
    route: async () => ({ agentId: 'a', confidence: 1, reason: 'fixture' }), log: vi.fn(),
    onDialAttached: vi.fn(), onDialGone: vi.fn(), onDialStatus: vi.fn(),
  }
  const logs = mkdtempSync(join(tmpdir(), 'usb-fleet-'))
  const options = {
    discover: vi.fn(async () => present), intervalMs: 60_000,
    open: vi.fn(async (path: string, onData: (chunk: Buffer) => void, onClosed: (why: string) => void) => {
      const port = new Peer(path, onData, onClosed); ports.push(port); return port
    }),
  }
  const fleet = new CableFleet(CableSession, host, logs, DialLog, options)
  async function start() { fleet.start(); await vi.waitFor(() => expect(ports).toHaveLength(2)); await greet(ports) }
  async function greet(peers: Peer[]) {
    for (const p of peers) p.say({ t: 'hello', product: 'harness', mac: p.path, fw: 'fixture', proto: 3 })
    await vi.waitFor(() => { for (const p of peers) expect(p.sent.some(m => m.t === 'agents.end')).toBe(true) })
  }
  return { fleet, host, ports, options, logs, start, greet, setPorts: (p: DialPort[]) => { present = p } }
}

describe('USB dial fleet', () => {
  it('names every device on the desk, and changes the settings of ONE of them', async () => {
    /*
     * Before this the fleet picked a row and threw the rest away, so the app drew one robot however
     * many were plugged in — and a preference had nowhere to be addressed to.
     *
     * Every other command here broadcasts ON PURPOSE: both devices show the same desktop. A setting
     * does not, because it belongs to the glass it was set on.
     */
    const f = fixture()
    try {
      await f.start()
      const settings = {
        brightness: 60, character: 0, face: 466, muted: false, quiet: false, straightTitle: false,
        focusFace: false, scrollReversed: false, round: true, voiceLang: 'vi',
      }
      for (const port of f.ports) {
        port.say({ t: 'hello', product: 'harness', mac: port.path, fw: 'fixture', proto: 3, settings })
      }
      await vi.waitFor(() => expect(f.fleet.devices().filter(d => d.settings)).toHaveLength(2))
      expect(f.fleet.devices().map(d => d.id)).toEqual(['AA:01', 'BB:02'])
      expect(f.fleet.devices().map(d => d.mac)).toEqual(['/dev/tim', '/dev/tux'])
      for (const device of f.fleet.devices()) expect(device.settings).toEqual(settings)
      // The whole desk rides on the status a window receives, with one row repeated flat.
      expect(f.host.onDialStatus).toHaveBeenLastCalledWith(
        expect.objectContaining({ attached: true, devices: expect.arrayContaining([expect.objectContaining({ id: 'BB:02' })]) }))

      for (const port of f.ports) port.sent.length = 0
      expect(await f.fleet.setSettings('BB:02', { brightness: 20 })).toEqual({ ok: true })
      await vi.waitFor(() => expect(f.ports[1].sent).toContainEqual({ t: 'settings.set', brightness: 20 }))
      expect(f.ports[0].sent).toHaveLength(0)   // the other robot was not touched

      expect(await f.fleet.setSettings('ZZ:99', { muted: true }))
        .toEqual({ ok: false, error: 'That device is not plugged into this computer.' })
    } finally { await f.fleet.stop() }
  })

  it('keeps an unplugged device on the desk, with what it last held', async () => {
    // A pane that emptied the moment a cable was pulled would be a pane nobody could read their own
    // settings out of. Read-only is the app's job; keeping the row is this one's.
    const f = fixture()
    try {
      await f.start()
      const settings = {
        brightness: 40, character: 1, face: 466, muted: true, quiet: true, straightTitle: true,
        focusFace: false, scrollReversed: true, round: false, voiceLang: 'en',
      }
      f.ports[0].say({ t: 'hello', product: 'harness', mac: '/dev/tim', fw: 'fixture', proto: 3, settings })
      await vi.waitFor(() => expect(f.fleet.devices()[0]?.settings).toEqual(settings))
      await f.ports[0].close('unplugged')
      await vi.waitFor(() => expect(f.fleet.devices()[0]?.attached).toBe(false))
      expect(f.fleet.devices()[0]).toMatchObject({ id: 'AA:01', attached: false, settings })
      expect(await f.fleet.setSettings('AA:01', { muted: false }))
        .toEqual({ ok: false, error: 'That device is unplugged.' })
    } finally { await f.fleet.stop() }
  })

  it('connects both dials, broadcasts work, and keeps the remaining dial attached', async () => {
    const f = fixture()
    try {
      await f.start(); f.fleet.start(); await f.fleet['scan']()
      expect(f.options.open).toHaveBeenCalledTimes(2)
      expect(f.host.onDialAttached).toHaveBeenCalledTimes(1)
      await f.fleet.turnStarted('a', 'Working')
      for (const port of f.ports) expect(port.sent).toContainEqual({ t: 'turn.started', agentId: 'a', text: 'Working' })
      f.setPorts([device('/dev/tux', 'BB:02')]); await f.fleet['scan']()
      expect(f.ports[0].isOpen).toBe(false)
      expect(f.ports[1].isOpen).toBe(true)
      expect(f.fleet.isConnected).toBe(true)
      expect(f.host.onDialGone).not.toHaveBeenCalled()
      expect(f.host.onDialStatus).toHaveBeenLastCalledWith(expect.objectContaining({ attached: true }))
      await f.fleet.turnDone('a')
      expect(f.ports[1].sent.some(m => m.t === 'turn.done')).toBe(true)
      await vi.waitFor(() => expect(readdirSync(f.logs).sort()).toEqual(['usb-AA-01', 'usb-BB-02']))
      f.setPorts([]); await f.fleet['scan']()
      expect(f.fleet.isConnected).toBe(false)
      expect(f.host.onDialGone).toHaveBeenCalledTimes(1)
      expect(f.host.onDialStatus).toHaveBeenLastCalledWith({ attached: false, devices: [] })
    } finally { await f.fleet.stop() }
  })

  it('keeps simultaneous voice uploads separate even with the same upload id', async () => {
    const f = fixture()
    try {
      await f.start()
      for (const p of f.ports) p.say({ t: 'voice.begin', uploadId: 'same', agentId: 'a' })
      f.ports[0].pcm(17); f.ports[1].pcm(34)
      for (const p of f.ports) p.say({ t: 'voice.end' })
      await vi.waitFor(() => expect(f.host.sendTurn).toHaveBeenCalledTimes(2))
      const audio = vi.mocked(f.host.transcribe).mock.calls.map(c => c[0])
      expect(audio.map(b => [b.length, b[0]])).toEqual([[3200, 17], [3200, 34]])
      expect(audio.every(b => b.every(v => v === b[0]))).toBe(true)
      for (const [i, p] of f.ports.entries()) {
        expect(p.sent.some(m => m.t === 'voice.transcript' && m.text === `audio-${i ? 34 : 17}`)).toBe(true)
      }
    } finally { await f.fleet.stop() }
  })

  it('does not cancel the other dial while its transcription is pending', async () => {
    const f = fixture(); let finish!: (text: string) => void
    vi.mocked(f.host.transcribe).mockImplementation(() => new Promise(resolve => { finish = resolve }))
    try {
      await f.start()
      f.ports[1].say({ t: 'voice.begin', uploadId: 'pending', agentId: 'a' }); f.ports[1].pcm(42)
      f.ports[1].say({ t: 'voice.end' })
      await vi.waitFor(() => expect(f.host.transcribe).toHaveBeenCalledTimes(1))
      f.setPorts([device('/dev/tux', 'BB:02')]); await f.fleet['scan']()
      finish('keep recording')
      await vi.waitFor(() => expect(f.host.sendTurn).toHaveBeenCalledWith('a', 'keep recording'))
      expect(f.host.onDialGone).not.toHaveBeenCalled()
    } finally { await f.fleet.stop() }
  })

  it('preserves healthy sessions when discovery fails and replaces a moved USB path', async () => {
    const f = fixture()
    try {
      await f.start()
      f.options.discover.mockRejectedValueOnce(new Error('inventory unavailable'))
      await f.fleet['scan'](); expect(f.ports.every(p => p.isOpen)).toBe(true)
      f.setPorts([device('/dev/tim-new', 'AA:01'), device('/dev/tux', 'BB:02')])
      await f.fleet['scan'](); await vi.waitFor(() => expect(f.ports).toHaveLength(3))
      await f.greet([f.ports[2]])
      expect(f.ports[0].isOpen).toBe(false); expect(f.ports[1].isOpen).toBe(true)
      expect(f.ports[2].path).toBe('/dev/tim-new')
      expect(f.host.onDialGone).not.toHaveBeenCalled()
      expect(f.host.onDialAttached).toHaveBeenCalledTimes(1)
    } finally { await f.fleet.stop() }
  })

  it('opens only selected serial numbers', async () => {
    const f = fixture()
    const fleet = new CableFleet(CableSession, f.host, f.logs, DialLog, { ...f.options, serials: ['bb:02'] })
    try {
      fleet.start(); await fleet['scan']()
      await vi.waitFor(() => expect(f.ports).toHaveLength(1))
      expect(f.ports[0].path).toBe('/dev/tux')
    } finally { await fleet.stop() }
  })

  it('closes a port that finishes opening after shutdown', async () => {
    const f = fixture(); let finish!: (port: Peer) => void; let late!: Peer
    f.setPorts([device('/dev/tim', 'AA:01')])
    f.options.open.mockImplementation((path, onData, onClosed) => {
      late = new Peer(path, onData, onClosed)
      return new Promise(resolve => { finish = resolve })
    })
    try {
      f.fleet.start(); await vi.waitFor(() => expect(late).toBeDefined())
      await f.fleet.stop(); finish(late)
      await vi.waitFor(() => expect(late.isOpen).toBe(false))
      expect(f.fleet.isConnected).toBe(false)
      expect(f.host.onDialAttached).not.toHaveBeenCalled()
    } finally { await f.fleet.stop() }
  })
})

describe('macOS USB inventory', () => {
  it('reads multiple USB-rooted subtrees without leaking IDs into their siblings', () => {
    const dump = `+-o Tim <class IOUSBHostDevice>
  "idVendor" = 12346
  "idProduct" = 4097
  "USB Serial Number" = "AA:01"
  +-o CDC
    +-o serial
      "IOCalloutDevice" = "/dev/tim"
+-o unrelated <class IOUSBHostDevice>
  "idVendor" = 12346
  "idProduct" = 12
  +-o serial
    "IOCalloutDevice" = "/dev/unrelated"
+-o Tux <class IOUSBHostDevice>
  "USB Serial Number" = "BB:02"
  "idProduct" = 4097
  "idVendor" = 12346
  +-o serial
    "IOCalloutDevice" = "/dev/tux"`
    expect(parseDarwinDialPorts(dump)).toEqual([device('/dev/tim', 'AA:01'), device('/dev/tux', 'BB:02')])
    expect(parseDarwinDialPorts('')).toEqual([])
  })

  it('associates each tty with its own matching USB parent and serial in either property order', () => {
    const dump = `+-o root
  +-o Tim
    "USB Serial Number" = "AA:01"
    "idProduct" = 4097
    "idVendor" = 12346
    +-o driver
      +-o serial
        "IOCalloutDevice" = "/dev/tim"
        "IOCalloutDevice" = "/dev/tim"
  +-o unrelated
    "idVendor" = 12346
    "idProduct" = 12
    +-o serial
      "IOCalloutDevice" = "/dev/unrelated"
  +-o Tux
    "idVendor" = 12346
    "idProduct" = 4097
    "USB Serial Number" = "BB:02"
    +-o serial
      "IOCalloutDevice" = "/dev/tux"
  +-o console
    "IOCalloutDevice" = "/dev/debug-console"`
    expect(parseDarwinDialPorts(dump)).toEqual([device('/dev/tim', 'AA:01'), device('/dev/tux', 'BB:02')])
  })
})
