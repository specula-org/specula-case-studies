# Modeling Brief: NVFlare job lifecycle and resource accounting (local-process launch path)

Pinned `53ba7ee5` (2026-09-11). Evidence and commands: `analysis-report.md`, `evidence/`. Finding IDs (F*) match the report.

## 1. System Overview

- **System**: NVIDIA FLARE (Python). In-scope lifecycle/resource logic is about 11 kLOC. Main files: `job_runner.py`,
  `job_scheduler.py`, `server_engine.py`, `fed_server.py`, the `job_cmds.py` lifecycle handlers, `job_def_manager.py`
  with `filesystem_storage.py`, the client `scheduler_cmds.py`, `client_engine.py`, `client_executor.py`, the resource
  managers, and the process launcher.
- **Category A (Distributed / Message-Passing)**: a server parent (SP), N client parents (CP) and per-job processes
  (SJ, CJ) talk through CellNet request/reply RPCs with timeouts. No reply means timeout, and a late reply is still
  processed. The relevant faults are message loss or lateness, process exit or crash, and client disconnect. Inside SP
  and CP, several threads also write shared dicts and a file-backed job store without a common lock, so handlers must be
  **split at their check-then-act boundaries** (concurrent-style action granularity inside a distributed model).
- **Reference protocol** (docs `job.rst:263-345`, contracts in `evidence/contracts.md`):
  1. SUBMITTED.
  2. Schedule: CHECK_RESOURCE reserves a token per client. Requires `min_sites` / required sites. `max_jobs` is
     enforced by `scheduled_jobs`, which JOB_STARTED increments and JOB_COMPLETED|ABORTED decrements.
  3. DEPLOY, then DISPATCHED.
  4. SJ launch, then START_JOB: the client allocates the token, consumes it and launches the CJ. Then RUNNING.
  5. SJ exit plus client terminal outcomes (barrier of at most 900 s), then FINISHED:*.
  6. The client frees resources at CJ exit. Reservations expire after 300 ticks of 1 s (provisioned config).
- **Architectural choices that deviate from a clean state machine**:
  - (i) Job status is a **blind-write** field (`set_status`, `job_def_manager.py:459-481`). Its store is an unlocked
    read-modify-write (`filesystem_storage.py:251-275`). At least 5 SP threads write it.
  - (ii) Admin abort of a not-yet-running job is **only a store write** (`job_cmds.py:1061-1066`).
  - (iii) A single unsupervised runner thread (`server_deployer.py:144-145`) executes schedule, deploy and start
    sequentially.
  - (iv) Reservations on runner skip/failure paths are reclaimed **only by expiry**.
  - (v) The client frees resources on **leader-process exit** (`client_executor.py:626-679`).
  - (vi) Terminal-outcome signals travel on separate best-effort channels: SJ exit code, UPDATE_RUN_STATUS,
    REPORT_JOB_FAILURE, heartbeat job lists.
- **Concurrency**: SP runs the runner, completion thread, admin handlers, cell handlers, per-SJ waiters, abort-cleanup
  threads and the dead-client sweeper. CP runs admin handlers on a worker pool, a heartbeat thread, per-CJ waiters and
  the reservation-expiry thread.
- **Defaults**: client `GPUResourceManager(num_of_gpus=0, mem=0, expiration_period=300)` with `GPUResourceConsumer`.
  Server `DefaultJobScheduler(max_jobs=4)` (class default 1). `strict_start_job_reply_check=False`.

## 2. Scenarios

### Scenario 1: Unguarded job-status writes and check-then-act (HIGH)
**Mechanism**: status transitions are blind writes from threads that decided on stale reads. There is no
compare-and-set, no terminal latch, and the store merge is non-atomic.
**Evidence**:
- Historical (H1): a6dcce63, def5c04c, bb840df0, 9e1881da, 8bb1b84c, e3568925, 6d193a24, 1b009bdc, e1206061. These
  fixes moved or ordered writers, but none added a transition guard.
