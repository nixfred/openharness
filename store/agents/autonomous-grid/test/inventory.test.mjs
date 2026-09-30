import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import {
  defaultRoots, joinedGrids, modelFamily, parseListDevices, parseListeningPorts, parseMeminfo, parseNetstatListening,
  parseProcNetTcp, parseSwapUsage, parseVmStat,
  probeEngines, readGguf, scanModels, summarize, summarizeGguf,
} from '../lib/inventory.mjs';

const u32 = n => { const b = Buffer.alloc(4); b.writeUInt32LE(n); return b; };
const u64 = n => { const b = Buffer.alloc(8); b.writeBigUInt64LE(BigInt(n)); return b; };
const str = s => Buffer.concat([u64(Buffer.byteLength(s)), Buffer.from(s)]);
const kv = {
  string: (key, value) => Buffer.concat([str(key), u32(8), str(value)]),
  u32: (key, value) => Buffer.concat([str(key), u32(4), u32(value)]),
  i32s: (key, list) => Buffer.concat([str(key), u32(9), u32(5), u64(list.length), ...list.map(u32)]),
  strings: (key, list) => Buffer.concat([str(key), u32(9), u32(8), u64(list.length), ...list.map(str)]),
};
const gguf = (pairs, tensorTypes = [12]) => Buffer.concat([
  Buffer.from('GGUF'), u32(3), u64(tensorTypes.length), u64(pairs.length), ...pairs,
  ...tensorTypes.map((type, i) => Buffer.concat([str(`blk.${i}.weight`), u32(2), u64(4), u64(4), u32(type), u64(0)])),
]);
const put = async (path, data) => { await mkdir(dirname(path), { recursive: true }); await writeFile(path, data); };
const tiny = arch => gguf([kv.string('general.architecture', arch), kv.u32(`${arch}.block_count`, 2)]);

test('hybrid attention caches KV only on its full-attention layers; foreign tensor types are flagged', async () => {
  const file = join(await mkdtemp(join(tmpdir(), 'gguf-')), 'qwen.gguf');
  await writeFile(file, gguf([
    kv.string('general.architecture', 'qwen35'), kv.string('general.size_label', '4B'),
    kv.strings('tokenizer.ggml.tokens', Array.from({ length: 5000 }, (_, i) => `token-${i}`)),
    kv.u32('qwen35.block_count', 32), kv.u32('qwen35.context_length', 262144),
    kv.u32('qwen35.attention.head_count', 16), kv.u32('qwen35.attention.head_count_kv', 4),
    kv.u32('qwen35.attention.key_length', 256), kv.u32('qwen35.attention.value_length', 256),
    kv.u32('qwen35.full_attention_interval', 4),
    kv.string('tokenizer.chat_template', '{% if tools %}<tools>{% endif %}{% if enable_thinking %}<think>{% endif %}'),
  ], [12, 143]));
  const summary = summarizeGguf(await readGguf(file));
  // llama.cpp measured 1024 MiB for 32768 cells on 8 layers of Qwen3.5-4B: 32 KiB per token.
  assert.equal(summary.kvBytesPerToken, 32768);
  assert.equal(summary.kvBasis, 'f16 cache');
  assert.deepEqual([summary.architecture, summary.parameters, summary.contextLength], ['qwen35', '4B', 262144]);
  assert.equal(summary.toolCalls, true);
  assert.equal(summary.thinking, true);
  assert.deepEqual(summary.unsupportedTensorTypes, [143]);
});

test('per-layer KV heads count only the attention layers, and non-GGUF files are ignored', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'gguf-'));
  await writeFile(join(dir, 'lfm.gguf'), gguf([
    kv.string('general.architecture', 'lfm2'), kv.u32('lfm2.block_count', 6), kv.u32('lfm2.embedding_length', 1024),
    kv.u32('lfm2.attention.head_count', 16), kv.i32s('lfm2.attention.head_count_kv', [0, 0, 8, 0, 8, 0]),
  ]));
  assert.equal(summarizeGguf(await readGguf(join(dir, 'lfm.gguf'))).kvBytesPerToken, 16 * (64 + 64) * 2);
  await writeFile(join(dir, 'blob'), 'not a model');
  assert.equal(await readGguf(join(dir, 'blob')), null);
});

