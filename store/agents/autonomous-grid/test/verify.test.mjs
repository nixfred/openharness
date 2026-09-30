import test from 'node:test';
import assert from 'node:assert/strict';
import { createLog, verifyEngine, verifyRelay } from '../lib/verify.mjs';

const json = (body, status = 200) => new Response(JSON.stringify(body), { status });
const quiet = () => {};
const instant = async () => {};

function engine({ bootFailures = 1, content = 'ok', reasoning = '', toolCall = true, seen = [], thinksFirst = false } = {}) {
  let boots = 0;
  return async (url, init = {}) => {
    const body = init.body ? JSON.parse(init.body) : null;
    seen.push({ url, body });
    if (url.endsWith('/models')) return boots++ < bootFailures ? new Response('loading', { status: 503 }) : json({ data: [{ id: 'widget' }] });
    if (body.tools) return json({ choices: [{ message: toolCall ? { tool_calls: [{ function: { name: 'read_file', arguments: '{"path":"README.md"}' } }] } : { content: 'I cannot' } }] });
    if (body.max_tokens === 128) return json({ usage: { completion_tokens: 128 }, timings: { predicted_per_second: 21.5 }, choices: [{ message: { content: 'one two' } }] });
    // A model an engine keeps thinking: 16 tokens are all reasoning, a larger budget reaches the answer.
    if (thinksFirst) return json({ choices: [{ message: body.max_tokens > 16 ? { content: 'ok', reasoning_content: 'hmm' } : { content: '', reasoning_content: 'hmm' } }] });
    return json({ choices: [{ message: { content, reasoning_content: reasoning } }] });
  };
}

test('an engine passes only after ready, listed, a real answer, a tool call and a speed reading, each narrated', async () => {
  const lines = [], seen = [];
  const result = await verifyEngine({ url: 'http://127.0.0.1:9/v1', model: 'widget', fetchImpl: engine({ seen }), log: createLog(line => lines.push(line)), sleep: instant });
  assert.equal(result.ok, true);
  assert.deepEqual(result.steps.map(step => step.name), ['ready', 'listed', 'answer', 'tool call', 'speed']);
  assert.equal(result.steps.at(-1).tokensPerSecond, 21.5);
  assert.ok(lines.some(line => /attempt 1: 503/.test(line)), 'a failed readiness attempt is shown, not hidden');
  assert.ok(lines.every(line => /^\[\+\s*\d+s\]/.test(line)), 'every line carries elapsed time');
  assert.deepEqual(seen.find(call => call.body?.max_tokens === 16).body.chat_template_kwargs, { enable_thinking: false });
});

test('a model that always thinks first passes once it answers with room to think, and says thinking stays on', async () => {
  const lines = [], seen = [];
  const result = await verifyEngine({ url: 'http://127.0.0.1:9/v1', model: 'widget', fetchImpl: engine({ bootFailures: 0, thinksFirst: true, seen }), log: createLog(line => lines.push(line)), sleep: instant });
  const answer = result.steps.find(step => step.name === 'answer');
  assert.equal(answer.ok, true);
  assert.match(answer.note, /"ok" — thinking stays on here/);
  assert.ok(lines.some(line => /only thinking came back in 16 tokens; asking once more with room for it \(1024 tokens\)/.test(line)));
  assert.deepEqual(seen.filter(call => call.body?.messages?.[0]?.content?.startsWith('Reply')).map(call => call.body.max_tokens), [16, 1024]);
});

test('thinking-only output, a missing tool call and a URL without /v1 each fail with the reason', async () => {
  const thinking = await verifyEngine({ url: 'http://127.0.0.1:9/v1', model: 'widget', fetchImpl: engine({ bootFailures: 0, content: '', reasoning: 'Let me think' }), log: quiet, sleep: instant });
  assert.equal(thinking.ok, false);
  assert.match(thinking.steps.at(-1).note, /thinking is still on/);
  const noTool = await verifyEngine({ url: 'http://127.0.0.1:9/v1', model: 'widget', fetchImpl: engine({ bootFailures: 0, toolCall: false }), log: quiet, sleep: instant });
  assert.equal(noTool.steps.at(-1).name, 'tool call');
  assert.equal(noTool.ok, false);
  const root = await verifyEngine({ url: 'http://127.0.0.1:9', model: 'widget', fetchImpl: engine(), log: quiet, sleep: instant });
  assert.match(root.steps[0].note, /must end in \/v1/);
});

test('Ollama gets its documented thinking switch; readiness gives up at its deadline', async () => {
  const seen = [];
  await verifyEngine({ url: 'http://127.0.0.1:9/v1', model: 'widget', kind: 'ollama', fetchImpl: engine({ bootFailures: 0, seen }), log: quiet, sleep: instant });
  assert.equal(seen.find(call => call.body?.max_tokens === 16).body.reasoning_effort, 'none');
  const never = await verifyEngine({ url: 'http://127.0.0.1:9/v1', model: 'widget', readyMs: 30, fetchImpl: engine({ bootFailures: Infinity }), log: quiet, sleep: instant });
  assert.equal(never.ok, false);
  assert.match(never.steps[0].note, /within/);
});

test('the relay must list the alias before one bounded answer through the grid counts', async () => {
  let polls = 0;
  const listModels = async () => ({ ok: true, models: ++polls < 3 ? ['other'] : ['other', 'widget-alias'] });
  const fetchImpl = async (url, init) => {
    assert.equal(init.headers.authorization, 'Bearer key');
    return json({ choices: [{ message: { content: 'ok' } }] });
  };
  const lines = [];
  const result = await verifyRelay({ alias: 'widget-alias', listModels, relay: { baseUrl: 'https://relay.test/v1', apiKey: 'key' }, fetchImpl, log: line => lines.push(line), sleep: instant });
  assert.equal(result.ok, true);
  assert.equal(polls, 3);
  assert.equal(lines.filter(line => /attempt \d+: .*not yet widget-alias/.test(line)).length, 2);
  const missing = await verifyRelay({ alias: 'gone', listModels: async () => ({ ok: true, models: [] }), relay: { baseUrl: 'https://relay.test/v1' }, listMs: 20, fetchImpl, log: quiet, sleep: instant });
  assert.equal(missing.ok, false);
});

test('a model registered under its raw id fails at once with the fix, instead of waiting out the deadline', async () => {
  let polls = 0;
  const result = await verifyRelay({
    alias: 'Coder', engineModel: '/Users/me/.cache/hub/snap', relay: { baseUrl: 'https://relay.test/v1' }, log: quiet, sleep: instant,
    listModels: async () => { polls++; return { ok: true, models: ['/users/me/.cache/hub/snap'] }; },
  });
  assert.equal(result.ok, false);
  assert.equal(polls, 1);
  assert.match(result.steps[0].note, /listed as \/users\/me\/\.cache\/hub\/snap, not Coder: join again with --advertise-as Coder/);
});

test('an alias the relay lists in another case passes at once, and is asked by the listed name', async () => {
  let polls = 0, asked = null;
  const result = await verifyRelay({
    alias: 'lfm2.5-vl-3b', relay: { baseUrl: 'https://relay.test/v1' }, log: quiet, sleep: instant,
    listModels: async () => { polls++; return { ok: true, models: ['LFM2.5-VL-3B', 'Qwen3-0.6B'] }; },
    fetchImpl: async (url, init) => { asked = JSON.parse(init.body).model; return json({ choices: [{ message: { content: 'ok' } }] }); },
  });
  assert.equal(result.ok, true);
  assert.equal(polls, 1);
  assert.equal(asked, 'LFM2.5-VL-3B');
});
