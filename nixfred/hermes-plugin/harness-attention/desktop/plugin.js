// harness-attention for Hermes Desktop. ESM, no build step, per
// https://hermes-agent.nousresearch.com/docs/developer-guide/desktop-plugin-sdk
//
// A status-bar item with the fleet summary, refreshed every 5 s, and a notification the moment an
// agent enters waiting / permission / failed or a new collision alert appears. Reads the Harness
// daemon on this machine directly. If the renderer's content policy refuses fetch() to 127.0.0.1,
// move the fetch into a Python backend (dashboard/plugin_api.py mounted at /api/plugins/<id>/) and
// call ctx.rest('/attention') here instead; that shape is what hermes-newswire uses.
import { host, useValue, STATUSBAR_AREAS } from '@hermes/plugin-sdk'
import { jsx } from 'react/jsx-runtime'

const URL = 'http://127.0.0.1:18473/api/attention'
const URGENT = new Set(['waiting', 'permission', 'failed'])
const LABEL = { waiting: 'is waiting on you', permission: 'needs permission', failed: 'failed' }

export default {
  id: 'harness-attention',
  name: 'Harness attention',
  defaultEnabled: true,
  register(ctx) {
    let summary = { text: 'harness: offline', title: '' }
    const seen = new Map()      // agentId -> last urgent state announced
    const seenAlerts = new Set() // alert key + at
    const listeners = new Set()
    const setSummary = (next) => { summary = next; for (const l of listeners) l(summary) }

    async function poll() {
      let data
      try {
        const res = await fetch(URL, { cache: 'no-store' })
        if (!res.ok) throw new Error(String(res.status))
        data = await res.json()
      } catch (e) {
        setSummary({ text: 'harness: offline', title: `Harness daemon unreachable at ${URL}` })
        return
      }
      const agents = Array.isArray(data.agents) ? data.agents : []
      const alerts = Array.isArray(data.alerts) ? data.alerts : []
      const s = data.summary || {}
      const urgent = agents.filter((a) => URGENT.has(a.state))
      setSummary({
        text: `${data.hostname || 'harness'}: ${s.count ?? agents.length} ${s.state || 'idle'}${alerts.length ? ` △${alerts.length}` : ''}`,
        title: [...agents.map((a) => `${a.glyph || '-'} ${a.name} ${a.label || a.state}${a.detail ? ` (${a.detail})` : ''}`), ...alerts.map((x) => `△ ${x.detail}`)].join('\n'),
      })
      // Announce transitions only: a state that was already announced stays quiet.
      for (const a of urgent) {
        if (seen.get(a.agentId) === a.state) continue
        seen.set(a.agentId, a.state)
        const message = `${a.name} ${LABEL[a.state]}${a.detail ? `: ${a.detail}` : ''}`
        host.notify({ kind: a.state === 'failed' ? 'error' : 'warning', message })
        if (ctx.os && ctx.os.notify) ctx.os.notify({ title: 'Harness', body: message })
      }
      for (const a of agents) if (!URGENT.has(a.state)) seen.delete(a.agentId)
      for (const x of alerts) {
        const key = `${x.kind}:${x.key || x.detail}:${x.at}`
        if (seenAlerts.has(key)) continue
        seenAlerts.add(key)
        host.notify({ kind: 'warning', message: `Collision: ${x.detail}` })
        if (ctx.os && ctx.os.notify) ctx.os.notify({ title: 'Harness collision', body: x.detail })
      }
      if (seenAlerts.size > 500) seenAlerts.clear()
    }

    function StatusItem() {
      const s = useValue(summary, (cb) => { listeners.add(cb); return () => listeners.delete(cb) })
      return jsx('span', { title: s.title, style: { fontVariantNumeric: 'tabular-nums' } }, s.text)
    }

    ctx.register({
      id: 'harness-attention-status',
      area: STATUSBAR_AREAS.right,
      title: 'Harness attention',
      render: () => jsx(StatusItem, {}),
    })

    void poll()
    ctx.setInterval(() => { void poll() }, 5000)
  },
}