test('scan finds models other apps downloaded, names them, and reports one entry per real file', async () => {
  const home = await mkdtemp(join(tmpdir(), 'home-'));
  const ollama = join(home, '.ollama', 'models');
  await put(join(ollama, 'blobs', 'sha256-aaa'), tiny('qwen2'));
  await put(join(ollama, 'manifests', 'registry.ollama.ai', 'library', 'qwen2.5', '0.5b'),
    JSON.stringify({ layers: [{ mediaType: 'application/vnd.ollama.image.model', digest: 'sha256:aaa' }] }));
  await mkdir(join(home, '.grid', 'models'), { recursive: true });
  await symlink(join(ollama, 'blobs', 'sha256-aaa'), join(home, '.grid', 'models', 'qwen2.5-0.5b.gguf'));
  const studio = join(home, '.lmstudio', 'models', 'publisher', 'repo');
  await put(join(studio, 'Model-7B-Q4_K_M.gguf'), tiny('llama'));
  await put(join(studio, 'mmproj-Model-7B-F16.gguf'), tiny('clip'));
  const snapshot = join(home, '.cache', 'huggingface', 'hub', 'models--mlx-community--Tiny-4bit', 'snapshots', 'abc');
  await put(join(snapshot, 'config.json'), JSON.stringify({ architectures: ['Qwen2ForCausalLM'], quantization: { bits: 4, group_size: 64 } }));
  await put(join(snapshot, 'model.safetensors'), 'weights');
  await put(join(home, 'models', 'plain', 'config.json'), JSON.stringify({ architectures: ['LlamaForCausalLM'], max_position_embeddings: 8192 }));
  await put(join(home, 'models', 'plain', 'model-00001-of-00001.safetensors'), 'weights');
  await put(join(home, 'Downloads', 'notes.txt'), 'not a model');

  const { models } = await scanModels({ roots: defaultRoots({}, home).filter(root => root.path.startsWith(home)), minBytes: 0 });
  const byName = Object.fromEntries(models.map(model => [model.name, model]));
  assert.equal(models.length, 4);
  assert.equal(byName['qwen2.5-0.5b'].source, 'grid');
  assert.deepEqual(byName['qwen2.5-0.5b'].alsoAt.map(seen => [seen.source, seen.name]), [['ollama', 'qwen2.5:0.5b']]);
  assert.equal(byName['Model-7B-Q4_K_M'].quant, 'Q4_K_M');
  assert.match(byName['Model-7B-Q4_K_M'].projector, /mmproj-Model-7B-F16\.gguf$/);
  assert.equal(byName['mlx-community/Tiny-4bit'].format, 'mlx');
  assert.equal(byName['mlx-community/Tiny-4bit'].config.quantization, '4-bit');
  assert.equal(byName.plain.format, 'safetensors');
  assert.ok(byName.plain.readableBy.includes('vllm'));
  assert.ok(byName['qwen2.5-0.5b'].readableBy.includes('llama.cpp'));
  assert.equal(byName['mlx-community/Tiny-4bit'].complete, true);
});