- Code/verified:
  - **F1**: an acknowledged abort is lost during deploy/start. It is overwritten by DISPATCHED (`job_runner.py:670`)
    and RUNNING (`:711`). Harness A1/A2.
  - **F3**: RUNNING (`:711`) is written after completion has published a terminal status. Harness B, delay control.
  - **F16**: the scheduler's `refresh_meta` RMW rewrites SUBMITTED over an abort of a queued job. `rmw_probe`.
  - **F5**: `fail_run` during `_start_run` causes a KeyError (`:359-360`) and the job ends FAILED_TO_RUN.
**Affected paths**: `JobRunner.run` (`:655-731`), `_start_run` (`:287-364`), `_job_complete_process` (`:441-541`),
`fail_run`/`stop_run`/`mark_run_aborted` (`:798-852`), `abort_job`/`delete_job` (`job_cmds.py:507-548, 1051-1084`),
`schedule_job` (`job_scheduler.py:287-311`), `set_status`/`update_meta` (`job_def_manager.py:459-505`).
**Modeling**:
- Variable `status[j]`, including `Deleted`, written by every actor. Model the store merge as two steps (read
  snapshot, then write snapshot plus delta).
- Runner PC: `Sched → ChkSubmitted → Deploy → SetDispatched → ChkDispatched → StartSJ → StartClients → FireStarted →
  Register → SetRunning`.
- Admin `Abort(j)` (status-branching) and `Delete(j)`. Completion `Finalize(j)`. `FailRun(j)` from client reports.
**Priority**: High. Five verified instances; the mechanism is systemic and ideal for interleaving search.

### Scenario 2: Admission-loop robustness — one failure stalls every later job (HIGH)
**Mechanism**: an exception or indefinite wait in the single scheduling/finalization path, or a candidate that is
never classified, blocks admission of all later eligible jobs.
**Evidence**:
- Historical (H5): 5535bdb7, 3225529d, 38fa2c75, 47684966 (an incomplete fix), 6608949c, 71fbcaae.
- Code/verified:
  - **F2**: deleting a SUBMITTED job while it is held kills `JobRunner.run`. `:661` is outside the `try`, and the
    handler at `:720` is unprotected. G1/G2.
  - **F4**: a validator-accepted `min_clients` of `"2"` or `null` (and a `resource_spec` process string) raises inside
    `_try_job`. The exception is swallowed before its count updates, so it causes head-of-line starvation.
  - **F12** (server agent): `disable_clients`/`remove_clients` skip `notify_dead_client`, so a finished job holds its
    slot for 900 s.
  - **F7**: the dead-client sweeper iterates a live dict in a thread with no exception handler
    (`fed_server.py:290-304,1109`).
**Affected paths**: `JobRunner.run`, `DefaultJobScheduler._do_schedule_job`/`_try_job`,
`server_deployer._start_job_runner`, `ServerEngine.disable_clients`, `FederatedServer.client_cleanup`.
**Modeling**:
- A `runner` actor that becomes `Dead` when it reads a deleted job or its handler write fails.
- A constant set `Poisoned ⊆ Jobs` of candidates whose evaluation raises.
- `slots ⊆ Jobs`, balanced by started/ended events.
- `AdminDisable(c)`, which removes a session without resolving outcomes.
**Priority**: High. Blast radius is every later job (liveness).

### Scenario 3: Reservation/allocation lifetime across partial failures (MEDIUM-HIGH)
**Mechanism**: ownership moves from reserved (token with a TTL) to allocated (token popped) to freed at leader exit.
Several branches skip a step or free by value with no ownership check.
**Evidence**:
- Historical (H4): 1058e40c (introduced expiry), 975dc146, 327be8ff, 15bebb31, 4327d7c3 (lost free leading to
  permanent capacity loss), a6616c8a, 82fec3f7, 03b56e8b.
