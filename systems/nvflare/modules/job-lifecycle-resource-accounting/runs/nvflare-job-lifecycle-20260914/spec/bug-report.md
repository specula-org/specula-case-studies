# Bug Report — nvflare-job-lifecycle

## Summary

- Source: NVIDIA/NVFlare `53ba7ee567468ea7971dad4faccef13c6cb35dc2`; source references below use original pinned lines, retained under `validation/source/`.
- Scenarios addressed: all 5 priority areas; all 8 original hunting configurations ran. Complete per-run evidence is in [run-coverage.json](output/run-coverage.json).
- Findings: **3 source-supported Case C model findings**. The violating interleavings were not reproduced end to end in the implementation during this validation phase. Passing controlled-fault harness scenarios are separate evidence.
- Trace conformance: **4/4 traces, 1,353 semantic events, 94/125 action types**; zero projection errors. See [replay receipts](output/traces-r5/summary.json) and [harness results](../harness/RESULTS.md).
- Standard convergence: one 30-minute `MC.cfg` BFS budget without invariant errors on the same model. Last report: depth 28, 85,219,049 generated, 16,008,119 distinct, 6,158,119 queued states. This was **bounded coverage, not exhaustive completion**. See [standard output](output/MC-r1.out).
- Selected production chain: DefaultJobScheduler, JobRunner, real Cell transport, ListResourceManager/ListResourceConsumer, and the default local process-launch path. Traces use one unit/site, max_jobs=2, required site-1, default non-strict startup and min_sites=1 (delayed-start: 2). Hunts also use two units, strict/min_sites=2, max_jobs=1 and a third optional site. Reservation TTL remains 30 real scan ticks; retry defaults remain 10 attempts and 10–600 seconds. The token universe is explicitly finite (11 attempts/job).