test('a model folder says whether every weight file is really there, following the cache links to the blobs', async () => {
  const home = await mkdtemp(join(tmpdir(), 'home-'));
  const hub = join(home, '.cache', 'huggingface', 'hub');
  const done = join(hub, 'models--org--Done-4bit', 'snapshots', 'a');
  await put(join(hub, 'models--org--Done-4bit', 'blobs', 'b1'), 'weights-1');
  await put(join(done, 'config.json'), JSON.stringify({ quantization: { bits: 4 } }));
  await put(join(done, 'model.safetensors.index.json'), JSON.stringify({ weight_map: { a: 'model-1.safetensors' } }));
  await symlink(join(hub, 'models--org--Done-4bit', 'blobs', 'b1'), join(done, 'model-1.safetensors'));
  const half = join(hub, 'models--org--Half-4bit', 'snapshots', 'a');
  await put(join(half, 'config.json'), JSON.stringify({ quantization: { bits: 4 } }));
  await put(join(half, 'model.safetensors.index.json'), JSON.stringify({ weight_map: { a: 'model-1.safetensors', b: 'model-2.safetensors' } }));
  await put(join(half, 'model-1.safetensors'), 'weights-1');
  await symlink(join(hub, 'models--org--Half-4bit', 'blobs', 'never-arrived'), join(half, 'model-2.safetensors'));

  const { models } = await scanModels({ roots: [{ source: 'huggingface', path: hub }], minBytes: 1024 });
  const byName = Object.fromEntries(models.map(model => [model.name, model]));
  assert.equal(byName['org/Done-4bit'], undefined, 'a complete folder below the size floor is still noise');
  assert.equal(byName['org/Half-4bit'].complete, false);
  assert.equal(byName['org/Half-4bit'].missingFiles, 1, 'a link whose blob never arrived is missing');
  const text = summarize({ machine: { platform: 'darwin', arch: 'arm64', accelerators: [], engines: [], canRun: ['mlx-lm'], listeningPorts: [] }, engines: [], models });
  assert.match(text, /org\/Half-4bit .*download unfinished: 1 of 2 weight files missing/);
});

test('the summary table lists every model of every format, with the reasons one cannot be used', () => {
  const text = summarize({
    machine: { chip: 'Apple M1 Pro', platform: 'darwin', arch: 'arm64', memory: { totalBytes: 34e9, availableBytes: 12e9, swapUsedBytes: 11e9 },
      accelerators: [{ vendor: 'apple', name: 'Apple M1 Pro', active: true, totalBytes: 26.8e9 }], engines: [{ kind: 'ollama', version: '0.34.4' }],
      canRun: ['llama.cpp', 'mlx-lm'], listeningPorts: [8082] },
    engines: [{ kind: 'llama.cpp', url: 'http://127.0.0.1:8082/v1', models: ['lfm'] }],
    models: [
      { name: 'big-gguf', source: 'grid', format: 'gguf', bytes: 6.1e9, projector: null, alsoAt: [], readableBy: ['llama.cpp'],
        gguf: { contextLength: 262144, kvBytesPerToken: 32768, toolCalls: true, unsupportedTensorTypes: [] } },
      { name: 'odd-gguf', source: 'folder', format: 'gguf', bytes: 5.9e9, projector: null, alsoAt: [], readableBy: ['llama.cpp'],
        gguf: { contextLength: 262144, kvBytesPerToken: 65536, toolCalls: true, unsupportedTensorTypes: [143] } },
      { name: 'org/Model-9B-4bit', source: 'huggingface', format: 'mlx', bytes: 5.95e9, projector: null, alsoAt: [], readableBy: ['mlx-lm'],
        gguf: null, config: { contextLength: 262144, kvBytesPerToken: 32768, toolCalls: true } },
      { name: 'small-ctx', source: 'ollama', format: 'gguf', bytes: 0.4e9, projector: null, alsoAt: [{ source: 'lm-studio' }], readableBy: ['llama.cpp'],
        gguf: { contextLength: 32768, kvBytesPerToken: 12288, toolCalls: true, unsupportedTensorTypes: [] } },
    ],
  });
  assert.match(text, /^machine\s+Apple M1 Pro/m);
  assert.match(text, /apple Apple M1 Pro active/);
  assert.match(text, /mlx .*org\/Model-9B-4bit \(huggingface\)/, 'MLX models appear, never filtered out');
  assert.match(text, /odd-gguf .*llama\.cpp cannot load \(tensor type 143\)/);
  assert.match(text, /small-ctx \(ollama, also lm-studio\)\s+! context 32768 < 65536/);
  assert.match(text, /answering llama\.cpp http:\/\/127\.0\.0\.1:8082\/v1/);
  assert.match(text, /^joined\s+none$/m);
});

