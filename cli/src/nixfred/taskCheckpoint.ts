/**
 * Portable task checkpoints: the brief, the decisions so far, the uncommitted patch and the repo
 * position, written as a folder another machine or engine can pick up. A live process cannot
 * migrate; a checkpoint is the honest alternative for closing a laptop lid mid-task.
 */
export interface CheckpointDeps {
  exec(cmd: string, args: string[], opts: { cwd: string }): Promise<string>
  writeFile(path: string, data: string): Promise<void>
  readFile(path: string): Promise<string>
  mkdir(path: string): Promise<void>
  listDir(path: string): Promise<string[]>
  now(): number
  dataDir: string
  machine: string
}

export interface CheckpointInput {
  agentId: string
  cwd: string
  brief: string
  decisions: string[]
  notes?: string
  testResultPath?: string
}

export interface Checkpoint {
  version: 1
  agentId: string
  machine: string
  at: number
  cwd: string
  brief: string
  decisions: string[]
  notes?: string
  git: { head: string; branch: string; status: string; remote?: string }
  patchFile: string
  testResult?: string
}

const stamp = (ms: number) => new Date(ms).toISOString().replace(/[:.]/g, '-')

async function git(deps: CheckpointDeps, cwd: string, args: string[]): Promise<string> {
  try { return (await deps.exec('git', ['-C', cwd, ...args], { cwd })).trimEnd() } catch { return '' }
}

export async function buildCheckpoint(deps: CheckpointDeps, input: CheckpointInput): Promise<{ dir: string; checkpoint: Checkpoint }> {
  const at = deps.now()
  const dir = `${deps.dataDir}/checkpoints/${input.agentId}/${stamp(at)}`
  await deps.mkdir(dir)
  const [head, branch, status, remote, patch] = await Promise.all([
    git(deps, input.cwd, ['rev-parse', 'HEAD']),
    git(deps, input.cwd, ['rev-parse', '--abbrev-ref', 'HEAD']),
    git(deps, input.cwd, ['status', '--short']),
    git(deps, input.cwd, ['remote', 'get-url', 'origin']),
    git(deps, input.cwd, ['diff', '--binary', 'HEAD']),
  ])
  const patchFile = `${dir}/uncommitted.patch`
  await deps.writeFile(patchFile, patch ? patch + '\n' : '')
  let testResult: string | undefined
  if (input.testResultPath) { try { testResult = await deps.readFile(input.testResultPath) } catch { /* no result yet */ } }
  const checkpoint: Checkpoint = {
    version: 1, agentId: input.agentId, machine: deps.machine, at, cwd: input.cwd, brief: input.brief,
    decisions: input.decisions, ...(input.notes ? { notes: input.notes } : {}),
    git: { head, branch, status, ...(remote ? { remote } : {}) }, patchFile, ...(testResult !== undefined ? { testResult } : {}),
  }
  await deps.writeFile(`${dir}/checkpoint.json`, JSON.stringify(checkpoint, null, 2) + '\n')
  return { dir, checkpoint }
}

export async function listCheckpoints(deps: CheckpointDeps, agentId: string): Promise<string[]> {
  const base = `${deps.dataDir}/checkpoints/${agentId}`
  try { return (await deps.listDir(base)).sort().map((d) => `${base}/${d}`) } catch { return [] }
}

/** Applies the saved patch onto `targetCwd` and returns the brief the next agent should read. */
export async function restoreCheckpoint(deps: CheckpointDeps, dir: string, targetCwd: string): Promise<{ checkpoint: Checkpoint; applied: boolean; handoff: string }> {
  const checkpoint = JSON.parse(await deps.readFile(`${dir}/checkpoint.json`)) as Checkpoint
  const patch = await deps.readFile(checkpoint.patchFile)
  let applied = false
  if (patch.trim()) {
    try { await deps.exec('git', ['-C', targetCwd, 'apply', '--3way', checkpoint.patchFile], { cwd: targetCwd }); applied = true } catch { applied = false }
  }
  const handoff = [
    `# Handoff from ${checkpoint.machine} (${new Date(checkpoint.at).toISOString()})`,
    '', '## Brief', checkpoint.brief, '',
    '## Decisions so far', ...(checkpoint.decisions.length ? checkpoint.decisions.map((d) => `- ${d}`) : ['- none recorded']), '',
    `## Repo position`, `- branch ${checkpoint.git.branch} at ${checkpoint.git.head.slice(0, 12)}`,
    `- uncommitted patch ${applied ? 'applied' : patch.trim() ? 'NOT applied (conflicts, see ' + checkpoint.patchFile + ')' : 'none'}`,
    ...(checkpoint.git.status ? ['', '## Working tree at checkpoint', '```', checkpoint.git.status, '```'] : []),
    ...(checkpoint.notes ? ['', '## Notes', checkpoint.notes] : []),
    ...(checkpoint.testResult ? ['', '## Last test result', '```', checkpoint.testResult.slice(-4000), '```'] : []),
  ].join('\n')
  return { checkpoint, applied, handoff }
}

export function describeCheckpoint(c: Checkpoint): string {
  const dirty = c.git.status ? `${c.git.status.split('\n').filter(Boolean).length} dirty files` : 'clean tree'
  return `${c.agentId}@${c.machine} ${new Date(c.at).toISOString()} ${c.git.branch}@${c.git.head.slice(0, 8)} ${dirty}, ${c.decisions.length} decisions`
}