- Code/verified:
  - **F6**: runner skip/failure paths never cancel; only expiry reclaims (300 s).
  - **F9**: string-return start failures leak the allocation permanently (`client_engine.py:357-367`); the trigger is
    outside the supported envelope.
  - **F19**: `free_resources` has no ownership check, so a double free duplicates units (defensive).
  - **F10**: resources are freed at leader exit while same-group descendants may live, and `terminate()` becomes a
    no-op.
  - The expiry-vs-slow-deploy race is **safe**: `allocate` raises (client harness C3).
**Affected paths**: `CheckResourceProcessor`, `StartJobProcessor`, `CancelResourceProcessor` (`scheduler_cmds.py`),
`AutoCleanResourceManager` (`:102-172`), `JobExecutor.start_app`/`abort_app`/`_wait_child_process_finish`,
`ServerEngine.check/cancel_client_resources`.
**Modeling**:
- Per client: a bag `free[c]`, `resv[c]` (token ↦ ⟨units, ttl, job⟩), `alloc[c][j]`, `cj[c][j]`, `grp[c][j]`
  (descendants alive).
- Actions: Check (reserve), Tick/Expire, Cancel, Allocate, StartReturnsError, Launch, LeaderExit, GroupExit, Free.
- Late CHECK replies. Heartbeat cleanup abort.
**Priority**: Medium-High. Conservation is a clean invariant, and the historical bug density is high.

### Scenario 4: Terminal-status composition from racing outcome signals (MEDIUM)
**Mechanism**: the final status is computed from whichever of several asynchronous signals has arrived. The signals are
the SJ exit code (`wait_for_complete`), UPDATE_RUN_STATUS (fire-and-forget with a 2 s grace), client REPORT_JOB_FAILURE,
admin `run_aborted`, and outcome-barrier timeouts. Cleanup threads can remove bookkeeping before a signal is recorded.
**Evidence**:
- Historical (H2): 2c89c887, 508c7d23, 8a3e3cb0, b25e6bd3, 6bc40bb5, a060c60f, 1f39ccf8, 924998da, 46cfc517,
  535373a0, 52c966d1.
- Code:
  - **F5**.
  - **F17**: an execution error is carried only by a best-effort UPDATE_RUN_STATUS (`server_engine.py:873-884,
    207-233`).
  - **F20**: `_remove_run_processes` pops `run_processes` before `wait_for_complete` reads it, and calls `killpg`
    unconditionally after a reap (`server_engine.py:385-409`).
  - The `-9 → FINISHED_ABNORMAL` branch is unreachable for process SJs (`job_runner.py:569-571`).
**Modeling**: `sj[j] ∈ {None, Running, Exited}`, `excRC[j]`, `finRpt[j]`, `pending[j]`, `runAborted[j]`. Model the
classification function exactly as `_classify_finished_job_status` (`:543-572`). Lossy UPDATE_RUN_STATUS.
**Priority**: Medium. Signal-precedence bugs dominate history, and the fixes are recent.

### Scenario 5: Partial deploy/start outcome vs site policy (LOW-MEDIUM)
**Mechanism**: `min_sites`/required-site tolerance is applied inconsistently across failure kinds:
- deploy timeouts and failures are tolerated;
- a client that disconnected after scheduling raises "unknown clients" or "not enough replies" and fails the whole job
  (`job_runner.py:222-226`, `admin.py:104-105`);
