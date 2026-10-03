# Bug Report — nvflare-job

## Summary

- Scenario families tested: 5 (S1–S5).
- Source-classified model candidates: 13 distinct report entries.
- Hunting configurations: 25; seed configurations: 8.
- All entries await the configured separate confirmation/reproduction phase. Severity is provisional.

Source pin: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. The original Claude run was interrupted during hunting by credit exhaustion, before independent confirmation. This is an authorized mixed-model continuation: GPT-6 Astra/max verification and repair, with GPT-5.5/xhigh confirmation owned by the launcher. Historical/source-derived seeds and variants are identified below; they are not presented as new independent discoveries.

The continuation independently audited the supplied conversations and pinned source, repaired model atomicity/prerequisites, adapted and reran the harness, replayed all 32 fresh traces, and checked the final model/configuration matrix below. Replay establishes compatibility of the observed projection; bounded TLC success is not unbounded correctness. Known failing contracts remain in strict probes while explicitly documented residuals allow other searches to continue. See [brief-coverage.md](brief-coverage.md), [continuation-audit.md](continuation-audit.md), and [changelog.md](changelog.md).

Phase 4 must consolidate these MC findings with all source-review Scenarios in `../modeling-brief.md` and the mandatory [findings reconciliation](../adoption/findings-reconciliation.md). Source-only, policy, unsupported and environment-limited leads must retain distinct dispositions. No product logic has been fixed.

## Bug 1: Queued cancellation can be overwritten by concurrent lifecycle writes

- **Scenario / provenance**: S1 / F1 and strict status-writer variants
- **Severity (provisional)**: High
- **Invariant violated**: AbortHonored
- **Config**: `MC_seed_F1.cfg`
- **Counterexample**: 12 states; [tlc.out](output/continuation-S3-F1/tlc.out)

### Trace Summary

1. The runner accepts a submitted job and completes deployment.
2. The administrator receives a successful queued-abort acknowledgment.
3. The runner unconditionally writes DISPATCHED, losing the terminal status; the implementation trace additionally observes a later launch.

### Root Cause

The queued-abort handler reads a submitted/dispatched status and acknowledges FINISHED:ABORTED without synchronizing with the runner's earlier status check and subsequent writes. A deployment already past its check can write DISPATCHED over that acknowledgment and later launch the job. The fresh model and controlled implementation trace independently exercise this source-derived F1 mechanism; full local-deployment confirmation remains separate.

### Affected Code

- `nvflare/private/fed/server/job_cmds.py:1058`
- `nvflare/private/fed/server/job_cmds.py:1063`
- `nvflare/private/fed/server/job_runner.py:661`
- `nvflare/private/fed/server/job_runner.py:670`
- `nvflare/private/fed/server/job_runner.py:697`
- `nvflare/private/fed/server/job_runner.py:711`
- `nvflare/fuel/flare_api/flare_api.py:569`

### Related evidence and limits

- [continuation-H4-probe_admin_abort](output/continuation-H4-probe_admin_abort/tlc.out): Historical MC-A: the stale queued-abort writer replaces FAILED_TO_RUN with ABORTED. The public API documents no effect for an already-done job; exact precedence for overlapping calls remains a confirmation question. This terminal-to-terminal path alone does not establish the primary finding's post-acknowledgment launch or High impact.
- [continuation-H4-probe_completion_write](output/continuation-H4-probe_completion_write/tlc.out): Historical MC-B: completion publishes EXECUTION_EXCEPTION over a queued-abort acknowledgment after the job has already been launched/tracked. This shares the cancellation/lifecycle serialization root; the trace uses an ordinary nonzero early SJ exit, not an impossible clean pre-bootstrap exit.
- [continuation-H4-probe_start_failure_write](output/continuation-H4-probe_start_failure_write/tlc.out): The deployment exception handler overwrites ABORTED with FAILED_TO_RUN. This status-only variant shares the queued-abort race and does not independently prove process launch or capacity loss; overlap precedence must be assessed during confirmation.

### Recommendation

Serialize cancellation and lifecycle transitions per job, or use checked status updates whose expected state is validated atomically.

---

## Bug 2: Deleting a listed job can terminate the only scheduling thread

- **Scenario / provenance**: S2 / F2 and RS-8
- **Severity (provisional)**: High
- **Invariant violated**: RunnerAliveInv
- **Config**: `MC_seed_F2.cfg`
- **Counterexample**: 5 states; [tlc.out](output/continuation-S3-F2/tlc.out)

### Trace Summary

1. Delete authorization snapshots a deletable job.
2. The scheduling scan lists that job.
3. Deletion removes its storage object.
4. The scan's metadata read raises; the scheduling thread terminates.

### Root Cause

The job manager lists storage objects and later reads each object's metadata without handling concurrent deletion. FilesystemStorage raises when a listed job has disappeared, and JobRunner calls this scan outside its deployment exception handler. The exception escapes the sole scheduling thread, preventing a later eligible job from being considered. This is a source-seeded F2/RS-8 rediscovery; the five-state minimal model path establishes thread death rather than an already-held admission-slot leak.

### Affected Code

- `nvflare/apis/impl/job_def_manager.py:520`
- `nvflare/apis/impl/job_def_manager.py:527`
- `nvflare/app_common/storages/filesystem_storage.py:327`
- `nvflare/private/fed/server/job_runner.py:650`

### Recommendation

Handle a disappearing object within the scan and isolate per-job failures from the scheduling loop.

---

## Bug 3: A late RUNNING write can replace an already-published terminal outcome