test('joined grids come from Grid run files with a live PID, whatever the relay says', async () => {
  const home = await mkdtemp(join(tmpdir(), 'grid-home-'));
  const write = async (dir, state) => { await mkdir(join(home, 'run', 'engines', dir), { recursive: true }); await writeFile(join(home, 'run', 'engines', dir, 'remote.json'), JSON.stringify(state)); };
  await write('grid-aaa', { grid_id: 'grid-aaa', pid: 111, advertise_as: [], models: ['lfm.gguf'], engines: [{ endpoint_url: null, models: ['lfm.gguf'] }] });
  await write('grid-bbb', { grid_id: 'grid-bbb', pid: 222, advertise_as: ['Coder'], models: ['/snap'], engines: [{ endpoint_url: 'http://127.0.0.1:8084/v1' }] });
  await write('grid-gone', { grid_id: 'grid-gone', pid: 333, models: ['old.gguf'] });
  await write('n1', {});
  const rows = await joinedGrids(home, { alive: pid => pid !== 333 });
  assert.deepEqual(rows.map(r => [r.gridId, r.models, r.at]).sort(), [
    ['grid-aaa', ['lfm.gguf'], null], ['grid-bbb', ['Coder'], 'http://127.0.0.1:8084/v1']]);
  assert.deepEqual(await joinedGrids(join(home, 'missing')), []);
  const text = summarize({
    machine: { platform: 'darwin', arch: 'arm64', accelerators: [], engines: [], canRun: [], listeningPorts: [] }, engines: [], models: [],
    joined: [{ grid: 'my-grid', gridId: 'grid-aaa', models: ['lfm.gguf'], at: null }],
  });
  assert.match(text, /^joined\s+my-grid serving \[lfm\.gguf\] — a join to that grid adds to what it serves \(Grid 0\.3\.53\+\)$/m);
});

