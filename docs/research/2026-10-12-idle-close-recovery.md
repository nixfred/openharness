# Idle Close during native recovery

Automatic cleanup could read an old idle parser and an empty composer while
native admission or interpretation was held. Close now checks the live original
pane and evidence before and after each asynchronous read. Identity, admission
and interpretation holds mean unknown activity. Explicit Close now remains an
explicit request; it still must retain the original conversation safely.

The permission also reaches the actual Stop boundaries. A tmux notification
queue cannot outlive it, and an unconfirmed pane result cannot retire the row.
A lost transcript proof keeps its retryable identity error. A late idle-only
revocation retains the same Close-after-task request as waiting, so recovery can
complete it without a new request. Once revoked, an old attempt cannot resume
just because the hold clears.

The regression composes automatic cleanup, Close, the real Stop service, tmux
backend and notification gate with fixture native readings and mocked OS I/O.
Eleven initial activity assertions and five physical-boundary assertions failed
before their fixes. Ten deliberate mutations cover the guards and retry behavior.
Private daemon cases cover Claude Code and Codex queued Close through unavailable
history, recovery, and ordinary Close/resume and agent cleanup. Exact validation
receipts and the independent review belong in the PR body.

This fix is isolated from draft #1172. It does not activate its unfinished native
turn controller or durable Cancel/rearm path. The optional recovery gate allows
that integration to supply its own authority later; current main uses its registry
holds. The owner requested this finished fix be merged and further daemon work
paused afterward. No release is authorized.

Work on this correction began October 12 at approximately 08:06 UTC. Implementation,
validation, independent review/CI waiting and merge are accounted for separately
in the PR. Publication is zero.
