import { ACTIVITY, SPINNER, COLUMNS, PRESETS, isLive, visibleRows, number, memory, bytes, age, formatValue, sumReading, storageTotal } from './table.js'
const el = id => document.getElementById(id)
const dom = {
  search: el('search'), filter: el('filter'), machine: el('machine'), columns: el('columns'), columnOptions: el('column-options'),
  grid: el('grid'), table: el('table'), colgroup: el('colgroup'), head: el('head'), body: el('body'),
  empty: el('empty'), count: el('count'), message: el('message'), updated: el('updated'), problems: el('problems'),
  refresh: el('refresh'), freeze: el('freeze'), live: el('live-status'), inspect: el('inspect'),
  summary: el('summary'), shared: el('shared'), sharedTitle: el('shared-title'), sharedBody: el('shared-body'),
  inspector: el('inspector'), inspectTitle: el('inspect-title'), inspectContext: el('inspect-context'),
  inspectContent: el('inspect-content'), inspectClose: el('inspect-close'), inspectStop: el('inspect-stop'),
  stopDialog: el('stop-dialog'), stopTitle: el('stop-title'), stopContext: el('stop-context'), stopResult: el('stop-result'),
  stopCancel: el('stop-cancel'), stopConfirm: el('stop-confirm'),
}
const token = document.querySelector('meta[name="hps-token"]').content
const STORAGE_KEY = 'harness-monitor.process-table.v4'
let saved = {}
try { saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}') || {} } catch { /* optional preference storage */ }
const state = {
  rows: [], snapshot: null, query: '', filter: 'all', machine: 'all', // Only currently open harnesses, in every view.
  sort: COLUMNS.some(c => c.key === saved.sort) ? saved.sort : 'rssBytes', direction: saved.direction === 1 ? 1 : -1,
  preset: Object.hasOwn(PRESETS, saved.preset) ? saved.preset : 'overview',
  visible: new Set(Array.isArray(saved.visible) ? saved.visible : PRESETS.overview), widths: {},
  selected: null, inspecting: null, busy: new Set(), nodes: new Map(), shown: [],
  frozen: false, pending: null, connected: false, receivedAt: 0, review: null,
}
for (const col of COLUMNS) state.widths[col.key] = Math.max(64, Math.min(600, Number(saved.widths?.[col.key]) || col.width))
const text = (node, value) => { if (node.textContent !== String(value)) node.textContent = value }
function element(tag, value, className) {
  const node = document.createElement(tag)
  if (value != null) node.textContent = value
  if (className) node.className = className
  return node
}
function persist() {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify({ sort: state.sort, direction: state.direction, preset: state.preset, visible: [...state.visible], widths: state.widths })) } catch { /* private browsing */ }
}
function message(value) { text(dom.message, value) }
async function post(path, payload) {
  const response = await fetch(path, { method: 'POST', headers: { 'content-type': 'application/json', 'x-hps-token': token }, body: JSON.stringify(payload) })
  const result = await response.json()
  if (!response.ok || result.error) throw new Error(result.error || 'Request failed. Refresh and try again.')
  return result
}
const CLOSE_WIDTH = 56
const activeColumns = () => {
  const ordered = PRESETS[state.preset]
  return ordered ? ordered.map(key => COLUMNS.find(c => c.key === key))
    : COLUMNS.filter(c => c.required || state.visible.has(c.key))
}
function resizeColumns() {
  for (const col of dom.colgroup.children) col.style.width = (col.dataset.key === 'close' ? CLOSE_WIDTH : state.widths[col.dataset.key]) + 'px'
  for (const header of dom.head.querySelectorAll('th')) header.querySelector('.resize')?.setAttribute('aria-valuenow', String(state.widths[header.dataset.key]))
  dom.table.style.width = activeColumns().reduce((sum, c) => sum + state.widths[c.key], CLOSE_WIDTH) + 'px'
}
function buildColumns() {
  dom.colgroup.replaceChildren(); dom.head.replaceChildren(); state.nodes.clear(); dom.body.replaceChildren()
  const tr = element('tr')
  for (const col of activeColumns()) {
    const width = element('col'); width.dataset.key = col.key; dom.colgroup.append(width)
    const th = element('th', null, col.numeric ? 'numeric' : ''); th.scope = 'col'; th.dataset.key = col.key
    const sort = element('button', col.label); sort.type = 'button'; sort.title = col.help || 'Sort by ' + col.label
    sort.onclick = () => { state.direction = state.sort === col.key ? -state.direction : col.numeric ? -1 : 1; state.sort = col.key; persist(); render() }
    const grip = element('span', null, 'resize'); grip.tabIndex = 0; grip.role = 'separator'
    grip.setAttribute('aria-orientation', 'vertical'); grip.setAttribute('aria-label', 'Resize ' + col.label)
    grip.setAttribute('aria-valuemin', '64'); grip.setAttribute('aria-valuemax', '600')
    const change = value => { state.widths[col.key] = Math.max(64, Math.min(600, value)); resizeColumns() }
    grip.onpointerdown = event => {
      event.preventDefault(); const start = event.clientX, width = state.widths[col.key]
      grip.setPointerCapture(event.pointerId)
      grip.onpointermove = move => change(width + move.clientX - start)
      grip.onpointerup = grip.onpointercancel = () => { grip.onpointermove = null; persist() }
    }
    grip.onkeydown = event => { if (['ArrowLeft', 'ArrowRight'].includes(event.key)) { event.preventDefault(); change(state.widths[col.key] + (event.key === 'ArrowLeft' ? -16 : 16)); persist() } }
    th.append(sort, grip); tr.append(th)
  }
  const closeWidth = element('col'); closeWidth.dataset.key = 'close'; dom.colgroup.append(closeWidth)
  const closeHeader = element('th', null, 'row-actions'); closeHeader.scope = 'col'
  closeHeader.append(element('span', 'Close harness', 'sr-only')); tr.append(closeHeader)
  dom.head.append(tr); resizeColumns(); render()
}
function columnMenu() {
  dom.columnOptions.replaceChildren()
  for (const group of ['Session', 'Resources', 'AI usage']) {
    dom.columnOptions.append(element('strong', group))
    for (const col of COLUMNS.filter(c => c.group === group && !c.required)) {
      const label = element('label'), check = element('input'); check.type = 'checkbox'; check.checked = state.visible.has(col.key)
      label.title = col.help || col.label
      check.onchange = () => { if (check.checked) state.visible.add(col.key); else state.visible.delete(col.key); state.preset = null; persist(); buildColumns() }
      label.append(check, document.createTextNode(col.label)); dom.columnOptions.append(label)
    }
  }
  const reset = element('button', 'Reset columns'); reset.onclick = () => setPreset('overview'); dom.columnOptions.append(reset)
}
function positionColumnMenu() {
  if (!dom.columns.open) return
  const anchor = dom.columns.querySelector('summary').getBoundingClientRect()
  const height = Math.min(innerHeight * .65, 500)
  const below = innerHeight - anchor.bottom - 14
  const top = below < 160 && anchor.top > below ? Math.max(8, anchor.top - height - 6) : anchor.bottom + 6
  dom.columnOptions.style.left = Math.max(8, Math.min(anchor.right - 230, innerWidth - 238)) + 'px'
  dom.columnOptions.style.top = top + 'px'
  dom.columnOptions.style.maxHeight = Math.max(0, Math.min(height, innerHeight - top - 8)) + 'px'
}
dom.columns.addEventListener('toggle', positionColumnMenu)
window.addEventListener('resize', positionColumnMenu)
function setPreset(preset) {
  state.preset = preset; state.visible = new Set(PRESETS[preset]);
  for (const col of COLUMNS) state.widths[col.key] = col.width
  if (preset === 'ai') { state.sort = 'tokens'; state.direction = -1 }
  else { state.sort = 'rssBytes'; state.direction = -1 }
  persist(); columnMenu(); buildColumns()
}
for (const button of document.querySelectorAll('[data-preset]')) button.onclick = () => setPreset(button.dataset.preset)
const iconNames = new Set(['codex', 'opencode', 'cursor', 'pi', 'hermes', 'commandcode', 'devin', 'muse', 'amp', 'kilo', 'grok', 'copilot', 'agy', 'claude'])
const engineNames = { codex: 'Codex', claude: 'Claude', opencode: 'OpenCode', cursor: 'Cursor', terminal: 'Terminal', pi: 'Pi', hermes: 'Hermes', copilot: 'Copilot', gemini: 'Gemini' }
function createRow(row) {
  const tr = element('tr'); tr.dataset.id = row.id
  tr.onclick = () => { state.selected = row.id; select(); dom.grid.focus({ preventScroll: true }) }
  tr.ondblclick = event => { if (!event.target.closest('button')) inspect(row.id) }
  for (const col of activeColumns()) {
    const td = element('td', null, col.numeric ? 'numeric' : ''); td.dataset.key = col.key
    if (col.key === 'name') td.append(element('strong'))
    if (col.key === 'activity') { const span = element('span', null, 'status'); span.append(element('span', null, 'mark'), element('span')); td.append(span) }
    if (col.key === 'engine') {
      const span = element('span', null, 'engine'), img = element('img'); img.alt = ''; img.hidden = true
      span.append(img, element('span')); td.append(span)
    }
    tr.append(td)
  }
  const actions = element('td', null, 'row-actions'), close = element('button', null, 'close-harness')
  close.type = 'button'
  const mark = element('span', '×'); mark.setAttribute('aria-hidden', 'true'); close.append(mark)
  close.onclick = event => { event.stopPropagation(); state.selected = row.id; select(); reviewStop(row.id) }
  actions.append(close); tr.append(actions)
  return tr
}
function updateRow(tr, row) {
  for (const td of tr.children) {
    const key = td.dataset.key, col = COLUMNS.find(c => c.key === key)
    if (td.classList.contains('row-actions')) {
      const close = td.firstChild
      close.disabled = !canStop(row)
      close.setAttribute('aria-label', 'Close ' + row.name)
      close.title = state.busy.has(row.id) ? 'Closing…' : state.frozen ? 'Turn on live updates before closing.'
        : !state.connected || !currentSnapshot() ? 'Reconnect before closing.'
        : row.unavailable || (row.canStop ? 'Close ' + row.name : 'This harness is not ready to close.')
      close.setAttribute('aria-busy', String(state.busy.has(row.id)))
    } else if (key === 'name') {
      text(td.children[0], row.name)
      td.title = [row.name, row.home, row.model].filter(Boolean).join('\n')
    } else if (key === 'activity') {
      const [mark, label] = ACTIVITY[row.activity] || ACTIVITY.unknown
      td.firstChild.className = 'status ' + row.activity; text(td.firstChild.children[0], mark); text(td.firstChild.children[1], label)
      td.title = row.activityKnown || ['offline', 'starting', 'failed'].includes(row.activity) ? label : 'The owning daemon has not reported activity.'
    } else if (key === 'engine') {
      const img = td.firstChild.children[0], icon = iconNames.has(row.engine) ? row.engine : null
      img.hidden = !icon; img.className = ['cursor', 'opencode', 'grok', 'copilot'].includes(icon) ? 'dark-tile' : ''
      if (icon && img.getAttribute('src') !== 'icons/' + icon + '.png') img.src = 'icons/' + icon + '.png'
      text(td.firstChild.children[1], engineNames[row.engine] || row.engine || '—')
    } else {
      text(td, formatValue(key, row[key]))
      td.classList.toggle('unknown', row[key] == null)
      td.title = row[key] == null ? (col.help || col.label) + '\nThis reading is unavailable.'
        : ['lastActivity', 'createdAt'].includes(key) ? new Date(row[key]).toLocaleString()
        : col.numeric ? Number(row[key]).toLocaleString() + '\n' + (col.help || col.label) : String(row[key])
    }
  }
}
const currentSelection = () => state.shown.find(r => r.id === state.selected)
const currentSnapshot = () => ['ok', 'degraded'].includes(state.snapshot?.status)
const canStop = row => row?.canStop && isLive(row) && state.connected && currentSnapshot() && !state.frozen && !state.busy.has(row.id)
function select() {
  for (const [id, node] of state.nodes) node.setAttribute('aria-selected', String(id === state.selected))
  dom.inspect.disabled = !currentSelection()
}
const totalText = (total, formatter) => total.value == null ? '—' : (total.partial ? '≥' : '') + formatter(total.value)
function summary() {
  const rows = state.shown
  const shared = (state.snapshot?.shared ?? []).filter(s => s.online && rows.some(r => r.machineId === s.machineId && s.agentIds.includes(r.agentId)))
  const resources = [...rows, ...shared]
  dom.summary.replaceChildren()
  for (const [label, total, format, hint] of [
    ['CPU', sumReading(resources, 'cpu'), n => Math.round(n) + '%', '100% is one core. Shared servers count once.'],
    ['RAM', sumReading(resources, 'rssBytes'), memory, 'Resident memory including child processes and shared servers once. Shared memory pages can overlap.'],
    ['GPU', sumReading(resources, 'gpuPercent'), n => Math.round(n) + '%', 'Harness process GPU use on supported macOS and Linux NVIDIA drivers. First samples and unavailable counters show —. Cloud model GPU usage is not reported.'],
    ['SSD', storageTotal(rows.map(r => r.online === false ? { ...r, workspaceBytes: null } : r)), bytes, 'Workspace disk space. Shared and nested folders count once per machine. Stopping does not delete files.'],
    ['Tokens', sumReading(rows, 'tokens'), number, 'Conversation totals for shown sessions. Cached input is included once.'],
  ]) {
    const item = element('div', null, 'total'); item.title = hint + ' ≥ means a partial total.'
    item.append(element('span', label), element('strong', totalText(total, format))); dom.summary.append(item)
  }
  const scope = element('p', `${(!state.connected || !currentSnapshot()) && !state.frozen ? 'Last harness readings' : 'Shown harnesses only'} · ≥ partial · — unavailable`, 'summary-scope'); dom.summary.append(scope)
  dom.shared.hidden = !shared.length; text(dom.sharedTitle, shared.length + ' shared ' + (shared.length === 1 ? 'server' : 'servers') + ' included once')
  dom.sharedBody.replaceChildren()
  for (const server of shared) {
    const row = element('div', null, 'shared-row')
    row.append(element('strong', server.name), element('span', server.machine), element('span', `${server.agentIds.length} sessions`),
      element('span', formatValue('cpu', server.cpu) + ' CPU'), element('span', memory(server.rssBytes) + ' RAM'))
    dom.sharedBody.append(row)
  }
}
function render() {
  const { scrollTop, scrollLeft } = dom.grid
  state.shown = visibleRows(state.rows, state)
  const ids = new Set(state.shown.map(r => r.id))
  for (const [id, node] of state.nodes) if (!ids.has(id)) { node.remove(); state.nodes.delete(id) }
  if (state.selected && !ids.has(state.selected)) state.selected = null
  let at = dom.body.firstChild
  for (const row of state.shown) {
    let node = state.nodes.get(row.id)
    if (!node) { node = createRow(row); state.nodes.set(row.id, node) }
    updateRow(node, row); if (at !== node) dom.body.insertBefore(node, at); at = node.nextSibling
  }
  select(); dom.grid.scrollTop = scrollTop; dom.grid.scrollLeft = scrollLeft
  for (const th of dom.head.querySelectorAll('th')) {
    const col = COLUMNS.find(c => c.key === th.dataset.key)
    if (!col) continue
    th.setAttribute('aria-sort', state.sort === col.key ? (state.direction === 1 ? 'ascending' : 'descending') : 'none')
    text(th.firstChild, col.label + (state.sort === col.key ? (state.direction === 1 ? ' ↑' : ' ↓') : ''))
  }
  for (const button of document.querySelectorAll('[data-preset]')) button.setAttribute('aria-pressed', String(button.dataset.preset === state.preset))
  const ready = state.snapshot && state.snapshot.status !== 'starting'
  dom.empty.hidden = state.shown.length > 0
  const filtered = state.query || state.machine !== 'all' || state.filter !== 'all'
  text(dom.empty.firstElementChild, !ready ? 'Connecting to your machines…' : filtered ? 'No matching harnesses' : 'No open harnesses')
  text(dom.empty.lastElementChild, !ready ? 'Open harnesses will appear here.' : filtered ? 'Try another search, machine, or status.' : 'Harnesses appear here while they are open, including when idle.')
  const active = state.rows.filter(isLive).length
  text(dom.count, `${filtered ? state.shown.length + ' of ' : ''}${active} open ${active === 1 ? 'harness' : 'harnesses'}`)
  text(dom.updated, state.frozen ? 'Updates frozen' : state.receivedAt ? 'Updated ' + age(state.receivedAt) : 'Connecting…')
  text(dom.live, state.frozen ? 'Frozen' : !state.connected ? 'Reconnecting' : state.snapshot?.status === 'starting' ? 'Connecting' : !currentSnapshot() ? 'Unavailable' : 'Live')
  dom.live.classList.toggle('inactive', state.frozen || !state.connected || !currentSnapshot())
  if (ready) summary()
  if (dom.inspector.open) renderInspector()
}
function inspect(id) {
  const row = state.rows.find(r => r.id === id); if (!row) return
  state.inspecting = id; renderInspector(); dom.inspector.showModal()
}
function renderInspector() {
  const row = state.rows.find(r => r.id === state.inspecting)
  dom.inspectStop.disabled = !canStop(row)
  if (!row) { text(dom.inspectContext, 'This harness is no longer open.'); return }
  text(dom.inspectTitle, row.name)
  text(dom.inspectContext, [engineNames[row.engine] || row.engine, row.machine, ACTIVITY[row.activity]?.[1]].filter(Boolean).join(' · '))
  dom.inspectContent.replaceChildren()
  for (const group of ['Resources', 'AI usage', 'Session']) {
    const section = element('section', null, 'inspect-section'); section.append(element('h3', group)); const dl = element('dl')
    for (const col of COLUMNS.filter(c => c.group === group && !['name', 'activity', 'engine', 'machine'].includes(c.key))) {
      const label = element('dt', col.label), value = element('dd', formatValue(col.key, row[col.key])); label.title = col.help || col.label
      dl.append(label, value)
    }
    section.append(dl); dom.inspectContent.append(section)
  }
  const processes = element('section', null, 'inspect-section processes'); processes.append(element('h3', 'Process tree'))
  processes.append(element('p', 'Owned processes and children; nested harnesses and shared servers are counted separately.'))
  if (!row.processes?.length) processes.append(element('p', 'Process details are unavailable on this machine.', 'muted'))
  else {
    const table = element('table'), head = element('tr')
    for (const title of ['PID', 'Parent PID', 'CPU', 'RAM']) head.append(element('th', title))
    const tbody = element('tbody'); table.append(head, tbody)
    for (const process of row.processes) {
      const tr = element('tr')
      for (const value of [process.pid, process.parent, formatValue('cpu', process.cpuPercent), memory(process.memoryBytes)]) tr.append(element('td', value))
      tbody.append(tr)
    }
    processes.append(table)
    if (row.processCount > row.processes.length) processes.append(element('p', `Showing ${row.processes.length} of ${row.processCount} processes.`, 'muted'))
  }
  dom.inspectContent.append(processes)
  const notes = element('p', 'GPU readings describe attributable processes on the owning machine, not a cloud model. Storage includes existing workspace files and remains after stopping. Missing readings are unavailable, not zero.', 'muted metric-note')
  dom.inspectContent.append(notes)
}
function reviewStop(id) {
  const row = state.rows.find(r => r.id === id); if (!canStop(row)) return
  state.review = { id: row.id, sessionId: row.sessionId, lastActivity: row.lastActivity, name: row.name }
  text(dom.stopTitle, 'Close “' + row.name + '”?')
  text(dom.stopContext, `${row.machine} · ${ACTIVITY[row.activity]?.[1] || 'Unknown'} · ${memory(row.rssBytes)} RAM · ${number(row.tokens)} tokens`)
  text(dom.stopResult, ''); dom.stopConfirm.disabled = false; dom.stopCancel.disabled = false
  dom.stopDialog.showModal()
}
dom.inspect.onclick = () => inspect(state.selected)
dom.inspectStop.onclick = () => reviewStop(state.inspecting)
dom.inspectClose.onclick = () => dom.inspector.close()
dom.stopCancel.onclick = () => dom.stopDialog.close()
dom.stopDialog.addEventListener('cancel', event => { if (state.busy.has(state.review?.id)) event.preventDefault() })
dom.stopConfirm.onclick = async () => {
  const review = state.review
  if (!review || state.busy.has(review.id)) return
  const row = state.rows.find(r => r.id === review.id)
  if (!canStop(row) || row.sessionId !== review.sessionId) {
    text(dom.stopResult, 'This session or connection changed. Cancel, refresh and review it again.')
    dom.stopConfirm.disabled = true
    return
  }
  state.busy.add(review.id); dom.stopConfirm.disabled = true; dom.stopCancel.disabled = true; text(dom.stopResult, 'Closing…'); render()
  try {
    const reply = await post('/api/act', { verb: 'stop', ids: [review.id], manual: true, expected: [review] })
    const result = reply.results?.find(r => r.id === review.id)
    if (!result?.ok) { text(dom.stopResult, result?.detail || 'Close was not confirmed. Refresh to check.'); return }
    state.rows = state.rows.filter(r => r.id !== review.id || r.sessionId !== review.sessionId)
    message('Closed ' + review.name + '. History and files kept.'); dom.stopDialog.close()
    if (dom.inspector.open && state.inspecting === review.id) dom.inspector.close()
    dom.grid.focus({ preventScroll: true })
  } catch (error) { text(dom.stopResult, error.message + ' Refresh to check before trying again.') }
  finally { state.busy.delete(review.id); dom.stopCancel.disabled = false; render() }
}
dom.search.oninput = () => { state.query = dom.search.value; render() }
dom.filter.onchange = () => { state.filter = dom.filter.value; render() }
dom.machine.onchange = () => { state.machine = dom.machine.value; render() }
dom.grid.onkeydown = event => {
  if (event.target.closest('button') || event.target.classList.contains('resize')) return
  if (['ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) {
    event.preventDefault(); const index = state.shown.findIndex(r => r.id === state.selected)
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? state.shown.length - 1 : Math.max(0, Math.min(state.shown.length - 1, index + (event.key === 'ArrowUp' ? -1 : 1)))
    state.selected = state.shown[next]?.id ?? null; select(); state.nodes.get(state.selected)?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  } else if (event.key === 'Enter' && state.selected) { event.preventDefault(); inspect(state.selected) }
  else if (['Delete', 'Backspace'].includes(event.key) && state.selected) { event.preventDefault(); reviewStop(state.selected) }
}
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && dom.columns.open) { dom.columns.open = false; dom.columns.querySelector('summary').focus() }
  if ((event.key === '/' || ((event.metaKey || event.ctrlKey) && event.key === 'f')) && !document.querySelector('dialog[open]') && !['INPUT', 'TEXTAREA', 'SELECT'].includes(event.target.tagName)) { event.preventDefault(); dom.search.focus() }
})
document.addEventListener('pointerdown', event => { if (!dom.columns.contains(event.target)) dom.columns.open = false })
dom.refresh.onclick = async () => {
  dom.refresh.disabled = true
  try { await post('/api/refresh', {}); message(state.frozen ? 'New readings ready. Live updates to display them.' : '') } catch (error) { message(error.message) }
  finally { dom.refresh.disabled = false }
}
dom.freeze.onclick = () => {
  state.frozen = !state.frozen; text(dom.freeze, state.frozen ? 'Live updates' : 'Freeze updates'); dom.freeze.setAttribute('aria-pressed', String(state.frozen))
  if (!state.frozen && state.pending) { applySnapshot(state.pending); state.pending = null }
  render()
}
function applySnapshot(snapshot) {
  state.snapshot = snapshot; state.rows = (snapshot.rows ?? []).filter(isLive); state.receivedAt = Date.now()
  const machines = new Map((snapshot.machines ?? []).map(m => [m.machineId, m.name]))
  for (const row of state.rows) machines.set(row.machineId, row.machine)
  const signature = JSON.stringify([...machines])
  if (dom.machine.dataset.signature !== signature) {
    dom.machine.dataset.signature = signature; dom.machine.replaceChildren(new Option('All machines', 'all'))
    for (const [id, name] of machines) dom.machine.append(new Option(name, id))
    if (!machines.has(state.machine)) state.machine = 'all'
    dom.machine.value = state.machine
  }
  dom.problems.hidden = !snapshot.problems?.length
  text(dom.problems, (snapshot.problems ?? []).map(p => p.machine + ': ' + String(p.error ?? 'Unavailable').replace('Offline — showing the last known sessions.', 'Offline — reconnect to view open harnesses.')).join(' · '))
  render()
}
let stream
function connect() {
  if (stream || document.hidden) return
  stream = new EventSource('/events')
  stream.addEventListener('snapshot', event => {
    try {
      const snapshot = JSON.parse(event.data); state.connected = true
      if (dom.message.textContent.startsWith('Readings are stale.')) message('')
      if (state.frozen) state.pending = snapshot; else applySnapshot(snapshot)
    } catch { message('Could not read the monitor update. Refresh and try again.') }
  })
  stream.onerror = () => { state.connected = false; message('Connection interrupted. Showing last readings; reconnecting…'); render() }
  stream.onopen = () => { if (dom.message.textContent.startsWith('Connection interrupted.')) message('') }
}
document.addEventListener('visibilitychange', () => { if (document.hidden) { stream?.close(); stream = null; state.connected = false } else connect() })
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)')
setInterval(() => {
  if (document.hidden || reducedMotion.matches || state.frozen || !state.connected) return
  const mark = SPINNER[Math.floor(Date.now() / 100) % SPINNER.length]
  for (const node of dom.body.querySelectorAll('.working .mark')) text(node, mark)
}, 100)
setInterval(() => {
  if (document.hidden || state.frozen || !state.receivedAt) return
  if (state.connected && Date.now() - state.receivedAt > 45_000) {
    state.connected = false; message('Readings are stale. Showing the last update; refresh to reconnect.')
  }
  render()
}, 10_000)
columnMenu(); buildColumns(); connect()