- any explicit client START error fails the whole job (`admin.py:131-140`);
- non-strict start timeouts are ignored (documented).
Clients that timed out may still start later, and heartbeat sync compensates.
**Evidence**:
- Historical (H7): df539aab, 365da018, a8ee3c2b, eaf1b5ba, 39c247d3, f8efaeb7.
- Code: **F15**, and **F11** (a CJ never starts its job if STARTED cannot be acknowledged).
**Modeling**: the per-client deploy/start outcome ∈ {ok, fail, timeout, disconnected}, reusing Scenarios 1 and 3.
**Priority**: Low-Medium. Mostly policy questions.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| Runner PC with split check/act steps | S1, S2 (F1, F2, F3, F5) | One action per step. The `Dead` state is reached from ChkSubmitted/SetDispatched/handler when the job is `Deleted`. |
| Blind store writes plus RMW split | S1 (F1, F16) | `status[j]`, plus a per-writer `snap` for update_meta. |
| Admin Abort/Delete/Disable as environment actions | S1, S2 | Interleave freely; `ackAbort[j]` history variable. |
| Completion thread and outcome barrier | S1, S4 | Finalize guarded as in `:444-476`; publishes, then removes from running, then fires events. |
| Scheduler slots and events | S2 | `slots`; JOB_STARTED at `_start_run` end; JOB_ABORTED on the exception path; JOB_COMPLETED at finalize. |
| Client resource pool as bags plus TTL expiry | S3 | Bag equality detects duplication and loss. Expiry is a nondeterministic `Tick`. |
| CJ lifecycle with a pending handle and process group | S3, S4 | Registered → Starting → Started → Stopped → LeaderExit → GroupExit. Abort acts per state (`client_executor.py:486-547`). |
| Lossy RPC with late processing | S3, S4, S5 | A CHECK/START/ABORT/REPORT may time out at the sender yet still be processed. Heartbeat reconciliation runs as an action. |

### 3.2 Do Not Model

| What | Why |
|---|---|
| Float GPU-memory drift (F8) | Numeric rounding; test-verified. |
| `CUDA_VISIBLE_DEVICES` env (F13) and portable-GPU 0-memory sharing (F14) | Environment and semantic questions; code review. |
| PID reuse / `killpg` mechanics (F10, F20 part) | OS-level; probes and tests. |
| Validator type coercion (F4 specifics) | Model generically as `Poisoned`; the concrete shapes are test cases. |
| Workspace archival/zip I/O, log streaming, auth/signing, study registry | No bearing on ownership or status beyond "may fail" (already bounded by 6608949c). |
| Docker/K8s/Slurm launchers, HA, restart reconciliation (F18) | Out of scope. F18 is recorded as code review. |
| `notify_job_status` retry (F11) | Local loop bug; test-verified. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Blind status store | `status[j]`, `snap[w][j]` | unguarded writes, RMW lost update | S1 |
| Runner thread | `rpc ∈ Steps × Jobs ∪ {Idle, Dead}`, `tok[j]` | check-then-act windows, thread death | S1, S2 |
| Admin history | `ackAbort[j]`, `deleted[j]` | abort/delete contracts | S1, S2 |
| Admission | `slots`, `startedEv[j]`, `endedEv[j]`, `Poisoned` | slot balance, starvation | S2 |
| Server job bookkeeping | `sj[j]`, `excRC[j]`, `finRpt[j]`, `pending[j]`, `running`, `runAborted[j]` | completion classification, outcome barrier | S1, S4 |
| Client pool | `free[c]` (bag), `resv[c]`, `alloc[c][j]` | conservation, exclusivity, leaks | S3 |
| Client jobs | `cj[c][j]`, `grp[c][j]`, `abortReq[c][j]` | abort windows, free-at-leader-exit | S3, S4 |
| Network | `msgs` (bag), `sessions[c]` | loss, lateness, disconnect/disable | S3–S5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| TerminalStable | Safety (action) | Once `status[j] ∈ FINISHED:*`, it never changes (deletion excepted) | S1: F1, F3, F16 |
| AbortHonored | Safety | `ackAbort[j]` ⇒ no SJ/CJ of j is launched after the ack, and the final status is FINISHED:ABORTED | S1: F1, F16 |
| OneShot | Safety | Each job's SJ is launched at most once (`job.rst:342-345`) | S1 |
| RunningIsTracked | Safety | `status[j]=RUNNING` ⇒ `j ∈ running ∪ {runner's current job}` | S1: F3 |
| SlotBalance | Safety | `slots = {j : startedEv[j] ∧ ¬endedEv[j]}` and `|slots| ≤ MaxJobs` | S2 |
| RunnerAlive | Safety | `rpc ≠ Dead` | S2: F2 |
| AdmissionProgress | Liveness | A SUBMITTED, non-poisoned, resource-feasible job eventually leaves SUBMITTED (WF on runner/completion) | S2: F2, F4, F12 |
| ResourceConservation | Safety | Per client, `free ⊎ reservedUnits ⊎ allocatedUnits = Capacity` (bag equality) | S3: F9, F19 |
| ExclusiveOwnership | Safety | No unit is held by two live reservations or allocations | S3 |
| NoFreeWhileGroupAlive | Safety | A unit re-enters `free` only when its job's process group is gone | S3: F10 |
| ReservationBounded | Safety (clocked) | Every reservation is consumed, cancelled or expired within `Expiry` ticks. Informational variant `PromptCancel` (tokens of undispatched sites cancelled within one runner step) is expected to fail by design (F6). | S3 |
| FinalMatchesOutcome | Safety | Final COMPLETED ⇒ no recorded SJ execution error and no accepted client failure. An admin abort of a running job ⇒ ABORTED. | S4: F5, F17 |
| BoundedFinalization | Liveness | SJ exited ∧ no participant can report ⇒ ◇ terminal (within the barrier timeout) | S4: F12 |
| EventualCleanup | Liveness | Terminal status ⇒ ◇ (no CJ alive ∧ all its units free) | S3–S5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable
Seed counterexamples F1, F2, F3, F5 and F16 are already confirmed in code. The spec must reproduce them as a fidelity
check before hunting; they are **not** the targets. The targets are open questions:

