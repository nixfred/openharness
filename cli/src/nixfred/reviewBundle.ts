/**
 * Review and incident bundles: everything a second pair of eyes needs about one task, in a static
 * folder and tarball, with secrets redacted and a manifest of hashes. No live terminal, no full
 * Larry history, nothing under .ssh or .env, nothing carrying a private key.
 */
import { createHash } from 'node:crypto'
import { redactSecrets } from './redact.js'
import type { Checkpoint } from './taskCheckpoint.js'

export interface BundleDeps {
  exec(cmd: string, args: string[], opts: { cwd: string }): Promise<string>
  writeFile(path: string, data: string): Promise<void>
  readFile(path: string): Promise<string>
  mkdir(path: string): Promise<void>
  now(): number
  machine: string
}

export interface BundleInput {
  agentId: string
  cwd: string
  brief?: string
  checkpointPath?: string
  transcriptPath?: string
  auditPath?: string
  outDir: string
}

export interface BundleManifest {
  version: 1
  agentId: string
  machine: string
  at: number
  files: Record<string, { sha256: string; bytes: number }>
  redactions: number
  excluded: string[]
}

const FORBIDDEN_PATH = /(^|\/)(\.ssh|\.env)(\/|$)|\.env\./
const FORBIDDEN_CONTENT = /BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY/

const sha256 = (s: string) => createHash('sha256').update(s).digest('hex')

async function tryRead(deps: BundleDeps, path?: string): Promise<string | null> {
  if (!path) return null
  try { return await deps.readFile(path) } catch { return null }
}

function lastLines(text: string, n: number): string {
  const lines = text.split('\n')
  return lines.slice(Math.max(0, lines.length - n)).join('\n')
}

export async function buildReviewBundle(deps: BundleDeps, input: BundleInput): Promise<{ dir: string; tarball: string; manifest: BundleManifest }> {
  const at = deps.now()
  const dir = `${input.outDir}/review-${input.agentId}-${at}`
  await deps.mkdir(dir)
  const files: BundleManifest['files'] = {}
  const excluded: string[] = []
  let redactions = 0

  const put = async (name: string, content: string, sourcePath?: string): Promise<void> => {
    if (sourcePath && FORBIDDEN_PATH.test(sourcePath)) { excluded.push(sourcePath); return }
    if (FORBIDDEN_CONTENT.test(content)) { excluded.push(sourcePath ?? name); return }
    const r = redactSecrets(content)
    redactions += r.redactionCount
    await deps.writeFile(`${dir}/${name}`, r.text)
    files[name] = { sha256: sha256(r.text), bytes: Buffer.byteLength(r.text) }
  }

  let checkpoint: Checkpoint | null = null
  const cpText = await tryRead(deps, input.checkpointPath)
  if (cpText) { try { checkpoint = JSON.parse(cpText) as Checkpoint } catch { checkpoint = null } }
  const brief = input.brief ?? checkpoint?.brief ?? '(no brief recorded)'

  let patch = ''
  let diffStat = ''
  try { patch = await deps.exec('git', ['-C', input.cwd, 'diff', '--binary', 'HEAD'], { cwd: input.cwd }) } catch { patch = '' }
  try { diffStat = await deps.exec('git', ['-C', input.cwd, 'diff', '--stat', 'HEAD'], { cwd: input.cwd }) } catch { diffStat = '' }
  if (!patch && checkpoint) patch = (await tryRead(deps, checkpoint.patchFile)) ?? ''

  await put('README.md', [
    `# Review bundle: ${input.agentId}`, '',
    `- machine: ${deps.machine}`, `- created: ${new Date(at).toISOString()}`, `- cwd: ${input.cwd}`,
    ...(checkpoint ? [`- checkpoint: ${new Date(checkpoint.at).toISOString()} on ${checkpoint.machine}, ${checkpoint.git.branch}@${checkpoint.git.head.slice(0, 12)}`] : []),
    '', '## Brief', brief, '',
    ...(checkpoint?.decisions.length ? ['## Decisions', ...checkpoint.decisions.map((d) => `- ${d}`), ''] : []),
    '## Contents', '- patch.diff: uncommitted changes', '- diffstat.txt', '- transcript.txt: last 200 lines, redacted', '- audit.jsonl: last 200 journal lines', '- manifest.json: sha256 of every file',
  ].join('\n') + '\n')
  await put('patch.diff', patch)
  await put('diffstat.txt', diffStat)
  const transcript = await tryRead(deps, input.transcriptPath)
  if (transcript !== null) await put('transcript.txt', lastLines(transcript, 200), input.transcriptPath)
  const audit = await tryRead(deps, input.auditPath)
  if (audit !== null) await put('audit.jsonl', lastLines(audit, 200), input.auditPath)

  const manifest: BundleManifest = { version: 1, agentId: input.agentId, machine: deps.machine, at, files, redactions, excluded }
  await deps.writeFile(`${dir}/manifest.json`, JSON.stringify(manifest, null, 2) + '\n')
  const tarball = `${dir}.tar.gz`
  await deps.exec('tar', ['czf', tarball, '-C', input.outDir, dir.slice(input.outDir.length + 1)], { cwd: input.outDir })
  return { dir, tarball, manifest }
}
