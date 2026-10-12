import { execFile } from 'node:child_process'

/** A process holding memory on an NVIDIA card: its pid, its executable and the bytes it holds. */
export interface GpuProcess { pid: number; name: string; bytes: number }

/** `nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits`, read:
 *  `30956, /home/me/.grid/bin/llama-server, 21769` (MiB). A line that does not read — `[N/A]` where the
 *  driver will not say — is left out. */
export function parseComputeApps(csv: string): GpuProcess[] {
  return csv.split('\n').flatMap(line => {
    const fields = line.split(',').map(field => field.trim())
    if (fields.length < 3) return []
    const pid = Number(fields[0]), mib = Number(fields[fields.length - 1])
    const name = fields.slice(1, -1).join(',')
    return Number.isInteger(pid) && pid > 0 && Number.isFinite(mib) && mib > 0 && name ? [{ pid, name, bytes: mib * 1024 ** 2 }] : []
  })
}

/** The processes computing on this machine's NVIDIA cards: none where there is no `nvidia-smi`, or it fails. */
export function nvidiaComputeApps(): Promise<GpuProcess[]> {
  return new Promise(resolve => execFile('nvidia-smi', ['--query-compute-apps=pid,process_name,used_memory', '--format=csv,noheader,nounits'],
    { timeout: 5_000 }, (error, stdout) => resolve(error ? [] : parseComputeApps(String(stdout)))))
}
