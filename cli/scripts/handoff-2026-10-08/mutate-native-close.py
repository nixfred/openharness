"""Native recovery holds must survive automatic cleanup and physical Stop."""
import os
from pathlib import Path
import subprocess
import sys

cli = Path(sys.argv[1]).resolve()
close = 'src/core/agents/close.ts'
service = 'src/lib/closeAgentService.ts'
spec = 'src/core/agents/closeCleanup.spec.ts'
mutations = [
    ('pending admission mistaken for idle', close, '!s.identityHold && !s.admissionHold && !s.interpretationHold',
     '!s.identityHold && !s.interpretationHold', 'automatic cleanup keeps old idle work while admissionHold'),
    ('unrecovered native process mistaken for idle', close, '&& nativeRecoveryReady(s)', '',
     'automatic cleanup keeps old idle work while recovery'),
    ('old screen adopts new native evidence', close, '&& paneReadIdentity(latest) === identity', '',
     'an idle screen from before native evidence'),
    ('hold during final screen read ignored', close,
     "const reading = await readScreen(s, screen)\n      if (!current()) return 'unknown'", 'const reading = await readScreen(s, screen)',
     'native admission starting during screen'),
    ('idle Stop discards physical revocation', service, 'if (this.deps.idleCurrent?.(latest) === false) idleRevoked = true', '',
     'automatic Stop remains revocable at dispatch'),
    ('recovery hold prevents explicit now closure', service, "if (request.mode === 'now') return true", '', 'explicit now still closes'),
    ('pane close ignores revocation while queued', 'src/lib/tmuxBackend.ts',
     '      if (current && !current()) { resolve(undefined); return }', '',
     'the real Stop path cannot remove a pane'),
    ('pane close result silently retires held work', 'src/lib/stopAgentService.ts',
     "        verifyTranscript()\n        if (!sameTarget() || options.current?.() === false) {\n          throw new AgentStopError('The harness changed while pausing. Check its current state before trying again.')\n        }\n        stoppedAgents.finishResume",
     "        verifyTranscript()\n        if (!sameTarget()) {\n          throw new AgentStopError('The harness changed while pausing. Check its current state before trying again.')\n        }\n        stoppedAgents.finishResume",
     'the real Stop path retains its row'),
    ('pane proof failure loses retryable identity hold', 'src/lib/stopAgentService.ts',
     '        if (nativeIdentityError) throw nativeIdentityError\n        if (panes.some',
     '        if (panes.some', 'the real Stop path cannot remove a pane after transcript'),
    ('late recovery hold permanently fails deferred close', service,
     "      if (code === 'STOP_UNCONFIRMED' && idleRevoked && current()) return { error: 'SESSION_NOT_IDLE', activity: 'unknown' }", '',
     'keeps the same after-task intent waiting'),
]
environment = {**os.environ, 'TZ': 'UTC', 'TMPDIR': '/tmp'}
for key in list(environment):
    if key in ['TMUX', 'TMUX_PANE'] or key.startswith('RECORD_'):
        environment.pop(key)
assert Path(environment.get('TMUX_TMPDIR', '/missing')).is_dir(), 'Private TMUX_TMPDIR is required'


def run(pattern='.'):
    return subprocess.run(['node', 'node_modules/vitest/vitest.mjs', 'run', spec, '--maxWorkers=1', '-t', pattern],
                          cwd=cli, env=environment, text=True, capture_output=True, timeout=45)


baseline = run()
if baseline.returncode:
    raise SystemExit('Baseline failed; no mutants ran.\n' + baseline.stdout + baseline.stderr)
print('Automatic cleanup and real Close composition baseline passed', flush=True)
failures = []
for label, name, before, after, pattern in mutations:
    path = cli / name
    original = path.read_text()
    assert original.count(before) == 1, (label, original.count(before))
    try:
        path.write_text(original.replace(before, after))
        result = run(pattern)
        output = result.stdout + result.stderr
        if result.returncode == 0 or 'AssertionError' not in output:
            failures.append(label)
            print(label + ': not caught by an assertion\n' + output, flush=True)
        else:
            print(label + ': caught by assertion', flush=True)
    finally:
        path.write_text(original)
if failures:
    raise SystemExit('Mutations without assertion proof: ' + ', '.join(failures))
