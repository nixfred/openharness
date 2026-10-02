// Manual native check (PTY required):
// node cli/scripts/memory-native-codex-lifecycle-probe.mjs --output <new-report.json>
// Review and trust only this disposable folder and its exact synthetic hooks through
// the native UI. Never bypass native trust or use an existing native home.
// First launch: send a synthetic coding prompt; /compact; send another prompt; /quit.
// Second (resume) and third (model change) launches: send one prompt; /quit.
// Submit prompts beginning 'Synthetic coding review request' without using tools.
// The report records each outgoing request; a marker in one request does not prove
// every request carried it. No real model, host authorization or usefulness is tested.
import { createServer } from 'node:http'
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn, execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
const engine = 'codex'
const outputIndex = process.argv.indexOf('--output')
const reportPath = outputIndex < 0 ? null : process.argv[outputIndex + 1]
if (!reportPath || reportPath.startsWith('--')) throw new Error('--output requires a new report path')
writeFileSync(reportPath, '{}\n', { flag: 'wx', mode: 0o600 })
let launch = 'first', promptNumber = 0, version = null
const runs = []
const persist = () => writeFileSync(reportPath,JSON.stringify({engine,version,launch,runs,hooks,requests},null,2))
const fixture = await mkdtemp(join(tmpdir(), 'native-memory-hooks-'))
const marker = 'coding-memory-probe-8bd9c6d4'
const contextTemplate = JSON.stringify({ type: 'coding_memory_context', notice: 'Synthetic historical context; current instructions take precedence.',
  items: [{ claim: `For coding review, prefer a tiny failing test first. ${marker}` }] })