- **Scenario / provenance**: S1 / F3
- **Severity (provisional)**: Medium
- **Invariant violated**: TerminalStable
- **Config**: `MC_seed_F3.cfg`
- **Counterexample**: 33 states; [tlc.out](output/continuation-S3-F3/tlc.out)

### Trace Summary

1. An SJ exits with a nonzero error and its waiter records the outcome.
2. The runner inserts running_jobs and pauses before writing RUNNING.
3. Completion latches and publishes EXECUTION_EXCEPTION.
4. The runner overwrites that terminal status with RUNNING.

### Root Cause

The runner inserts running_jobs before writing RUNNING to persistent metadata. The completion thread can observe that insertion, classify an already-exited server process and publish a terminal status before the runner resumes its unconditional RUNNING write. The model reproduces the source-derived F3 race with a nonzero early SJ exit; the fresh controlled trace also observes completion removal before the late write. This leaves misleading persisted lifecycle state and still requires independent real-deployment confirmation.

### Affected Code

- `nvflare/private/fed/server/job_runner.py:710`
- `nvflare/private/fed/server/job_runner.py:711`
- `nvflare/private/fed/server/job_runner.py:444`
- `nvflare/private/fed/server/job_runner.py:524`

### Recommendation

Publish startup status and running ownership atomically with respect to completion, and reject transitions out of a terminal state.

---

## Bug 4: An early authoritative client failure can make START collection raise KeyError

- **Scenario / provenance**: S2/S4 / F5
- **Severity (provisional)**: Medium
- **Invariant violated**: NoStartKeyError
- **Config**: `MC_seed_F5_keyerror.cfg`
- **Counterexample**: 31 states; [tlc.out](output/continuation-S3-F5_keyerror/tlc.out)

### Trace Summary

1. The server initializes pending outcomes and starts two clients.
2. One STARTING child exits generically with rc=1, which the parent maps to infrastructure error 104.
3. The accepted report calls active fail_run and removes pending outcomes.
4. Both START launch replies succeed, but pending[job].intersection_update raises KeyError.
5. The separate outcome seed follows the resulting generic runner exception path through its FAILED_TO_RUN write; the primary KeyError trace stops at the exception.

### Root Cause

A client can fail after its process launch succeeds but before all START replies are collected. While the server process entry exists, fail_run records an authoritative failure and removes the pending-outcome entry; START collection later indexes that removed entry directly. The resulting KeyError sends the runner through its generic FAILED_TO_RUN path instead of preserving the authoritative outcome. Both the direct KeyError oracle and outcome oracle reproduce this source-derived F5 mechanism using the real generic-exit remapping rule.

### Affected Code

- `nvflare/private/fed/server/job_runner.py:309`
- `nvflare/private/fed/server/job_runner.py:360`
- `nvflare/private/fed/server/job_runner.py:720`
- `nvflare/private/fed/server/job_runner.py:841`
- `nvflare/private/fed/client/client_executor.py:635`

### Related evidence and limits

- [continuation-S3-F5](output/continuation-S3-F5/tlc.out): The separate FinalMatchesOutcome seed includes the generic FAILED_TO_RUN publication after the KeyError. It distinguishes the actual publication from the earlier stopping point of the primary NoStartKeyError trace.

### Recommendation

Coordinate START completion with fail_run, preserving an already-established authoritative failure and avoiding unconditional access to a removed pending entry.

---

## Bug 5: A metadata refresh can restore SUBMITTED after a successful abort

- **Scenario / provenance**: S1/S3 / F16 and deployment-metadata variant
- **Severity (provisional)**: High
- **Invariant violated**: NoRefreshWriteOverwrite
- **Config**: `MC_seed_F16_refresh.cfg`
- **Counterexample**: 37 states; [tlc.out](output/continuation-S3-F16_refresh/tlc.out)

### Trace Summary

1. Job j1 owns the sole resource unit; j2 receives NO_RESOURCE.
2. The scheduler begins refreshing j2's scheduling metadata and reads SUBMITTED.
3. Queued abort writes FINISHED:ABORTED and acknowledges success.
4. Refresh writes the stale whole dictionary, restoring SUBMITTED.

### Root Cause

FilesystemStorage implements a partial metadata update by reading and rewriting the whole metadata dictionary without serializing that read/write interval. A scheduler refresh for a resource-blocked job can capture SUBMITTED, overlap a successful FINISHED:ABORTED update, and then write its old status back. The dedicated F16 probe independently reaches the refresh writer; the generic F16 configuration only finds the shallower F1 deployment race. The fresh controlled trace additionally observes later launch after the lost cancellation.

### Affected Code

- `nvflare/app_common/job_schedulers/job_scheduler.py:303`
- `nvflare/apis/impl/job_def_manager.py:484`
- `nvflare/app_common/storages/filesystem_storage.py:273`
- `nvflare/app_common/storages/filesystem_storage.py:275`
- `nvflare/private/fed/server/job_cmds.py:1063`
- `nvflare/private/fed/server/job_runner.py:674`

### Related evidence and limits

- [continuation-H4-probe_deploy_meta](output/continuation-H4-probe_deploy_meta/tlc.out): The same unlocked partial metadata update occurs after deployment: it reads DISPATCHED, overlaps a successful queued abort, then restores DISPATCHED. This independently checks the deployment writer hidden by the residual and shares F16's storage RMW root.

### Recommendation

Make partial metadata updates atomic and preserve concurrent changes to unrelated fields, including status.

---

## Bug 6: Competing cleanup paths can terminate the completion thread with KeyError

