# Validation and release

The release clock starts at the user's request, not at the tag. The October 2
[audit](performance/2026-10-02-release-process-audit.md) found repeated full suites,
baseline investigations, local environment failures, and waiting before publishing.
Keep a short validation plan and reuse its evidence through merge and release.

## Select the checks once

| Change | Required scope |
| --- | --- |
| Documentation or static artwork | Relevant links/schema/assets, visual inspection when the result is visual |
| Isolated CLI behavior | Typecheck, affected unit tests, relevant integration/real-engine tests |
| Isolated desktop behavior | Analyze changed Dart code, affected widget/unit tests, native/browser check for the surfaces changed |
| Shared state, authentication, protocol, dependencies, or unclear impact | Full suite for each affected component, plus relevant integration/platform checks |
| Packaging, signing, updater, or release workflow | Script/workflow checks and artifact/manifest contract checks; use a test publication when publication behavior changes |

This is an impact assessment, not a file-extension bypass. A small deletion change
can require real disposable worktrees and lifecycle tests. A resource label change
does not require retesting every unrelated engine. Keep required coverage gates.
An unavailable native engine or platform is an unverified row, never a passing one.

Use the pinned toolchain and lockfile. Check free disk space before installing,
compiling, or starting a broad suite. Do not clean other sessions' files to make room.
Run independent checks concurrently, with enough capacity for their workers;
two commands each spawning every CPU is not useful parallelism.

Manual **CI → Run workflow** accepts `scope`: `cli`, `tui`, `backend`, or `full`
(the default). `cli` includes typecheck, all CLI tests, updater coverage, release
bundle checks, and the serial/login-shell OS/Node matrix. `tui` includes its native
CLI integration tests. Select `full` for cross-component changes or uncertain impact.
The workflow remains on demand; this change does not introduce new required gates.

For repository process tooling only, `scope=process` runs its Python regression
tests without installing or building unrelated components. It does not validate
application changes. Workflow edits also need `actionlint` and a run exercising
the changed workflow behavior, such as the desktop cache preparation checks.

Desktop SDK and pub caches are prepared on `main` when their inputs change by
**Prepare desktop caches**. Run that workflow on `main` after cache eviction if
needed; it does not publish anything. Release tags restore those caches without
saving another tag-specific copy. Cache misses still install the pinned SDK and
resolve dependencies normally. macOS enables Swift Package Manager before pub get.
The shared keys include SDK version/commit, OS/architecture, and the dependency
lockfiles for pub. Signing, notarization and artifact checks remain required.

Native TUI CI tests and builds the shipped musl target in the same Cargo output
directory. Dependency caches are keyed by target, Rust toolchain, and Cargo inputs;
cache hits still run every test. The ten native TUI fixtures run two at a time,
using their own homes, socket names, and mock ports. CI retains each fixture's log
and validation receipt as an artifact. To run the same set locally after building:

```bash
python3 scripts/validate-tui-native.py tui/target/release/harness-tui
```

This needs tmux, the pinned Node runtime, and the CLI's installed dependencies.
Do not run another copy on the same host at the same time: each fixture has a
separate port, but separate invocations use the same reserved fixture ports.
TUI release platform builds run alongside unit tests. Native release checks run
against the actual Linux artifact, and publication waits for both unit tests and
all platform builds/native checks. A build-only run uses `publish=false`.

## Bound checks and preserve the result

`make validate ARGS=".harness/validation-plan.json"` runs an explicit plan, at most
two checks at once, without installing tools or retrying tests. Create a local plan
with only the checks relevant to the diff, for example:

```json
{
  "reason": "DSH doctor/materialize shell isolation: typecheck and affected behavior",
  "minimum_free_gib": 2,
  "checks": [
    {
      "name": "cli-types",
      "cwd": "cli",
      "argv": ["node", "node_modules/typescript/bin/tsc", "--noEmit"],
      "timeout_seconds": 180
    },
    {
      "name": "cli-dsh",
      "cwd": "cli",
      "argv": ["node", "node_modules/vitest/vitest.mjs", "run", "src/dsh/command.spec.ts", "src/dsh/materialize.spec.ts", "--maxWorkers=2"],
      "timeout_seconds": 180
    }
  ]
}
```