| ID | Open question | Expected violation | Scenario |
|---|---|---|---|
| MC-1 | Which *other* interleavings of runner steps, completion finalize, admin abort/delete, `fail_run`/`stop_run`, scheduler give-up (CANT_SCHEDULE) and RMW writes overwrite a terminal status with a different outcome (e.g. ABORTED→FAILED_TO_RUN/CANT_SCHEDULE/COMPLETED), or launch a job twice? | TerminalStable, OneShot, AbortHonored | S1 |
| MC-2 | Is every JOB_STARTED balanced by exactly one end event on all exit paths, including start exceptions, the KeyError path, `fail_run` after SJ exit, `stop_run` of an already-exited SJ, and publication retries? Can a slot leak or be double-released? | SlotBalance, AdmissionProgress | S2 |
| MC-3 | Through any *supported* path, with late CHECK replies, dropped cancels, abort in each CJ state, heartbeat cleanup and leader/group exit, can a unit be owned by two live jobs or lost beyond expiry? | ResourceConservation, ExclusiveOwnership, NoFreeWhileGroupAlive | S3 |
| MC-4 | With a lossy UPDATE_RUN_STATUS, client failure reports, `_remove_run_processes` popping before rc capture, and admin abort racing, can a failed job publish COMPLETED, or an admin-aborted running job publish non-ABORTED? | FinalMatchesOutcome | S4 |
| MC-5 | Under fairness, with disable/remove/dead clients, does every finished job reach a terminal status within the barrier, and does every CJ of a terminal job eventually exit and free its units? | BoundedFinalization, EventualCleanup | S2, S4 |

### 6.2 Test-Verifiable (confirmed by harness unless noted)