- **Scenario / provenance**: S2 / historical MC-D and RS-7
- **Severity (provisional)**: High
- **Invariant violated**: CompletionAlive
- **Config**: `MC_hunt_s2_slots.cfg`
- **Counterexample**: 38 states; [tlc.out](output/continuation-H4-s2_slots/tlc.out)

### Trace Summary

1. An early SJ failure is recorded, and the runner inserts running_jobs.
2. Completion publishes EXECUTION_EXCEPTION and pauses before map removal.
3. A deletion authorized before dispatch removes the job storage.
4. The late RUNNING write raises; runner exception cleanup removes running_jobs.
5. Completion's blind deletion raises KeyError while an admission slot is still held.

### Root Cause

Completion publishes a terminal status before removing running_jobs, while the startup thread can still be pending at its RUNNING write. A previously authorized deletion makes that late status write raise, and runner exception cleanup removes the same running entry that completion subsequently deletes without a presence check. The unchecked deletion raises KeyError outside a protecting loop handler and kills completion before lifecycle release events. The final C8 38-state counterexample rechecks historical MC-D; it does not constitute a fresh real-code reproduction.

### Affected Code

- `nvflare/private/fed/server/job_runner.py:524`
- `nvflare/private/fed/server/job_runner.py:532`
- `nvflare/private/fed/server/job_runner.py:711`
- `nvflare/private/fed/server/job_runner.py:715`
- `nvflare/private/fed/server/job_cmds.py:516`

### Recommendation

Give cleanup a single owner or make map removal and lifecycle release idempotent, with per-job failure isolation in the completion loop.

---

## Bug 7: Concurrent process removal can terminate dead-client cleanup

- **Scenario / provenance**: S2 / F7 run-process iterator
- **Severity (provisional)**: High
- **Invariant violated**: SweeperAlive
- **Config**: `MC_hunt_s2_sweeper.cfg`
- **Counterexample**: 23 states; [tlc.out](output/continuation-H4-s2_sweeper/tlc.out)

### Trace Summary

1. An SJ process entry exists for a participating client and the SJ exits with an error.
2. That client's parent dies; the sweeper begins the live process-map iteration and blocks in notification.
3. The SJ waiter removes the process entry.
4. Iteration resumes and raises dictionary-changed-size RuntimeError, terminating cleanup.

### Root Cause

Dead-client notification iterates the live server run_processes dictionary while its body can wait on a child RPC. A process waiter can remove an entry during that wait, causing the iterator's next advance to raise RuntimeError outside the RPC helper's catch. BaseServer.client_cleanup does not catch that exception around remove_dead_clients, so its cleanup thread terminates and later expired clients can remain unprocessed. The model reproduces this source-derived F7 variant; live-client-map and stale-token variants remain separate source-only confirmation candidates.

### Affected Code

- `nvflare/private/fed/server/fed_server.py:296`
- `nvflare/private/fed/server/fed_server.py:323`
- `nvflare/private/fed/server/fed_server.py:1109`
- `nvflare/private/fed/server/server_engine.py:233`

### Recommendation

Iterate a stable snapshot with appropriate locking and contain individual client/job failures within the cleanup loop.

---

## Bug 8: Client resources can be freed while same-group descendants remain alive

- **Scenario / provenance**: S3 / source-seeded F10 and CL-5
- **Severity (provisional)**: High
- **Invariant violated**: NoFreeWhileGroupAlive
- **Config**: `MC_hunt_s3_groups.cfg`
- **Counterexample**: 28 states; [tlc.out](output/continuation-H4-s3_groups/tlc.out)

### Trace Summary

1. Reserve and allocate the sole unit to j1.
2. Launch/register/bootstrap the SJ and launch/register the CJ.
3. The CJ checks in and can synchronize with the running SJ.
4. Its leader exits while a same-group descendant continues using the unit.
5. The CP reaps the leader and frees the unit while the descendant remains alive.

### Root Cause

The client waiter treats leader exit as the point to release the job resources and remove its process registration. Same-process-group descendants can still be alive, while termination either returns after registration disappearance or cannot recover the group through the reaped leader PID. The repaired C8 model witnesses resource release after actual possible SJ/CJ synchronization, leaving the sole unit free while a descendant uses it. This is a source-derived F10 candidate; real local process-group behavior, a supported cooperative subprocess pattern and a later-job allocation control remain mandatory confirmation requirements.

### Affected Code

- `nvflare/private/fed/client/client_executor.py:628`
- `nvflare/private/fed/client/client_executor.py:676`
- `nvflare/private/fed/client/client_executor.py:581`
- `nvflare/utils/process_utils.py:256`
- `nvflare/utils/process_utils.py:301`

### Recommendation

Track the process group independently of the leader PID and complete group cleanup before releasing its resource ownership.

---

## Bug 9: Running-job abort can succeed while the final status is COMPLETED

- **Scenario / provenance**: S4 / historical MC-E; stop-before-marker race
- **Severity (provisional)**: Medium
- **Invariant violated**: NoStoppedSuccess
- **Config**: `MC_hunt_probe_stop_success.cfg`
- **Counterexample**: 35 states; [tlc.out](output/continuation-H4-probe_stop_success/tlc.out)

### Trace Summary

1. Default non-strict START proceeds after a lost request; the SJ is bootstrapped and tracked.
2. The administrator aborts the running job; the SJ handles abort and exits cleanly.
3. Completion observes no pending outcomes, reads run_aborted=False and publishes COMPLETED.
4. Before completion removes tracking, mark_run_aborted sets the in-memory marker and acknowledges a successful abort.

### Root Cause

