# Harness Monitor

Inspect active harnesses across connected machines and decide what to stop. The workspace footer's
Harnesses, CPU, RAM, GPU and SSD controls select the existing Harness Monitor tab, creating one when
needed. The tab uses the standard 70% viewer / 30% assistant split. Use the pane Zoom icon for a full-width table. Opening the table submits no model prompt.

The table lists only currently open harnesses on connected machines, including idle, working,
waiting and starting sessions. Closed sessions and offline history never appear in this table.
Harness, Status, CPU, RAM, GPU and SSD come first, followed by Agent, Tokens,
Machine, Project and Branch. RAM is the initial default sort. Filter by machine or activity, search session
metadata, and choose Overview, Resources or AI usage. Click a header to sort; unknown readings sort
last in either direction. Drag a separator or use its arrow keys to resize a column. Columns and
widths persist; search and status reset on entry. The harness name stays visible during horizontal
scrolling. Arrow keys select; Enter or double-click opens the inspector. It includes process IDs,
parent IDs and resource readings. Each row has a visible × close button that stays available during
horizontal scrolling. Saved sessions remain available in Open Harness (Cmd-P).

The × button reviews that harness before asking its owning daemon to stop the validated process
and close its panes. A confirmed close removes the row and updates the totals.
Conversation history, launch settings and files remain. The daemon checks conversation identity again
before stopping. Offline or disconnected sessions cannot be stopped. Freeze updates holds the displayed readings
without affecting work, and disables closing until live updates return.

## Metric definitions

| Metric | Meaning and availability |
| --- | --- |
| CPU % | Interval CPU across owned processes and children; 100% is one core, so totals can exceed 100%. macOS and Linux. The first sample is unknown. |
| RAM | Process-tree resident memory, in rounded MB/GB. Shared pages can overlap. Nested harness roots are excluded from their parent. Shared Codex servers appear separately and count once. |
| GPU % | GPU use of the harness process tree. macOS reads IOAccelerator clients owned by each PID: Apple Silicon AppUsage and Intel/AMD accumulatedGPUTime counters. GPU nanoseconds divided by the sample interval give percent. Linux reads NVIDIA process utilization. Summed use can exceed 100% across contexts/devices. Initial samples, context changes, resets and unavailable drivers show —. Cloud inference is not local GPU use. |
| GPU memory | NVIDIA compute allocations on supported Linux drivers. macOS and unsupported counters show —. |
| SSD | Allocated workspace disk space, including pre-existing files, from bounded du reads cached for one minute. Shared and nested canonical folders count once per machine in totals. Stopping does not release this space. SSD is a display label, not a hardware-media probe. |
| Disk read/s / write/s | Physical process-tree I/O deltas from Linux /proc/<pid>/io. Restricted counters, resets and macOS show —. |
| Transcript | Individual conversation-file size when reported. Shared databases show —. |
| Tokens | Conversation input plus output, with cached input counted once. Claude, Codex and OpenCode use the existing incremental daemon ledger. Other frameworks remain visible with unavailable token fields. |
| Input / output / cached input | Input includes cache reads/writes. Cached input is a subset, not an extra charge. Reasoning is included in output once. |
| Tokens/min | Recent change in conversation totals across distinct ledger updates, measured using local receipt time. Includes input/cache; not model generation speed. Session changes, counter resets or stale updates clear it. |
| Last active | Daemon conversation activity, not filesystem modification time. |

Model, framework, machine, project, branch, folder, process count, start time and identity columns
provide context. There is no invented dollar cost: subscription plans, caching and provider prices
cannot be inferred reliably from total tokens.

Totals describe the shown open harnesses and their shared servers. ≥ marks partial totals; — means
unavailable, never measured zero. Footer totals cover the open harnesses in its count across
connected owned machines. CPU/GPU use whole percentages; RAM/SSD use whole MB/GB (10.4 GB → 10 GB).
They do not include unrelated applications or whole-machine utilization.

The viewer polls local inventory every four seconds and linked machines every fifteen seconds while
visible. The foreground desktop footer samples every fifteen seconds; hidden apps clear readings and
stop polling. The daemon coalesces process reads, verifies PID birth identity, bounds macOS IORegistry/NVIDIA commands
and directory walks, and keeps telemetry off the terminal-input queue. No extra transcript scan is
started by the table or footer. Older daemons retain basic inventory but require updating for new
metrics. Identity and all stop actions remain machine-scoped through the paired bridge.

## Design references and checks

[Activity Monitor](https://support.apple.com/guide/activity-monitor/view-information-about-processes-actmntr1001/mac)
informs sortable columns, filtering, a focused inspector and an explicit stop review.
[btop](https://github.com/aristocratos/btop) informs process-tree accounting, resource sorting and
pausing display updates. This monitor adds conversation usage and machine identity to those patterns.
GPU and I/O definitions follow [NVIDIA's process telemetry](https://docs.nvidia.com/deploy/nvidia-smi/index.html)
and [Linux procfs](https://www.kernel.org/doc/html/latest/filesystems/proc.html).
The macOS investigation used [Stats' GPU reader](https://github.com/exelban/stats/blob/master/Modules/GPU/reader.swift)
to locate IOAccelerator data and [GPUI's process GPU probe](https://github.com/longbridge/gpui-kit/blob/main/crates/fps/src/gpu/macos.rs)
to verify the per-process counters. Stats' whole-device percentages are never included in harness totals.

`npm test` uses isolated policy/state fixtures. `node test/preview.mjs` serves synthetic sessions and
simulated stops, without a daemon bridge or model call. Daemon checks live in harnessResources,
harnessTelemetry, agentTokenUsage and backendSocket specs. Desktop tests cover footer scope,
rounding, hidden polling and tab reuse; `tool/check_swarm_titlebar.sh` checks native clicks/layout.
Real Linux NVIDIA counters still require hardware validation; parser fixtures do not establish
support for every driver.
On macOS, `cd cli && RUN_MACOS_GPU=1 npm test -- src/lib/macosProcessGpu.integration.spec.ts`
compiles a disposable Metal workload with the Command Line Tools and verifies that only its
harness gets nonzero GPU use while a separate idle harness stays at zero. It stops only its own
fixtures. Apple Silicon parsing is covered by fixtures; Intel/AMD has been checked on hardware.

The hps CLI offers explicit stop/open and reviewed cleanup commands; old pause/resume names remain compatibility aliases.
Rules/pins live in ~/.config/harness/policy.jsonc; receipts live under ~/.harness/monitor/.
Nothing automatically stops sessions. The assistant keeps its saved configuration, and its header offers the shared agent and model controls.

New OpenCode sessions use `opencode/muse-spark-1.3-contributor-free` with automatic approvals and xhigh effort. **Contributor permits Meta to train on prompts and responses.** The Assistant model disclosure keeps this visible. There is no automatic paid fallback, and existing sessions retain their saved agent/model settings.

## Credit and stewardship

Built by Autonomous for Harness, MIT. See [LICENSE](LICENSE). The Harness CLI owns process identity,
telemetry and lifecycle; this package owns the table and hps. Engine artwork is reused from the
desktop; attribution is included beside the copied icons.
