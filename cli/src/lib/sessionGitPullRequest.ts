import type { RegisteredSession } from './registry.js'
import { agentProject } from './agentProject.js'
import { agentTokenUsage } from './agentTokenUsage.js'
import { sessionGitContext } from './sessionGitContext.js'
import { sessionGitHistory } from './sessionGitHistory.js'
import { readGitPullRequest, readPullRequestUrl } from './gitPullRequest.js'

export type ExpectedGitContext = { cwd: string; branch: string; remote: string | null }
/** The branch badge and session history share the same resolved checkout. Existing callers may
 * omit expected context; new clients bind their reply to the branch they displayed when asking. */
export async function readSessionGitPullRequest(agent: RegisteredSession, options: {
  expected?: ExpectedGitContext; history?: boolean; offset?: number;
} = {}) {
  const work = agentTokenUsage.get(agent)?.work
  let context = await sessionGitContext(await agentProject(agent.cwd), work)
  await sessionGitHistory.observe(agent, context)
  const current = context.current
  let identity = current?.branch ? { cwd: current.cwd, branch: current.branch, remote: current.remote } : null
  const matches = !options.expected || identity && options.expected.cwd === identity.cwd
    && options.expected.branch === identity.branch && options.expected.remote === identity.remote
  let result = matches && current && !current.branch?.startsWith('Detached ')
    ? identity ? await readGitPullRequest(current.cwd, identity) : await readGitPullRequest(current.cwd)
    : { status: 'unavailable' as const }
  const checkedAt = new Date().toISOString()
  if (result.status === 'found' && context.state === 'observed') for (const pr of [result, ...(result.related ?? [])]) {
    const { related: _, ...recorded } = pr
    await sessionGitHistory.recordPullRequest(agent,
      { url: pr.url, cwd: current!.cwd, at: context.observedAt ?? checkedAt }, recorded, pr.checkedAt ?? checkedAt)
  }
  const refreshMovedWork = async () => {
    const latest = agentTokenUsage.get(agent)?.work
    if (JSON.stringify(latest) === JSON.stringify(work)) return
    context = await sessionGitContext(await agentProject(agent.cwd), latest)
    await sessionGitHistory.observe(agent, context)
    const project = context.current
    identity = project?.branch ? { cwd: project.cwd, branch: project.branch, remote: project.remote } : null
    result = { status: 'unavailable' }
  }
  if (!options.history) {
    await refreshMovedWork()
    return options.expected ? { ...result, context: identity } : result
  }

  const saved = await sessionGitHistory.get(agent)
  const offset = Number.isSafeInteger(options.offset) && options.offset! >= 0 ? Math.min(options.offset!, 128) : 0
  const page = saved.pullRequests.slice(offset, offset + 4)
  const lookups = await Promise.all(page.map(async pr => {
    const answer = await readPullRequestUrl(pr.url)
    await sessionGitHistory.recordPullRequest(agent, pr, answer, answer.status === 'found' ? answer.checkedAt ?? checkedAt : checkedAt)
    return { url: pr.url, status: answer.status }
  }))
  await refreshMovedWork()
  const history = await sessionGitHistory.get(agent)
  return { ...result, context: identity, gitContext: context, history, lookups,
    nextOffset: offset + page.length < saved.pullRequests.length ? offset + page.length : null }
}