stop_run sends cleanup and abort RPCs before marking the tracked Job as aborted. Completion can observe the resulting clean SJ exit, read the old abort marker, and publish COMPLETED while the handler is still waiting to mark the job. In the final C8 35-state witness, mark_run_aborted then finds the still-tracked Job and returns success without changing that published outcome. This independently rechecks historical MC-E; the earlier C5 witness placed the marker between the abort read and latch. A real abort/RPC/completion schedule and passing nonoverlap control remain separate confirmation obligations.

### Affected Code

- `nvflare/private/fed/server/job_runner.py:798`
- `nvflare/private/fed/server/job_runner.py:802`
- `nvflare/private/fed/server/job_runner.py:484`
- `nvflare/private/fed/server/job_runner.py:489`
- `nvflare/private/fed/server/job_runner.py:524`

### Related evidence and limits

- [continuation-H4-s4_unsafe](output/continuation-H4-s4_unsafe/tlc.out): The typed-102 unsafe handler starts cleanup during START, but its marker write is still pending when completion publishes success. This shares the stop-before-marker boundary and additionally depends on an unobserved SJ return code after cleanup pop. It does not independently reproduce RS-5's marker-executed-as-no-op schedule. The real rc-file and timing path remains conditional.

### Recommendation

Record abort intent before sending termination RPCs and serialize completion finalization with that intent.

---

## Bug 10: An authoritative client failure recorded after the completion outcome read can be published as success

- **Scenario / provenance**: S4 / continuation counterexample for the source-review V04 finalization gap
- **Severity (provisional)**: Medium
- **Invariant violated**: FinalMatchesOutcomeNovel
- **Config**: `MC_hunt_s4_outcome.cfg`
- **Counterexample**: 37 states; [tlc.out](output/continuation-H4-s4_outcome/tlc.out)

### Trace Summary

1. An early clean SJ exit leaves the client outcome pending and the job tracked.
2. A STARTING client fails generically; its parent maps the exit to infrastructure error 104.
3. The server report handler passes the pending check; completion then expires the barrier.
4. Completion reads no exception and retains a successful outcome.
5. Active fail_run records authoritative 104; completion then latches and publishes the earlier successful result.

### Root Cause

The report handler can pass the pending-outcome check just before completion expires the client-outcome barrier. Completion reads a successful outcome, and fail_run then records an authoritative infrastructure failure while the job is still tracked, but completion latches and publishes its earlier read. This is distinct from an intentionally ignored report after final removal: the implementation accepts and records the active-job failure. The 37-state C8 counterexample refines the source-review V04 concern; actual deadline/handler timing and independent local-deployment reproduction remain required.

### Affected Code

- `nvflare/private/fed/server/fed_server.py:933`
- `nvflare/private/fed/server/fed_server.py:951`
- `nvflare/private/fed/server/job_runner.py:484`
- `nvflare/private/fed/server/job_runner.py:492`
- `nvflare/private/fed/server/job_runner.py:524`
- `nvflare/private/fed/server/job_runner.py:817`
- `nvflare/private/fed/server/job_runner.py:837`
- `nvflare/private/fed/server/job_runner.py:575`

### Related evidence and limits

- [continuation-H3-s4_outcome](output/continuation-H3-s4_outcome/tlc.out): Historical C7 model witness placed active failure recording after the formal latch and before publication. The current C8 primary witness places it after the outcome read but before the latch; both share the finalization serialization gap.

### Recommendation

Serialize finalization with accepted outcome processing, or atomically close outcome admission before choosing a status and reject late active failure recording consistently.

---

## Bug 11: A client failure accepted in the startup tracking gap can be lost before success is published

- **Scenario / provenance**: S4 / historical MC-U1 independently rediscovered
- **Severity (provisional)**: Medium
- **Invariant violated**: NoInactiveFailureSuccess
- **Config**: `MC_hunt_u1_startup_gap.cfg`
- **Counterexample**: 37 states; [tlc.out](output/continuation-H4-u1_startup_gap/tlc.out)

### Trace Summary

1. The SJ obtains parent participants, finishes cleanly, and its waiter removes the process entry.
2. The client launch succeeds and START collection reaches the step before running_jobs insertion.
3. The STARTING client fails generically and its parent reports infrastructure error 104.
4. The report is accepted as pending, but fail_run sees no active map entry and records nothing.
5. The runner inserts tracking; the pending barrier expires while resolution is delayed; completion publishes COMPLETED while the job is still tracked.

### Root Cause

The pending-client table becomes active before running_jobs is populated, while an early-exited SJ can already have been removed from run_processes. A failure report can therefore pass the pending check but reach fail_run while neither active map contains the job, causing the failure to be ignored. The runner later inserts the job and completion publishes success without that failure record. The guarded 37-state C8 counterexample independently rechecks historical MC-U1; real supported fast-workflow timing, process failure, deadline/resolution variants and passing active-tracking controls remain confirmation obligations.

### Affected Code

- `nvflare/private/fed/server/job_runner.py:304`
- `nvflare/private/fed/server/job_runner.py:308`
- `nvflare/private/fed/server/job_runner.py:710`
- `nvflare/private/fed/server/job_runner.py:817`
- `nvflare/private/fed/server/fed_server.py:933`
- `nvflare/private/fed/server/fed_server.py:951`
- `nvflare/private/fed/server/fed_server.py:957`

### Recommendation

Establish lifecycle ownership before accepting client outcomes, and retain pending startup failures until the runner can apply them instead of treating the temporary tracking gap as final inactivity.

---

## Bug 12: Stale delete authorization can strand a running job and its admission slot