[PR #5191](https://github.com/NVIDIA/NVFlare/pull/5191) was refreshed on 2026-09-14: **open, unmerged**, head `27ecde2ab85b38734072b90128dc5dc2e8390882`; full discussion is saved in `validation/pr5191-*.json`. Its admission-exception bookkeeping/cancellation scope is known context, not a new finding here. The [expiry discussion](https://github.com/NVIDIA/NVFlare/pull/5191#issuecomment-5432240101) concerns reservations: missing cancellation acknowledgement alone does not establish a permanent leak, and expiry does not reclaim an allocation transferred to a job. Proposed PR changes were not applied to the pinned implementation.

## Bug 1: Startup rollback frees a resource while the spawned child is still live

- **ID / classification:** MC-2 / Case C, pinned-source supported
- **Scenario:** 2 - startup cleanup ownership
- **Severity:** Medium
- **Invariant violated:** `NoFreeWhileInUse`
- **Config:** `MC_hunt_s2_cleanup_handoff.cfg`
- **Counterexample:** 36 states; [MC_hunt_s2_cleanup_handoff-bfs.out](output/MC_hunt_s2_cleanup_handoff-bfs.out)

### Trace Summary

State 27 allocates unit 0 at required site s1; 32 spawns a live child; 33 attaches the handle; 34 returns from production AFTER_JOB_LAUNCH dispatch; 35 fails cleanup-waiter installation before any waiter executes; 36 rolls back, changing free=[1] to [0,1] while alive remains true, binding=[0], waiter=false.

### Root Cause

JobExecutor attaches a spawned process handle before creating and starting the sole child-exit waiter. A waiter-installation exception propagates to StartJobProcessor, whose catch frees the retained allocation without checking whether a child already owns it. The resource manager immediately returns the unit to its free deque. This exposes available capacity while the child may still use its launch binding, without an installed waiter owning normal cleanup.

### Affected Code

- `nvflare/private/fed/client/client_executor.py:299`
- `nvflare/private/fed/client/client_executor.py:318`
- `nvflare/private/fed/client/client_executor.py:330`
- `nvflare/private/fed/client/scheduler_cmds.py:129`
- `nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166`

### Evidence Boundary

Model counterexample and pinned-source control flow. The existing passing implementation traces do not inject cleanup-thread installation failure. No double-free or permanent process survival is claimed.

### Recommendation

Make post-spawn cleanup ownership explicit. On waiter-install failure retain ownership or terminate and observe exit before returning the resource; ensure a single effective cleanup owner.

---

## Bug 2: A stale deployment write can undo an acknowledged pre-run abort

- **ID / classification:** MC-3 / Case C, pinned-source supported
- **Scenario:** 3 - pre-run abort status
- **Severity:** Medium
- **Invariant violated:** `AcceptedPreRunAbortPersists`
- **Config:** `MC_hunt_s3_abort_status.cfg`
- **Counterexample:** 22 states; [MC_hunt_s3_abort_status-bfs.out](output/MC_hunt_s3_abort_status-bfs.out)

### Trace Summary

State 12 saves a successful SUBMITTED status check; 13 admin reads SUBMITTED; deployment proceeds; 18 admin stores ABORTED; 21 runner unconditionally stores DISPATCHED; 22 admin constructs a success response from its saved pre-run branch while current status is DISPATCHED.

### Root Cause

JobRunner checks SUBMITTED before deployment, then writes DISPATCHED unconditionally. The concurrent pre-run abort handler reads status once, stores ABORTED, and constructs a success response from its saved branch. Deployment can overwrite that terminal value before the response is constructed. The built-in job manager performs a plain metadata update without an expected-state condition.

### Affected Code

- `nvflare/private/fed/server/job_runner.py:661`
- `nvflare/private/fed/server/job_runner.py:669`
- `nvflare/private/fed/server/job_cmds.py:1059`
- `nvflare/private/fed/server/job_cmds.py:1062`
- `nvflare/apis/impl/job_def_manager.py:459`

### Evidence Boundary

Model counterexample and pinned-source control flow. The 22-state trace ends before any child spawn. Subsequent startup is a source-permitted continuation, not an executed public-API reproduction in this phase. The modeled acknowledgment is server-side CLI success-response construction; reply transport is outside this trace projection. Client-visible success assumes ordinary delivery.

### Recommendation

Serialize abort with status transitions or use expected-state updates so stale deployment/start writes cannot overwrite a terminal abort.

---

## Bug 3: A delayed startup write can restore RUNNING after terminal publication

- **ID / classification:** MC-4 / Case C, pinned-source supported
- **Scenario:** 3 - terminal status publication
- **Severity:** Medium
- **Invariant violated:** `NoTerminalResurrection`
- **Config:** `MC_hunt_s3_terminal_status.cfg`
- **Counterexample:** 61 states; [MC_hunt_s3_terminal_status-bfs.out](output/MC_hunt_s3_terminal_status-bfs.out)

### Trace Summary

The server exits and is removed; heartbeat recovery resolves pending outcomes before runner registration. Both starts return and the runner publishes its running-map entry at state 56, then pauses before the RUNNING store. Completion selects/classifies/archives the job and stores COMPLETED at state 60. The startup thread stores RUNNING at 61, after terminal publication.

### Root Cause

JobRunner publishes running_jobs membership under its lock, then stores RUNNING after releasing that lock. The completion thread can observe the entry after server exit and outcome resolution and publish a terminal status first. The delayed startup write then restores RUNNING. Completion can subsequently delete its bookkeeping without another status publication.

### Affected Code

- `nvflare/private/fed/server/job_runner.py:709`
- `nvflare/private/fed/server/job_runner.py:711`
- `nvflare/private/fed/server/job_runner.py:524`
- `nvflare/private/fed/server/job_runner.py:531`
- `nvflare/apis/impl/job_def_manager.py:459`

### Evidence Boundary

Pinned-source locking/store order supports Case C. The saved 61-state trace has completion=remove and running=true: final map deletion has not yet occurred. Source lines 531-538 can subsequently remove bookkeeping without republishing status; a permanently stale RUNNING record is a continuation consequence, not an executed production result. The early-exit/heartbeat setup is within the model child-exit abstraction; no end-to-end reproduction of this interleaving was run.

### Recommendation

Coordinate running-map publication, RUNNING persistence and terminal publication using a shared lifecycle synchronization boundary or expected-state store updates.

---

## Search Coverage

Every successful budget run used 30 minutes. Simulation used a depth limit of 100 and a requested trace count of 999999999, allowing the timer to terminate exploration. No configuration bound was shrunk. BFS depths are achieved search depths; simulation 100 is a configured limit, not an exhaustive diameter. Counts below are the final available TLC statistics, so budgeted counts can precede termination by a progress interval.

| Config | Mode | BFS depth / simulation limit | State coverage | Result | Output |
|---|---|---:|---|---|---|
| `MC_hunt_s1_environment.cfg` | BFS | 57 | 4,393,726 distinct / 24,825,813 generated | Budget ended; no violation reported | [MC_hunt_s1_environment-bfs](output/MC_hunt_s1_environment-bfs.out) |
| `MC_hunt_s1_environment.cfg` | simulation | 100 (limit) | 7,608,509 checked / 20,376 traces generated | Budget ended; no violation reported | [MC_hunt_s1_environment-sim](output/MC_hunt_s1_environment-sim.out) |
| `MC_hunt_s1_optional_symmetry.cfg` | BFS | 53 | 2,961,605 distinct / 18,138,177 generated | Budget ended; no violation reported | [MC_hunt_s1_optional_symmetry-bfs](output/MC_hunt_s1_optional_symmetry-bfs.out) |
| `MC_hunt_s1_optional_symmetry.cfg` | simulation | 100 (limit) | 5,594,280 checked / 12,508 traces generated | Budget ended; no violation reported | [MC_hunt_s1_optional_symmetry-sim](output/MC_hunt_s1_optional_symmetry-sim.out) |
| `MC_hunt_s2_cleanup_handoff.cfg` | BFS | 37 | 14,769 distinct / 50,412 generated | Violation: NoFreeWhileInUse | [MC_hunt_s2_cleanup_handoff-bfs](output/MC_hunt_s2_cleanup_handoff-bfs.out) |
| `MC_hunt_s2_partial_start_strict.cfg` | BFS | 47 | 4,086,785 distinct / 22,842,918 generated | Budget ended; no violation reported | [MC_hunt_s2_partial_start_strict-bfs](output/MC_hunt_s2_partial_start_strict-bfs.out) |
| `MC_hunt_s2_partial_start_strict.cfg` | simulation | 100 (limit) | 8,224,287 checked / 21,107 traces generated | Budget ended; no violation reported | [MC_hunt_s2_partial_start_strict-sim](output/MC_hunt_s2_partial_start_strict-sim.out) |
| `MC_hunt_s3_abort_status.cfg` | BFS | 23 | 6,230 distinct / 21,543 generated | Violation: AcceptedPreRunAbortPersists | [MC_hunt_s3_abort_status-bfs](output/MC_hunt_s3_abort_status-bfs.out) |
| `MC_hunt_s3_terminal_status.cfg` | BFS | 62 | 207,875 distinct / 872,880 generated | Violation: NoTerminalResurrection | [MC_hunt_s3_terminal_status-bfs](output/MC_hunt_s3_terminal_status-bfs.out) |
| `MC_hunt_s4_exit_cleanup.cfg` | BFS | 28 | 4,428,812 distinct / 24,252,184 generated | Budget ended; no violation reported | [MC_hunt_s4_exit_cleanup-bfs](output/MC_hunt_s4_exit_cleanup-bfs.out) |
| `MC_hunt_s4_exit_cleanup.cfg` | simulation | 100 (limit) | 9,972,239 checked / 35,340 traces generated | Budget ended; no violation reported | [MC_hunt_s4_exit_cleanup-sim-eager](output/MC_hunt_s4_exit_cleanup-sim-eager.out) |
| `MC_hunt_s5_scheduling_progress.cfg` | BFS | 20 | 10,193 distinct / 33,680 generated | Budget ended; no violation reported | [MC_hunt_s5_scheduling_progress-bfs](output/MC_hunt_s5_scheduling_progress-bfs.out) |
| `MC_hunt_s5_scheduling_progress.cfg` | simulation | 100 (limit) | 6,989 checked / 16 traces generated | TLC worker crash; excluded from successful coverage | [MC_hunt_s5_scheduling_progress-sim](output/MC_hunt_s5_scheduling_progress-sim.out) |
| `MC_hunt_s5_scheduling_progress.cfg` | simulation | 100 (limit) | 106,341 checked / 238 traces generated | Budget ended; no violation reported | [MC_hunt_s5_scheduling_progress-sim-eager](output/MC_hunt_s5_scheduling_progress-sim-eager.out) |

The first progress simulation crashed in TLC's lazy-function equality while constructing liveness traces. It was stopped, retained as failed execution, and retried with `TLCEval` around explicit function constructors in isolated execution copies. `TLCEval(v)==v`; all guards, properties, fairness and bounds retain identical mathematical meaning. Four real traces also pass on that eager copy. The canonical model is unchanged. See [execution workaround](validation/eager-execution.md), [control replay](output/traces-eager-control/summary.json), and the retry's input/hash receipt. The exit-cleanup simulation uses the same workaround. Generated-trace counts do not imply exhaustive liveness verification.

## Not Reproduced

| Scenario / boundary | Result |
|---|---|
| `MC_hunt_s1_environment.cfg` | No violation in the recorded bounded BFS/simulation coverage; this does not establish implementation correctness. |
| `MC_hunt_s1_optional_symmetry.cfg` | No violation in the recorded bounded BFS/simulation coverage; this does not establish implementation correctness. |
| `MC_hunt_s2_partial_start_strict.cfg` | No violation in the recorded bounded BFS/simulation coverage; this does not establish implementation correctness. |
| `MC_hunt_s4_exit_cleanup.cfg` | No violation in the recorded bounded BFS/simulation coverage; this does not establish implementation correctness. |
| `MC_hunt_s5_scheduling_progress.cfg` | No violation in the recorded bounded BFS/simulation coverage; this does not establish implementation correctness. |
| Two-unit process-binding implementation trace | Not executed; the four passing traces use one unit/site. Any shared-environment source hypothesis not backed by a model counterexample remains outside findings.json. |
| Post-spawn waiter-install failure in real NVFlare | Not injected in the passing implementation traces; MC-2 remains source-supported model evidence pending local functional confirmation. |
| TV-2 / TV-3 service-death paths | Not modeled/tested here; progress assumes live scheduling/completion services. |
| CR-2 surviving server process after termination request | No permanent surviving-process consequence was established; no ineffective-SIGKILL fault was invented. |
| CR-1 returned startup error, CR-3 invalid custom resource counts, CR-4 full notification retry loop, CR-5 header-only error producer, CR-6 disconnected fallback | Retained as brief/code-review boundaries, not promoted into model-checking findings. |
| Zero-grace server command exception and accepted ABORTED outcome receiver path | Source-modeled but lack dedicated passing implementation traces. |
| Delayed heartbeat snapshots | Current trace projection covers the observed missing-outcome branch; delayed snapshot interleavings remain outside that projection. |

All five priority questions, including physical ownership versus logical stop, exact reply/job identity, participant policy and conditional progress, are mapped in [priority-coverage.md](validation/priority-coverage.md). No progress guarantee is claimed under permanent site/resource/store failure. No GPU computation, HA recovery, external trainer, alternative launcher or workspace-content correctness was tested.

## Specification and Capture Repairs

The initial replay mismatches were model/capture issues: stop-send versus blocking return, pre-wait abort ownership capture, exceptional participant-list preservation, heartbeat-origin outcome resolution, ignored late reports, server cleanup grace branches, and repeated termination/pop. The pending-client acceptance guard, ABORTED classification and unbounded normal heartbeat behavior were preserved/refined from source. Every hunt now checks MCTypeOK. No safety predicate was weakened to suppress a counterexample. See [changelog.md](changelog.md) and [source-fidelity notes](validation/review-resolution.md).