| ID | Description | Test approach |
|---|---|---|
| F1 | Abort during deploy/start lost; the job runs | `lifecycle_harness.py A1/A2` |
| F2 | Delete of a held SUBMITTED job kills `JobRunner.run` | `G1/G2`; also the scan race at `:650` |
| F3 | RUNNING after terminal (needs descheduling) | `B_running_overwrite` (delay control) |
| F4 | Validator-accepted `min_clients` `"2"`/`null` (and `resource_spec` process string) starves later jobs | `l9_l1_probe.py`; add a scheduler unit test per shape |
| F5 | `fail_run` during `_start_run` → KeyError → FAILED_TO_RUN, stale `exception_run_processes` | `K_failrun_during_start` |
| F7 | `stop_all_runs` live-dict iteration at shutdown | `H_stop_all_runs`; same pattern at `fed_server.py:1109` |
| F8 | GPU float-memory drift, permanent capacity loss | `l9_l1_probe.py` (0.1+0.2 GiB) |
| F9 | Start string-return leaks allocation | `client_harness.py` c1 (unsupported trigger) |
| F10 | `terminate()` no-op after leader reaped | `pgroup_probe.py` |
| F11 | `notify_job_status` ignores `retry_timeout` | `client_harness.py` c2 |
| F12 | disable/remove client → finished job holds slot until outcome timeout | `evidence/deep/server_engine/repro_disable_client_outcome_wait.py` |
| F16 | RMW lost update: queued-job abort reverted to SUBMITTED | `rmw_probe.py` (timing control) |
| F19 | `free_resources` double free duplicates units (defensive) | `client_harness.py` c4 |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| F6 | Runner skip/failure paths never cancel dispatched reservations; expiry-only (300 s) | Decide whether contract 9 ("consumed or cancelled") should extend to the runner |
| F13 | `CUDA_VISIBLE_DEVICES` set process-wide in CP; inherited by later GPU-less jobs; races concurrent starts | Review consumer contract (GPU-adjacent) |
| F14 | Portable `num_of_gpus` carries no memory → `GPUResourceManager` gives no exclusivity (vs `job.rst:313-316`) | Clarify the intended semantics |
| F15 | Disconnect after scheduling, or an explicit error from any client, fails the whole job despite `min_sites` | Policy decision; document |
| F17 | Exec-error status only via fire-and-forget UPDATE_RUN_STATUS with a 2 s grace | Verify the exit-code path |
| F18 | Restart reconciliation (`update_unfinished_jobs` etc.) has no callers; jobs stay RUNNING after a restart | Out-of-scope recovery; note |
| F20 | `_remove_run_processes` pops before rc capture; unconditional `killpg` after reap (PID reuse) | Review |
| R1 | Terminal publication retried unbounded while holding the slot (`job_runner.py:523-530`) | Review with 6608949c |

## 7. Reference Pointers

- **Full report**: `analysis-report.md`.
  - §0: environment limits. Historical diffs are unavailable (blob-less clone), so archaeology rests on commit bodies,
    file lists and HEAD code.
  - §2: archaeology. 405 commits, 78 in-scope fixes.
  - §3: findings with commands.
- **Contracts**: `evidence/contracts.md`. Recent-fix contracts: report §2.3.
- **Harnesses and logs**: `evidence/harness/`. Deep-analysis notes: `evidence/deep/*.md`.
- **Key source**:
  - `nvflare/private/fed/server/job_runner.py:287-364,441-541,633-735,798-869`
  - `app_common/job_schedulers/job_scheduler.py:104-311`
  - `private/fed/server/server_engine.py:179-409,1010-1083`
  - `private/fed/server/fed_server.py:290-330,579-624,906-1113`
  - `private/fed/server/job_cmds.py:507-548,1051-1084`
  - `apis/impl/job_def_manager.py:459-531`
  - `app_common/storages/filesystem_storage.py:251-329`
  - `private/fed/client/scheduler_cmds.py:57-157`
  - `client_engine.py:349-404`
  - `client_executor.py:198-334,486-688`
  - `app_common/resource_managers/auto_clean_resource_manager.py:93-176`
  - `utils/process_utils.py:210-352`
- **Historical fixes** (reference only; commit subjects in `evidence/archaeology/core-commits.txt`): H1–H7 in report
  §2.2. GitHub issues were not consulted, because they are not a permitted source.