- **Scenario / provenance**: S2 / historical MC-C and source stale-delete lead
- **Severity (provisional)**: High
- **Invariant violated**: NoDeletedTrackedSlot
- **Config**: `MC_hunt_probe_deleted_slot.cfg`
- **Counterexample**: 27 states; [tlc.out](output/continuation-H4-probe_deleted_slot/tlc.out)

### Trace Summary

1. Delete obtains a SUBMITTED Job snapshot before dispatch.
2. The runner deploys, collects successful START replies, holds the admission slot and publishes RUNNING.
3. The earlier delete request removes the job storage without rechecking current status.
4. The model now has a deleted but tracked job outside the completion-removal interval; source completion publication retries cannot reach slot-release events.

### Root Cause

The delete handler checks the status of an earlier Job snapshot, so a request authorized while SUBMITTED can remove storage after START has succeeded and the job is tracked as RUNNING. When completion later publishes its terminal status, the missing store object makes every retry fail before map removal and lifecycle release. With the concurrency limit occupied, later eligible work cannot be admitted. The fresh 27-state C8 counterexample independently rechecks historical MC-C and excludes the benign interval after successful terminal publication; live completion retry and later-job controls remain confirmation obligations.

### Affected Code

- `nvflare/private/fed/server/job_cmds.py:516`
- `nvflare/private/fed/server/job_cmds.py:527`
- `nvflare/private/fed/server/job_runner.py:524`
- `nvflare/private/fed/server/job_runner.py:530`
- `nvflare/private/fed/server/job_runner.py:532`
- `nvflare/app_common/job_schedulers/job_scheduler.py:263`

### Recommendation

Serialize deletion authorization with lifecycle ownership, and ensure missing metadata cannot indefinitely prevent completion cleanup and admission release.

---

## Bug 13: Accepted noncanonical min_clients can repeatedly starve a later eligible job

- **Scenario / provenance**: S2 / source-seeded F4; pre-reservation numeric-string case
- **Severity (provisional)**: High
- **Invariant violated**: AdmissionProgress
- **Config**: `MC_hunt_live_admission.cfg`
- **Counterexample**: 5 states; [tlc.out](output/continuation-H4-live_admission/tlc.out)

### Trace Summary

1. The validator-accepted numeric-string job j1 precedes a well-formed j2 in submission order.
2. A scan reads both jobs and sorts j1 first.
3. The min_sites comparison for j1 raises before any resource request or retry-count increment.
4. The whole-list catch returns no selected job; the fair scan/try cycle repeats while j2 remains SUBMITTED and capacity is free.

### Root Cause

Job validation accepts a numeric string for min_clients by converting it locally, but leaves the original string in persisted metadata, which Job construction retains unchanged. The scheduler then raises TypeError before updating its retry history; its outer catch abandons the whole candidate list. Each later scan retries the same oldest job, so a well-formed later job remains SUBMITTED despite free capacity. The C8 temporal counterexample has five listed states with a loop back to state 1 (seven distinct reachable states) and satisfies the modeled fairness assumptions. This is the original source-seeded F4 mechanism; real public submission, later-job impact and a numeric-value control remain independent confirmation obligations.

### Affected Code

- `nvflare/private/fed/server/job_meta_validator.py:240`
- `nvflare/apis/job_def.py:241`
- `nvflare/app_common/job_schedulers/job_scheduler.py:166`
- `nvflare/app_common/job_schedulers/job_scheduler.py:292`
- `nvflare/app_common/job_schedulers/job_scheduler.py:344`
- `nvflare/app_common/job_schedulers/job_scheduler.py:365`

### Recommendation

Normalize validated metadata or reject noncanonical types, and isolate per-job scheduling exceptions so one accepted job cannot prevent later candidates from being considered.

---

## Convergence evidence

Final MC.cfg run: [continuation-C8-MC-resume](output/continuation-C8-MC-resume/tlc.out). depth=39, generated=414,115,288, distinct=74,561,992, queue=32,570,191. 30-minute budget; no violation reported; incomplete search.

This uses the explicit known-writer residual after the retained strict TerminalStable failure. It does not certify TerminalStable or excluded bug families. Fresh replay and negative-control records are linked in the coverage audit.

## Complete hunting matrix

Each frozen run directory contains its model, configuration, task manifest, TLC log and process outcome. Statistics are the last values TLC reported; simulation checked-state counts include repetitions and are not distinct-state coverage. A time budget is not exhaustive completion; a violation is classified independently of process exit. No bounds were reduced to obtain depth.