Commands use argv arrays; use separate checks for independent work. CLI and desktop
checks can run together if memory/disk allow it. Put dependent operations in separate
plans. A desktop test command should name its affected files and use
`flutter test --no-pub --concurrency=2 --timeout=60s ...`. Tests legitimately needing
longer can declare that explicitly. Start a necessary broad desktop run early, with
an outer limit (initial budget: 15 minutes); investigate a timeout instead of waiting
through multiple ten-minute stalled fixtures. Budgets are diagnostic deadlines,
not permission to turn failures into success.

The runner writes logs and `receipt.json` under ignored `.harness/validation/`.
It records source commit/tree, dirty-source fingerprint, start/end times, exit codes,
timeouts, and disk preflight. A source edit during validation invalidates the receipt.
Timeout or Ctrl-C terminates only process groups started by that invocation. Tests
remain responsible for any deliberately detached daemons. macOS/Linux are supported.
Choose a lower disk minimum only for a plan whose known requirements justify it;
the default is 2 GiB, not an estimate of a full Flutter build's needs.

## Reuse evidence without hiding regressions

Record the tested SHA/tree, toolchain, dependency lock, selected checks, results,
and links in the PR. A clean squash with the same tree preserves evidence. After a
rebase, examine the diff and rerun checks covering new interactions or conflict
resolutions. Do not reuse results across dependency/toolchain changes. A dirty
receipt identifies the tested working copy, not HEAD alone.

A passing CI run satisfies the equivalent full local check; don't repeat both
before merge and then again on the merged commit. Check the merged source identity
and rerun only validation invalidated by the merge. Native checks absent from CI
still need their own evidence.

For a failure, isolate the failing test once. If its code, fixtures, dependencies,
or environment changed, investigate it as a possible regression. Otherwise check
existing baseline evidence before starting another baseline run. Link the exact
failure, baseline SHA, and relevant file/lockfile comparison. If no valid evidence
exists, perform one bounded baseline reproduction of the affected test. Preserve
the failure as a maintenance item; a baseline failure is not a passing full suite.
Do not repeatedly run thousands of tests to rediscover it. The October 2 desktop
[baseline record](performance/2026-10-02-buffered-diagnostic-validation.json) is
historical evidence, not an allowlist: changes to those paths need fresh checks.

## Complete the authorized release

Once required checks pass, merge, verify the resulting source, and tag that source
using the existing release scripts. Do not introduce an additional full-suite phase.
For a client/server change, publish required server support before exposing clients
that need it. Independent product releases may build concurrently; preserve their
source/version compatibility and manifest publication safeguards.

Check the live version and artifact checksum, and give the user the release link
promptly. Broader maintenance testing must not silently turn into another release
gate after shipping. Record these UTC timestamps in the PR or release task:

- Request received; implementation ready; required validation started/completed.
- Merge; each product's release trigger and live publication; completion reported.
- Pauses and waiting, with their known reason. Mark missing data unknown.

For Desktop, use the existing release command with `--wait` to follow the exact
tag and source through completion:

```bash
make release-desktop ARGS="--notes-file /path/to/reviewed-notes.md --wait"
```

The workflow's `verify` job downloads all six public artifacts three at a time,
using the updater's Dart user agent, and checks every version, full SHA-256, and
size. It starts immediately after publication, alongside release-page creation.
Each transfer has a total deadline; any failure makes the workflow fail and keeps
the JSON receipt in the `desktop-release-verification` artifact. A successful
verification satisfies that release's download checks: report completion instead
of downloading everything again locally. The watcher requires this job to pass
and checks the tag's full SHA, so another release's success cannot satisfy it.

For a release made before that job existed, or to investigate a download failure:

```bash
python3 scripts/verify-desktop-release.py 1.2.51
```

This is read-only. A failed verification after publication means the release may
already be live; inspect the receipt and fix the cause rather than blindly
retagging or retrying immutable artifact uploads.

Report both total elapsed time and its stages. For small changes, aim to return to
the team's previous 10–15 minute merge/release overhead; publishing duration alone
does not demonstrate that target. At ten minutes without progress, identify the
blocked phase and its next action instead of silently extending testing. Compare
the next ten tasks using request-to-completion data before claiming an improvement.