test('engines are identified by what they answer, and the --at URL always carries /v1', async () => {
  const serve = routes => new Promise(resolve => {
    const server = createServer((req, res) => {
      const body = routes[req.url];
      if (!body) { res.statusCode = 404; res.end(); return; }
      res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(body));
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
  const servers = await Promise.all([
    serve({ '/v1/models': { data: [{ id: 'qwen', owned_by: 'vllm' }] } }),
    serve({ '/v1/models': { data: [{ id: 'qwen2.5:0.5b', owned_by: 'library' }] }, '/api/version': { version: '0.34.4' } }),
    serve({ '/v1/models': { models: [{ name: 'lfm' }], data: [{ id: 'lfm', owned_by: 'llamacpp' }] } }),
    serve({ '/v1/models': { data: [{ id: 'mlx-community/x' }] } }),
    serve({}),
  ]);
  try {
    const ports = servers.map(server => server.address().port);
    const found = await probeEngines(ports);
    assert.deepEqual(found.map(engine => engine.kind), ['vllm', 'ollama', 'llama.cpp', 'openai-compatible']);
    assert.ok(found.every(engine => engine.url === `http://127.0.0.1:${engine.port}/v1`));
    assert.deepEqual(found[1].models, ['qwen2.5:0.5b']);
  } finally { servers.forEach(server => server.close()); }
});

test('system readings parse the exact text macOS, Linux, lsof and llama-server print', () => {
  assert.equal(parseVmStat('Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:  10.\nPages active:  500.\nPages inactive:  20.\nPages speculative:  5.\nPages purgeable:  1.\n'), 36 * 16384);
  assert.equal(parseSwapUsage('total = 11264.00M  used = 10945.44M  free = 318.56M  (encrypted)').used, 10945.44 * 1024 ** 2);
  assert.deepEqual(parseMeminfo('MemTotal:  1000 kB\nMemAvailable:  600 kB\nSwapTotal:  200 kB\nSwapFree:  50 kB\n'), { total: 1000 * 1024, available: 600 * 1024, swapUsed: 150 * 1024 });
  assert.deepEqual(parseListDevices('Available devices:\n  MTL0: Apple M1 Pro (25559 MiB, 25558 MiB free)\n  BLAS: Accelerate (0 MiB, 0 MiB free)\n'),
    [{ id: 'MTL0', name: 'Apple M1 Pro', totalBytes: 25559 * 1024 ** 2, freeBytes: 25558 * 1024 ** 2 }]);
  assert.deepEqual(parseListeningPorts('p123\nf4\nn*:8082\nf5\nn127.0.0.1:8130\np9\nf3\nn[::1]:631\n'), [631, 8082, 8130]);
});

test('listening ports are read on Linux without lsof, and on Windows from netstat', () => {
  const proc = [
    '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode',
    '   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0 100 0 0 10 0',
    '   1: 0100007F:2328 0100007F:A1B2 01 00000000:00000000 00:00000000 00000000     0        0 12346 1 0 20 4 30 10 -1',
    '   0: 00000000000000000000000000000000:2CAA 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 1 1 0 100 0 0 10 0',
  ].join('\n');
  assert.deepEqual(parseProcNetTcp(proc), [8080, 11434], 'only LISTEN (0A) rows, IPv4 and IPv6');
  const netstat = [
    'Active Connections', '', '  Proto  Local Address          Foreign Address        State           PID',
    '  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1016',
    '  TCP    127.0.0.1:11434        0.0.0.0:0              LISTENING       4812',
    '  TCP    192.168.1.5:52100      20.1.2.3:443           ESTABLISHED     7000',
    '  TCP    [::]:1234              [::]:0                 LISTENING       5000',
    '  UDP    0.0.0.0:5353           *:*                                    2100',
  ].join('\r\n');
  assert.deepEqual(parseNetstatListening(netstat), [135, 1234, 11434]);
});

test('one model in two formats is one model, and on a Mac with mlx-lm the GGUF row points at the MLX copy', () => {
  assert.equal(modelFamily('Qwen3.5-9B-UD-Q4_K_XL'), 'qwen3.5-9b');
  assert.equal(modelFamily('mlx-community/Qwen3.5-9B-4bit'), 'qwen3.5-9b');
  assert.equal(modelFamily('qwen2.5-0.5b-instruct-q8_0'), 'qwen2.5-0.5b-instruct');
  assert.equal(modelFamily('Qwen3.5-9B-MTP-Q6_K'), 'qwen3.5-9b-mtp', 'a variant stays its own model');
  const row = (name, format, readableBy) => ({ name, source: 'x', format, bytes: 6e9, projector: null, alsoAt: [], readableBy, gguf: format === 'gguf' ? { unsupportedTensorTypes: [] } : null, config: {} });
  const models = [row('Qwen3.5-9B-UD-Q4_K_XL', 'gguf', ['llama.cpp']), row('mlx-community/Qwen3.5-9B-4bit', 'mlx', ['mlx-lm'])];
  const mac = { platform: 'darwin', arch: 'arm64', accelerators: [], engines: [{ kind: 'mlx-lm' }], canRun: ['llama.cpp', 'mlx-lm'], listeningPorts: [] };
  assert.match(summarize({ machine: mac, engines: [], models }), /Qwen3\.5-9B-UD-Q4_K_XL .*an MLX copy is on disk \(mlx-community\/Qwen3\.5-9B-4bit\)/);
  assert.doesNotMatch(summarize({ machine: { ...mac, engines: [] }, engines: [], models }), /MLX copy/, 'no MLX engine installed, no pointer');
});

test('a model no engine on this machine can run says so, instead of looking usable', () => {
  const text = summarize({
    machine: { platform: 'linux', arch: 'x86_64', accelerators: [], engines: [], canRun: ['llama.cpp', 'ollama'], listeningPorts: [] },
    engines: [],
    models: [
      { name: 'org/Model-4bit', source: 'huggingface', format: 'mlx', bytes: 5e9, projector: null, alsoAt: [], readableBy: ['mlx-lm', 'lm-studio'], config: {} },
      { name: 'model-q4', source: 'grid', format: 'gguf', bytes: 5e9, projector: null, alsoAt: [], readableBy: ['llama.cpp'], gguf: { unsupportedTensorTypes: [] } },
    ],
  });
  assert.match(text, /org\/Model-4bit .*! no engine this machine can run reads mlx \(Apple silicon only\)/);
  assert.doesNotMatch(text, /model-q4 .*no engine/);
});