| Config / mode | Search statistics | Result | Evidence |
|---|---|---|---|
| `MC_hunt_live_admission.cfg` / BFS | depth=5, generated=16, distinct=7, queue=0 | Case C: AdmissionProgress; F4 validator-accepted numeric-string poison starves later job | [continuation-H4-live_admission](output/continuation-H4-live_admission/tlc.out) |
| `MC_hunt_live_cleanup.cfg` / BFS | depth=42, generated=21,383,522, distinct=4,006,867, queue=1,413,343 | 30-minute budget; no violation reported; incomplete search | [continuation-H4b-live_cleanup](output/continuation-H4b-live_cleanup/tlc.out) |
| `MC_hunt_live_finalize.cfg` / BFS | depth=39, generated=20,786,066, distinct=4,717,707, queue=1,900,789 | 30-minute budget; no violation reported; incomplete search | [continuation-H4b-live_finalize](output/continuation-H4b-live_finalize/tlc.out) |
| `MC_hunt_probe_admin_abort.cfg` / BFS | depth=14, generated=5,796, distinct=1,508, queue=576 | Case C: NoAdminAbortOverwrite; historical MC-A stale queued-abort writer | [continuation-H4-probe_admin_abort](output/continuation-H4-probe_admin_abort/tlc.out) |
| `MC_hunt_probe_cant_schedule.cfg` / BFS | depth=39, generated=138,212,975, distinct=31,413,140, queue=14,510,129 | 30-minute budget; no violation reported; incomplete search | [continuation-H4-probe_cant_schedule](output/continuation-H4-probe_cant_schedule/tlc.out) |
| `MC_hunt_probe_cant_schedule.cfg` / simulation | states_checked=78,016,422, traces=780,167, depth_limit=100 | 30-minute budget; no violation reported; incomplete search | [continuation-H4b-sim-probe_cant_schedule](output/continuation-H4b-sim-probe_cant_schedule/tlc.out) |
| `MC_hunt_probe_completion_write.cfg` / BFS | depth=32, generated=5,297,639, distinct=1,111,325, queue=453,386 | Case C: NoCompletionOverwrite; historical MC-B completion overwrites queued-abort acknowledgment | [continuation-H4-probe_completion_write](output/continuation-H4-probe_completion_write/tlc.out) |
| `MC_hunt_probe_deleted_slot.cfg` / BFS | depth=27, generated=153,117, distinct=40,679, queue=10,070 | Case C: NoDeletedTrackedSlot; historical MC-C stale delete strands tracked admission slot | [continuation-H4-probe_deleted_slot](output/continuation-H4-probe_deleted_slot/tlc.out) |
| `MC_hunt_probe_deploy_meta.cfg` / BFS | depth=15, generated=9,149, distinct=2,242, queue=721 | Case C: NoDeployMetaOverwrite; F16 deployment-metadata RMW variant | [continuation-H4-probe_deploy_meta](output/continuation-H4-probe_deploy_meta/tlc.out) |
| `MC_hunt_probe_start_failure_write.cfg` / BFS | depth=14, generated=6,895, distinct=1,738, queue=630 | Case C: NoStartFailureOverwrite; queued-abort terminal overwrite by startup exception handler | [continuation-H4-probe_start_failure_write](output/continuation-H4-probe_start_failure_write/tlc.out) |
| `MC_hunt_probe_stop_success.cfg` / BFS | depth=35, generated=4,960,294, distinct=1,289,908, queue=583,501 | Case C: NoStoppedSuccess; historical MC-E stop before abort marker | [continuation-H4-probe_stop_success](output/continuation-H4-probe_stop_success/tlc.out) |
| `MC_hunt_s1_contracts.cfg` / BFS | depth=13, generated=4,102, distinct=1,282, queue=261 | Case C: TerminalStable; F1 duplicate | [continuation-H4-s1_contracts](output/continuation-H4-s1_contracts/tlc.out) |
| `MC_hunt_s1_status.cfg` / BFS | depth=39, generated=133,238,176, distinct=29,885,311, queue=13,693,983 | 30-minute budget; no violation reported; incomplete search | [continuation-H4-s1_status](output/continuation-H4-s1_status/tlc.out) |
| `MC_hunt_s2_contracts.cfg` / BFS | depth=7, generated=353, distinct=158, queue=78 | Case C: RunnerAliveInv; F2 duplicate | [continuation-H4-s2_contracts](output/continuation-H4-s2_contracts/tlc.out) |
| `MC_hunt_s2_slots.cfg` / BFS | depth=38, generated=40,218,829, distinct=9,317,562, queue=4,134,980 | Case C: CompletionAlive; Historical MC-D / RS-7 | [continuation-H4-s2_slots](output/continuation-H4-s2_slots/tlc.out) |
| `MC_hunt_s2_slots_c2.cfg` / BFS | depth=40, generated=132,675,627, distinct=28,348,605, queue=11,917,928 | 30-minute budget; no violation reported; incomplete search | [continuation-H4-s2_slots_c2](output/continuation-H4-s2_slots_c2/tlc.out) |
| `MC_hunt_s2_sweeper.cfg` / BFS | depth=24, generated=9,201, distinct=2,963, queue=1,203 | Case C: SweeperAlive; F7 run_processes live iterator | [continuation-H4-s2_sweeper](output/continuation-H4-s2_sweeper/tlc.out) |
| `MC_hunt_s3_groups.cfg` / BFS | depth=28, generated=7,919, distinct=2,531, queue=761 | Case C: NoFreeWhileGroupAlive; F10 same-group descendants | [continuation-H4-s3_groups](output/continuation-H4-s3_groups/tlc.out) |
| `MC_hunt_s3_promptcancel.cfg` / BFS | depth=44, generated=18,743,438, distinct=3,897,036, queue=1,459,473 | 30-minute budget; no violation reported; incomplete search | [continuation-H4b-s3_promptcancel](output/continuation-H4b-s3_promptcancel/tlc.out) |
| `MC_hunt_s3_resources.cfg` / BFS | depth=43, generated=129,396,910, distinct=23,776,496, queue=8,772,449 | 30-minute budget; no violation reported; incomplete search | [continuation-H4-s3_resources](output/continuation-H4-s3_resources/tlc.out) |
| `MC_hunt_s4_groundtruth.cfg` / BFS | depth=44, generated=179,186,742, distinct=30,213,171, queue=8,733,877 | 30-minute budget; no violation reported; incomplete search | [continuation-H4-s4_groundtruth](output/continuation-H4-s4_groundtruth/tlc.out) |
| `MC_hunt_s4_outcome.cfg` / BFS | depth=37, generated=13,731,237, distinct=3,132,375, queue=1,340,723 | Case C: FinalMatchesOutcomeNovel; Accepted authoritative failure after completion outcome read; V04 split-finalization race | [continuation-H4-s4_outcome](output/continuation-H4-s4_outcome/tlc.out) |
| `MC_hunt_s4_unsafe.cfg` / BFS | depth=41, generated=3,797,331, distinct=748,530, queue=296,676 | Case C: FinalMatchesOutcomeNovel; Unsafe report stop-before-marker variant; not the original no-op-marker seed | [continuation-H4-s4_unsafe](output/continuation-H4-s4_unsafe/tlc.out) |
| `MC_hunt_s5_policy.cfg` / BFS | depth=43, generated=145,675,919, distinct=25,801,699, queue=8,485,496 | 30-minute budget; no violation reported; incomplete search | [continuation-H4-s5_policy](output/continuation-H4-s5_policy/tlc.out) |
| `MC_hunt_startup_failure.cfg` / BFS | depth=37, generated=98,823,566, distinct=19,097,576, queue=8,426,654 | 30-minute budget; no violation reported; incomplete search | [continuation-H4-startup_failure](output/continuation-H4-startup_failure/tlc.out) |
| `MC_hunt_u1_startup_gap.cfg` / BFS | depth=37, generated=11,681,274, distinct=2,703,423, queue=1,177,925 | Case C: NoInactiveFailureSuccess; Historical MC-U1 startup tracking gap | [continuation-H4-u1_startup_gap](output/continuation-H4-u1_startup_gap/tlc.out) |