const receiptId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
const requests = [], hooks = []
const provider = createServer(async (req, res) => {
  const chunks = []
  for await (const chunk of req) chunks.push(chunk)
  let body
  try { body = JSON.parse(Buffer.concat(chunks)) } catch { res.writeHead(200, { 'content-type': 'application/json' }).end('{}'); return }
  if (!req.url.startsWith('/v1/responses')) {
    res.writeHead(200, { 'content-type': 'application/json' }).end('{}'); return
  }
  requests.push({ launch,model:body.model, route: req.url.split('?')[0], promptNumber, markers:[...JSON.stringify(body).matchAll(/coding-memory-probe-8bd9c6d4-(\d+)/g)].map(match=>Number(match[1])), inputTypes:(body.input??[]).map(item=>({type:item.type,role:item.role,channel:item.channel})), contextReceived: JSON.stringify(body).includes(marker),
    contextRoles: (body.messages ?? body.input ?? []).filter(item => JSON.stringify(item).includes(marker)).map(item => item.role),
    promptReceived: JSON.stringify(body).includes('Synthetic coding review request'), tools: (body.tools ?? []).map(tool => tool.name ?? tool.type) })
  persist()
  if (req.url.startsWith('/v1/responses/compact')) {
    res.writeHead(200,{'content-type':'application/json'}).end(JSON.stringify({id:'cmp_fixture',object:'response.compaction',created_at:1,output:[{id:'cmp_item',type:'compaction',encrypted_content:'synthetic-opaque-compaction'}],usage:{input_tokens:100,output_tokens:10,total_tokens:110}})); return
  }
  res.writeHead(200, { 'content-type': 'text/event-stream' })
  const send = event => res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`)
    const item = { id:`msg_${randomUUID()}`,type:'message',role:'assistant',channel:'final',status:'completed',content:[{type:'output_text',text:'Synthetic response.',annotations:[]}] }
    const response = {id:`resp_${randomUUID()}`,object:'response',status:'completed',model:body.model,output:[item],usage:{input_tokens:10,output_tokens:2,total_tokens:12}}
    send({type:'response.created',response:{...response,status:'in_progress',output:[]}})
    send({type:'response.output_item.added',output_index:0,item:{...item,status:'in_progress'}})
    send({type:'response.output_text.delta',output_index:0,content_index:0,item_id:item.id,delta:'Synthetic response.'})
    send({type:'response.output_item.done',output_index:0,item})
    send({type:'response.completed',response})

  res.end()
})
const adapter = createServer(async (req, res) => {
  const chunks = []
  for await (const chunk of req) chunks.push(chunk)
  const body = JSON.parse(Buffer.concat(chunks))
  if(body.hookEvent==='UserPromptSubmit')promptNumber++
  hooks.push({launch,promptNumber,route:req.url,event:body.hookEvent,source:body.source,engine:body.engine,receipt:body.memoryReceiptId===receiptId})
  persist()
  const additionalContext=contextTemplate.replace(marker,`${marker}-${promptNumber}`)
  res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ ok: true, additionalContext, memoryReceiptId: receiptId }))
})
const listen = server => new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve) })
try {
  await Promise.all([listen(provider), listen(adapter)])
  for (const name of ['home','codex','data','work']) await mkdir(join(fixture,name), { mode:0o700 })
  await writeFile(join(fixture,'data','hook-credential'), `${'a'.repeat(43)}\n`, { mode:0o600 })
  const quote = value => `'${value.replace(/'/g, `'\\''`)}'`
  const command = [process.execPath,fileURLToPath(new URL('../hook/notify.mjs', import.meta.url)),'--port',String(adapter.address().port),'--data-dir',join(fixture,'data'),
    '--engine',engine,'--codex-home',join(fixture,'codex')].map(quote).join(' ')
  const config = { hooks: Object.fromEntries(['SessionStart','UserPromptSubmit','PreCompact','PostCompact'].map(event=>[event,[{hooks:[{type:'command',command,timeout:3}]}]])) }
  await writeFile(join(fixture,'codex','hooks.json'),JSON.stringify(config))
  const baseEnv = { PATH:process.env.PATH,HOME:join(fixture,'home'),TMPDIR:fixture,TERM:'xterm-256color',TMUX_PANE:'%424242',
    CODEX_HOME:join(fixture,'codex'),HARNESS_MEMORY_TEST_KEY:'local-test-only' }
  const disabled = ['shell_tool','unified_exec','apps','browser_use','browser_use_external','browser_use_full_cdp_access',
    'computer_use','image_generation','in_app_browser','multi_agent','plugins','remote_plugin','view_image','code_mode_host',
    'tool_suggest','workspace_dependencies','skill_search','sleep_tool','goals','memories','shell_snapshot','enable_request_compression','daemon_auto_start']
  const overrides = ['--model','gpt-5.4','--sandbox','read-only','-c','model_provider="memory_mock"',
    '-c','model_providers.memory_mock.name="Local hook test"','-c',`model_providers.memory_mock.base_url="http://127.0.0.1:${provider.address().port}/v1"`,
    '-c','model_providers.memory_mock.env_key="HARNESS_MEMORY_TEST_KEY"','-c','model_providers.memory_mock.wire_api="responses"',
    '-c','model_providers.memory_mock.requires_openai_auth=false','-c','web_search="disabled"','-c','check_for_update_on_startup=false',
    '--enable','hooks',...disabled.flatMap(feature=>['--disable',feature])]
  const args = ['--no-daemon','--no-alt-screen',...overrides]
  version = execFileSync(engine,['--version'],{encoding:'utf8',env:baseEnv,timeout:5000}).trim()
  for(const step of ['first','resume','model_change']) {
    launch=step
    const nextArgs=[...args,...(step==='first'?[]:['resume','--last'])]
    if(step==='model_change') nextArgs[nextArgs.indexOf('--model')+1]='gpt-5.4-mini'
    console.log(`\nSYNTHETIC FIXTURE ${step}; native folder and exact hook trust must be reviewed. Report: ${reportPath}\n`)
    const child=spawn(engine,nextArgs,{cwd:join(fixture,'work'),env:baseEnv,stdio:'inherit'})
    let timedOut=false
    const timer=setTimeout(()=>{timedOut=true;child.kill('SIGTERM')},240000)
    const hardTimer=setTimeout(()=>{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL')},245000)
    const result=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',(code,signal)=>resolve({code,signal}))})
    clearTimeout(timer);clearTimeout(hardTimer)
    runs.push({step,...result,timedOut});persist()
    if(result.code!==0) { process.exitCode=1; break }
  }
  console.log(JSON.stringify({reportPath,runs,requests:requests.length,hooks:hooks.length},null,2))

} finally {
  for(const server of [provider,adapter]) { server.closeAllConnections();await new Promise(resolve=>server.close(resolve)) }
  await rm(fixture,{recursive:true,force:true})
}
