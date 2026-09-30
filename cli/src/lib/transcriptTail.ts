import { open } from 'node:fs/promises'
import { createReadStream } from 'node:fs'
import { createInterface } from 'node:readline'

/** Return the last `n` non-empty raw lines of a specific transcript file. Prefer this over
 *  `tailLines` when the caller already holds a trusted, registered `transcriptPath` — it takes no
 *  request-controlled id, so there is no path to traverse. */
export async function tailFile(filePath: string, n = 200): Promise<string[]> {
  try {
    if (n === Infinity) {
      // A long-running session can exceed V8's maximum single-string length.
      // Keep the full-history contract, without decoding the entire file at once.
      const lines: string[] = []
      const input = createReadStream(filePath, { encoding: 'utf8' })
      const reader = createInterface({ input, crlfDelay: Infinity })
      try {
        for await (const line of reader) if (line.trim()) lines.push(line)
      } finally { reader.close(); input.destroy() }
      return lines
    }
    if (!Number.isFinite(n)) return []
    n = Math.floor(n)
    if (n <= 0) return []
    const handle = await open(filePath, 'r')
    try {
      let position = (await handle.stat()).size
      const chunks: Buffer[] = []
      let newlines = 0
      while (position > 0) {
        const size = Math.min(position, 64 * 1024)
        position -= size
        const chunk = Buffer.allocUnsafe(size)
        const { bytesRead } = await handle.read(chunk, 0, size, position)
        const read = chunk.subarray(0, bytesRead)
        chunks.unshift(read)
        for (const byte of read) if (byte === 10) newlines++
        if (newlines > n || position === 0) {
          let text = Buffer.concat(chunks).toString('utf8')
          if (position > 0) text = text.slice(text.indexOf('\n') + 1)
          const lines = text.split('\n').filter(line => line.trim())
          if (lines.length >= n || position === 0) return lines.slice(-n)
        }
      }
      return []
    } finally { await handle.close() }
  } catch {
    return []
  }
}