## Seed fidelity

| Seed config | Evidence / classification | Statistics |
|---|---|---|
| `MC_seed_F1.cfg` | [continuation-S3-F1](output/continuation-S3-F1/tlc.out): Case C: AbortHonored; F1 acknowledged queued-abort overwrite. C8: successful queued abort at JC:1063 is overwritten by unconditional JR:670 DISPATCHED after its earlier SUBMITTED check. Twelve-state source-seeded F1 rediscovery. Fresh controlled implementation trace also exercises subsequent launch; public local-deployment confirmation remains separate. | depth=15, generated=247, distinct=100, queue=12 |
| `MC_seed_F16.cfg` | [continuation-S3-F16](output/continuation-S3-F16/tlc.out): Case C: TerminalStable; F1 duplicate; not F16 fidelity. C8 generic seed stops at SetDispatched overwriting ABORTED in 13 states: F1 duplicate, not refresh fidelity. The dedicated F16_refresh seed independently exercises the advertised RMW mechanism. | depth=15, generated=449, distinct=175, queue=22 |
| `MC_seed_F16_refresh.cfg` | [continuation-S3-F16_refresh](output/continuation-S3-F16_refresh/tlc.out): Case C: NoRefreshWriteOverwrite; F16. C8: j1 holds the sole unit and j2 cannot reserve; refresh snapshots SUBMITTED, queued abort writes ABORTED, then refresh rewrites the stale whole dictionary (JS:303; JD:484-505; FilesystemStorage:271-275). Thirty-seven states. Source-seeded F16; fresh controlled mechanism/control evidence is retained, with separate public-deployment confirmation pending. | depth=37, generated=467,361, distinct=117,748, queue=47,033 |
| `MC_seed_F2.cfg` | [continuation-S3-F2](output/continuation-S3-F2/tlc.out): Case C: RunnerAliveInv; F2/RS-8 list/read deletion. C8: list, authorized deletion, then missing metadata read kills the runner outside its deployment handler (JD:520/527, FilesystemStorage:327, JR:650). Five states; j2 remains SUBMITTED with no held slot. This establishes the modeled scheduling-thread death, not an already-held slot leak. Source-seeded F2/RS-8; separate confirmation required. | depth=11, generated=99, distinct=44, queue=7 |
| `MC_seed_F3.cfg` | [continuation-S3-F3](output/continuation-S3-F3/tlc.out): Case C: TerminalStable; F3 late RUNNING over terminal publication. C8: ordinary early SJ rc=1 is recorded by the actual waiter read; running_jobs insertion permits completion to publish EXECUTION_EXCEPTION before JR:711 overwrites it with RUNNING. Thirty-three states. Source-seeded F3; no premature clean SJ/CJ return is assumed. | depth=33, generated=46,574, distinct=14,500, queue=5,086 |
| `MC_seed_F5.cfg` | [continuation-S3-F5](output/continuation-S3-F5/tlc.out): Case C: FinalMatchesOutcome; F5 START KeyError and authoritative-outcome loss. C8: whole-map START construction precedes delivery. A STARTING CJ generic rc=1 maps to authoritative 104; active fail_run removes pending. Both launch replies succeed, START collection indexes the missing entry, and the generic exception handler publishes FAILED_TO_RUN. Thirty-three states; no sync-deadline or bare typed-OS-code assumption. Source-seeded F5, independent implementation confirmation pending. | depth=34, generated=53,612, distinct=14,638, queue=7,568 |
| `MC_seed_F5_keyerror.cfg` | [continuation-S3-F5_keyerror](output/continuation-S3-F5_keyerror/tlc.out): Case C: NoStartKeyError; F5 direct oracle. C8 direct oracle: both launch replies succeed after STARTING generic rc=1 maps to authoritative 104 and active fail_run removes pending outcomes (JR:360/841; CX:635-643). Thirty-one states, stopping at NoStartKeyError. The separate F5 outcome seed includes the later FAILED_TO_RUN write. Source-seeded F5; no real deployment reproduction claimed. | depth=32, generated=12,831, distinct=3,619, queue=1,684 |
| `MC_seed_F9.cfg` | [continuation-S3-F9](output/continuation-S3-F9/tlc.out): Case B: ResourceConservation; unsupported app-missing defensive branch. C8 defensive seed reaches ResourceConservation failure in 19 states through EnableUnsupported/app disappearance after allocation. No supported cooperative in-tree cause of that disappearance was established; a same-token duplicate instead fails allocation first. Case B relative to task reachability, retained as a defensive oracle control. All normal and hunt cfgs disable this branch; no product defect claimed. | depth=22, generated=238, distinct=97, queue=20 |

