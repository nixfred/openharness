import { beforeEach, describe, expect, it, vi } from 'vitest'

const execFile = vi.hoisted(() => vi.fn())
vi.mock('node:child_process', () => ({ execFile }))

import { nvidiaComputeApps, parseComputeApps } from './gpuProcesses.js'

const MiB = 1024 ** 2

describe('the processes holding NVIDIA VRAM', () => {
  beforeEach(() => execFile.mockReset())

  it('reads nvidia-smi\'s compute apps, leaving out a line that does not read', () => {
    expect(parseComputeApps([
      '30956, /home/me/.grid/bin/llama-server, 21769',
      '2014, /opt/My App, Inc/app, 300',
      '99, /usr/bin/ollama, [N/A]',
      '0, /bin/zero-pid, 10',
      '12, , 10',
      'garbage',
      '',
    ].join('\n'))).toEqual([
      { pid: 30956, name: '/home/me/.grid/bin/llama-server', bytes: 21769 * MiB },
      { pid: 2014, name: '/opt/My App,Inc/app', bytes: 300 * MiB },
    ])
  })

  it('asks nvidia-smi for them, and has none where it is missing or fails', async () => {
    execFile.mockImplementationOnce((_file, _args, _options, done) => done(null, '30956, /home/me/.grid/bin/llama-server, 21769\n'))
    expect(await nvidiaComputeApps()).toEqual([{ pid: 30956, name: '/home/me/.grid/bin/llama-server', bytes: 21769 * MiB }])
    expect(execFile).toHaveBeenCalledWith('nvidia-smi', ['--query-compute-apps=pid,process_name,used_memory', '--format=csv,noheader,nounits'],
      { timeout: 5_000 }, expect.any(Function))
    execFile.mockImplementationOnce((_file, _args, _options, done) => done(Object.assign(new Error('spawn nvidia-smi ENOENT'), { code: 'ENOENT' }), ''))
    expect(await nvidiaComputeApps()).toEqual([])
  })
})
