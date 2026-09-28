# Session work, branches, and pull requests

A session has a stable name and launch workspace. Its current Git context follows
the checkout where work was most recently observed. Its PR history records output
across tasks. These identities have different lifetimes and should not be combined
into one permanent branch label.

For example, `hn` can launch in `silent-beacon`, run tools in `ship-hn/tui`, and
work on `hn/nfc` followed by `hn/preview`. The bar shows the branch Git reports for
`ship-hn`, while Work details retain both observed branches and their PRs.
`silent-beacon` remains the launch/resume workspace.

## Display and navigation

The focused app bar shows the current named branch and a separate
`#123 Open / Draft / Merged / Closed` link. A dependent viewer uses its owner's
context. Native macOS and Flutter/web use the same formatter. The branch opens
**Work** details; the PR opens GitHub. **Inspect session work** is also available
through the command picker, including when there is no branch. Older daemons
retain their existing branch-scoped search behavior.

On phone, the session menu offers **Branches and pull requests**. Both surfaces
show the current observation, launch workspace, observed branch history, and PRs
with repository, title, head/base branch, state, and check time. Open/draft work
appears before unknown and completed work. Four PRs are shown initially; Show more
expands the history. Refresh checks a bounded page; each PR keeps its own actual
GitHub check time, including when a cached answer is reused.

| Evidence | Display |
| --- | --- |
| Successful tools in one checkout | Its actual current branch |
| Several checkouts in one operation | Multiple workspaces |
| Unresolved execution or unsupported dynamic commands | Work location unknown |
| The observed directory has disappeared | Workspace unavailable |
| No tool observations yet | Session workspace, explicitly labeled in details |
| Machine offline | Last-known observations, labeled offline |

Paths and long values remain inspectable in details and accessibility text.
An unavailable lookup preserves saved PR links and their last-known status.
Nothing on this surface checks out, pushes, merges, deletes, or sends terminal input.
A push is not described as shipped; a merged PR is not evidence that a worktree
can safely be deleted.

## Evidence, privacy, and freshness

The daemon reuses its incremental Claude/Codex transcript reader. It accepts
successful literal shell/file/patch receipts, explicit tool workdirs, guarded
`cd … && …`, `git -C`, and a small static subset of Codex code-mode calls. Yielded
Codex processes/cells stay connected to passive completion polls. Concurrent
operations are ordered by their start, so a slow earlier operation cannot replace
newer work. Pending execution remains uncertain.

It never executes transcript text. Arbitrary scripts, shell substitutions,
interactive input, and unrecognized engine formats cannot establish a location.
Other engines show the registered workspace. History is explicitly partial: it
cannot reconstruct branches that were created and deleted between observations,
or receipts removed before the daemon saw them.

Registry `cwd` and the legacy `project` wire field retain launch semantics.
The additive `gitContext` carries display evidence on both list and push frames.
Daemon-scoped versions reject out-of-order snapshots without changing during
unchanged polling. PR replies are bound to checkout identity; session, machine,
focus, branch and repository changes discard stale replies.

Minimal histories live under `ADAPTER_DATA_DIR/session-git-history`, outside Git
worktrees, in private atomic JSON files. They contain validated locations, branch
observations, PR links and lookup results, never raw commands, credentials or
transcript output. Conversation identity separates histories and inherited fork
receipts are excluded. Deleting a checkout does not delete its history.

Histories retain at most 128 branches and 128 PRs per conversation, with an
explicit truncation message. Git inspection uses the existing 15-second bounded
cache. GitHub results are cached for 60 seconds; the focused badge refreshes once
a minute. Four GitHub/Git reader subprocesses can run simultaneously, with a
bounded queue and deadlines. History refreshes four saved PRs at a time. List
frames never query GitHub. Private paths travel through the existing encrypted
machine RPC.

GitHub lookup uses the owning machine's installed `gh` and existing sign-in.
Current PRs match both head repository and branch, including fork-to-parent PRs;
an open PR wins over older completed work. Every verified match can be retained
in history. Saved URLs resolve independently of deleted branches/worktrees and
follow GitHub repository renames. GitHub Enterprise and arbitrary fork-network
base repositories beyond the origin's parent are outside this reader's scope.

## Branch workflow for agents

Use one topic branch per independently reviewable change and one worktree per
concurrently edited checkout. A session can reuse its worktree for sequential
changes and keep several PRs open. Each active editing process needs its own
checkout; a shared repository still has shared refs, remotes and Git objects.

Start unrelated changes from updated `origin/main`. Deliberately stack dependent
changes, with the intended base branch made explicit. Put review fixes on the
original PR branch. After merging, retire the topic branch and create a new one
for subsequent work. Switch only after saving work and finishing processes that
still use that checkout. Keep PR history as the durable review/output record.

This follows [Git worktree semantics](https://git-scm.com/docs/git-worktree) and
[GitHub flow](https://docs.github.com/en/get-started/using-github/github-flow).
The [implementation plan and verification evidence](plans/2026-09-27-session-git-context.md)
cover the delivery contract and regression cases.