## Not Reproduced

| Scenario / check | Config | States explored | Result / limit |
|---|---|---|---|
| EventualCleanup under declared fairness | `MC_hunt_live_cleanup.cfg` (BFS) | depth=42, generated=21,383,522, distinct=4,006,867, queue=1,413,343 | 30-minute budget; no violation reported; incomplete search |
| BoundedFinalization under declared fairness | `MC_hunt_live_finalize.cfg` (BFS) | depth=39, generated=20,786,066, distinct=4,717,707, queue=1,900,789 | 30-minute budget; no violation reported; incomplete search |
| NoCantSchedOverwrite / historical RS-3 writer | `MC_hunt_probe_cant_schedule.cfg` (BFS) | depth=39, generated=138,212,975, distinct=31,413,140, queue=14,510,129 | 30-minute budget; no violation reported; incomplete search |
| NoCantSchedOverwrite / historical RS-3 writer | `MC_hunt_probe_cant_schedule.cfg` (simulation) | states_checked=78,016,422, traces=780,167, depth_limit=100 | 30-minute budget; no violation reported; incomplete search |
| Known-status residuals and OneShot | `MC_hunt_s1_status.cfg` (BFS) | depth=39, generated=133,238,176, distinct=29,885,311, queue=13,693,983 | 30-minute budget; no violation reported; incomplete search |
| NoOrphanSlotNovel and SlotBalance | `MC_hunt_s2_slots_c2.cfg` (BFS) | depth=40, generated=132,675,627, distinct=28,348,605, queue=11,917,928 | 30-minute budget; no violation reported; incomplete search |
| ReservationDrain plus conservation/TTL safety | `MC_hunt_s3_promptcancel.cfg` (BFS) | depth=44, generated=18,743,438, distinct=3,897,036, queue=1,459,473 | 30-minute budget; no violation reported; incomplete search |
| Discrete list-unit ownership and TTL safety | `MC_hunt_s3_resources.cfg` (BFS) | depth=43, generated=129,396,910, distinct=23,776,496, queue=8,772,449 | 30-minute budget; no violation reported; incomplete search |
| RecordedExecutionErrorNotMasked | `MC_hunt_s4_groundtruth.cfg` (BFS) | depth=44, generated=179,186,742, distinct=30,213,171, queue=8,733,877 | 30-minute budget; no violation reported; incomplete search |
| structural lifecycle checks after source-policy correction | `MC_hunt_s5_policy.cfg` (BFS) | depth=43, generated=145,675,919, distinct=25,801,699, queue=8,485,496 | 30-minute budget; no violation reported; incomplete search |
| Ordinary SJ launch exception with strict slot/completion checks | `MC_hunt_startup_failure.cfg` (BFS) | depth=37, generated=98,823,566, distinct=19,097,576, queue=8,426,654 | 30-minute budget; no violation reported; incomplete search |
| unsupported app-missing defensive branch | `MC_seed_F9.cfg` (BFS) | depth=22, generated=238, distinct=97, queue=20 | Case B: ResourceConservation; unsupported app-missing defensive branch |
| F6 immediate cancellation | Historical s3_promptcancel | 8-state counterexample retained | Case A: expiry-backed retention is allowed; revised ReservationDrain is a finite-batch fair-tick property, not a time bound. |
| F15 cross-phase START tolerance | Historical s5_policy | 25-state counterexample retained | Case A: missing targets/explicit errors are fatal by policy. Removed as N/A; current cfg covers structural lifecycle checks only. |
| F17/F20 unconditional ground-truth error delivery | Historical s4_groundtruth | 31-state diagnostic retained | Case A for the reliable-signal oracle; revised check covers recorded errors. End-to-end status loss remains in the source-only confirmation queue. |
| Source-only GPU arithmetic/binding, parent-death retry, re-registration, late heartbeat, typed return codes, restart, cleanup exceptions and other retained leads | No complete reference-model mechanism | Not a TLC result | See all 33 source-review Scenarios and the reconciliation table. No omission constitutes a refutation. |

## Repairs and evidence limits

The changelog records Case A oracle changes and Case B model repairs. Key repairs separate SJ launch/registration/bootstrap, START request construction from delivery, actual waiter read/pop, CP reap/report/free, report acceptance from active fail_run, independent admin contexts, and completion outcome reads/latch. Clean CJ exit requires a possible runner sync; a failed sync can return an ordinary process error. CP death does not automatically kill the child, and retained remote handler state cannot disable the server START-reply deadline. Strict probes audit the families hidden by residuals. All fresh trace projections replay after repairs, with corruption/input/truncation controls recorded separately.

The harness uses real pinned handlers, store, scheduler and resource code with controlled process/transport/authentication edges and a stronger tracing lock. Hidden sync witnesses are inferred prerequisites, not observed handshakes. Real OS descendants, typed rc-file paths, default GPU arithmetic, actual authentication and end-to-end deployment belong to the separate confirmation phase. Timing controls and faults must be labeled there, with passing controls and source provenance.

Original Claude spend: **$180.5573146**, including preflight. New Codex subscription usage is accounted separately in the launcher usage artifacts. API-equivalent Codex estimates are not new Claude-account charges.
