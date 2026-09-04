# Confirmation Report — slatedb-byom-complete

## Final Result

Reproduced bugs: 4 = 3 NEW + 1 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 1
Dropped: 2
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 7
Dispositions: 7 total = 4 reproduced + 0 env-limited + 0 masked + 1 false-positive + 0 needs-more-info + 2 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | CR-2 | FALSE POSITIVE | no |
| 5 | CR-3 | DROPPED | no |
| 6 | CR-4 | DROPPED | no |
| 7 | CR-6 | REPRODUCED | yes |

## Entry 1: External submissions bypass cross-compaction conflict checks

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: <run-output>/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/slatedb/slatedb/issues/1838; fix-status: unfixed)
- **Location**: slatedb/src/compactor.rs:478

## Description

Confirmed. `Admin::submit_compaction` reaches `Compactor::submit`, which inserts an external `Submitted` compaction directly into `.compactions` at `slatedb/src/compactor.rs:478`. The local scheduler path would reject active destination collisions in `CompactorState::add_compaction` at `slatedb/src/compactor_state.rs:1005`, but `validate_compaction` explicitly says cross-compaction conflicts are not rechecked there at `slatedb/src/compactor.rs:914`.

As a result, two external submissions with the same SR source and destination can both be promoted to `Scheduled` by `maybe_validate_submitted_compactions` at `slatedb/src/compactor.rs:1211`.

## Trigger scenario

Level 0 public API sequence:

1. Create a DB and let normal compaction produce an existing sorted run.
2. Generate a public manual `CompactionRequest::Full` spec.
3. Submit the same spec twice through `Admin::submit_compaction`.
4. Run the public compactor loop until both entries become `Scheduled`.
5. Run the public compaction worker with capacity 2.

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes**.
2. Level 2/3 were not used.
3. Real consumer/caller: `CompactionWorkerHandler::poll_and_claim` claims both scheduled entries at `slatedb/src/compaction_worker.rs:327` and dispatches them at `slatedb/src/compaction_worker.rs:393`; `TokioCompactionExecutor::start_compaction_job` then panics at `slatedb/src/compactor_executor.rs:893`.
4. The failure is not masked. The worker returns public `ErrorKind::Closed(CloseReason::Panic)`, mapped from `BackgroundTaskPanic` at `slatedb/src/error.rs:619`.

## Developer intent

The design docs require compactions to avoid conflicting ongoing work: RFC-0002 says execution should ensure no other ongoing compaction includes the same SSTs or SRs (`rfcs/0002-compaction.md:314`). RFC-0013 says local scheduling uses `CompactorState::add_compaction` to enforce destination conflict rules, while external requests enter through `Admin::submit_compaction` with no validation at submit time (`rfcs/0013-compaction-state-persistence.md:283`, `rfcs/0013-compaction-state-persistence.md:295`).

The mechanism is already tracked upstream in open issue #1838 and open, unmerged PR #2018.

## Reproduction result

Wrote and executed:

`<run-output>/repro/test_bugMC-1_external_compaction_conflict.sh`

Command exited successfully after detecting the bug:

```text
Running MC-1 public API reproduction from <run-output>/repro/tmp/slatedb-mc1-repro.Vqfqru
Generated manual Full compaction spec: sources=[SortedRun(0)], destination=Some(0)
Submitted duplicate external compactions: first=01M1M4W5YCX917Q9VG3F60E92S, second=01M1M4W5YC1AW6QC69EF9PY651, initial_statuses=Submitted/Submitted
Coordinator promoted duplicate external submissions: scheduled_matches=2

thread 'tokio-rt-worker' (835595) panicked at <run-output>/confirmation/MC-1/worktree/slatedb/src/compactor_executor.rs:893:9:
assertion failed: !tasks.values().any(|task| task.destination == dst)
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
Worker returned error: Closed error: background task panicked. name=`compaction_worker`
Worker error kind: Closed(Panic)
BUG TRIGGERED: duplicate Scheduled compactions caused worker panic
```

## Recommendation

Apply the same active-compaction conflict checks to externally submitted work before promotion to `Scheduled`, including conflicts among the batch of currently `Submitted` entries and against existing `Scheduled`/`Running` entries. Invalid duplicate external specs should be rejected or marked `Failed` before any worker can claim them.

---

## Entry 2: External jobs can overflow the coordinator concurrency limit

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: <run-output>/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: slatedb/src/compactor.rs:1178

## Description
Confirmed. `maybe_validate_submitted_compactions` promotes every valid `Submitted` tiered compaction to `Scheduled` without checking the coordinator concurrency budget. The scheduler budget only subtracts current `Running` records, and workers claim using per-worker capacity, so two workers can each claim one job while the coordinator limit is one.

Known-status search covered upstream issues and recently merged/closed PRs. Closest items were different: [PR #1926](https://github.com/slatedb/slatedb/pull/1926), [issue #1850](https://github.com/slatedb/slatedb/issues/1850), [issue #1838](https://github.com/slatedb/slatedb/issues/1838), and [PR #1853](https://github.com/slatedb/slatedb/pull/1853). I also checked issue/PR searches for `max_concurrent_compactions`, external submissions, Submitted/Scheduled, worker/coordinator terms.

## Trigger scenario
A DB is built with `CompactorOptions::max_concurrent_compactions = 1` and no embedded worker. A custom public scheduler admits a local `aaa` segment compaction. Then `Admin::submit_compaction` submits a disjoint external `bbb` segment compaction. The coordinator validates both to `Scheduled`; two normal external workers, each with local capacity one, then claim one each.

## Developer intent
`CompactorOptions::max_concurrent_compactions` is documented as “maximum number of concurrent compactions to execute at once” at `slatedb/src/config.rs:1110`. `CompactionWorkerOptions::max_concurrent_compactions` is separately per-worker at `slatedb/src/config.rs:1191`. Multiple standalone workers are a supported operating mode in `slatedb/src/compaction_worker.rs:1`.

## Reproduction result
Executed `<run-output>/repro/test_bugMC-2_external_capacity_overflow.sh`.

```text
running 1 test
Level 0 attempt: public DB/Admin APIs and two normal external workers, no timing gate.
level0: before workers counts=StatusCounts { submitted: 0, scheduled: 2, running: 0, compacted: 0, completed: 0, failed: 0, total: 2 }
level0: coordinator_max_concurrent_compactions=1 worker_capacity_each=1 max_running_observed=0 compacted_puts_blocked=0
Level 0 result: max_running_observed=0
Level 1 attempt: same public APIs; delay only compacted SST writes after worker claims.
level1: before workers counts=StatusCounts { submitted: 0, scheduled: 2, running: 0, compacted: 0, completed: 0, failed: 0, total: 2 }
level1 timing gate blocked compacted SST put #1: tmp/test_bug_mc2_external_capacity_overflow_level1/compacted/01M1M65AGA65GZ2TYFWSHQ1VVB.sst
level1 timing gate blocked compacted SST put #2: tmp/test_bug_mc2_external_capacity_overflow_level1/compacted/01M1M65AGA5X3K7Q4T2F207SHG.sst
level1: coordinator_max_concurrent_compactions=1 worker_capacity_each=1 max_running_observed=2 compacted_puts_blocked=2
level1: running-observation id=01M1M65AFCW197QEQW178SNYNT status=Running segment=aaa destination=Some(0) worker=Some(WorkerSpec { worker_id: "01M1M65AG7M5QHB7B7HM6473ZY", last_heartbeat_ms: 1788457691657 })
level1: running-observation id=01M1M65AFGBG2QEVVWFAXAD64Q status=Running segment=bbb destination=Some(1) worker=Some(WorkerSpec { worker_id: "01M1M65AG7HMY5ZBDPNJPKTSC7", last_heartbeat_ms: 1788457691657 })
Level 1 result: max_running_observed=2
test external_jobs_can_overflow_coordinator_concurrency_limit ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 3.15s
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? yes. Level 1 did, using public APIs plus timing help only.
2. No Level 2 or Level 3 was used.
3. Real consumer/caller: `Admin::read_compactions` observes two `Running` records; real workers dispatch both jobs through `slatedb/src/compaction_worker.rs:393`.
4. The `Running` status is not permanent, but it is not masked: both jobs are already claimed and executing before later completion can reduce the count.

## Recommendation
Make coordinator admission and worker claim share one durable global budget. At minimum, count `Scheduled` plus `Running` against the coordinator limit when promoting external submissions, and prevent worker CAS claims from exceeding that same global count.

---

## Entry 3: Repeated scheduler ticks can overflow the coordinator concurrency limit

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: <run-output>/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `slatedb/src/compactor.rs:1178`

Checklist:
1. Level 0/1 alone triggered it: **yes**. The repro uses public `Db` and `Admin` APIs plus normal coordinator/worker loops; timing only keeps jobs observable.
2. Level 2/3 were not used.
3. Real consumers: `CompactionWorkerHandler::poll_and_claim` at `slatedb/src/compaction_worker.rs:393` dispatches both claimed jobs; `Admin::read_compactions` at `slatedb/src/admin.rs:121` observes two `Running` jobs.
4. The bad state is not masked before observation. Jobs may later finish, but the configured live concurrency limit is exceeded while both run.

## Description
The coordinator validates all `Submitted` compactions into `Scheduled` without reapplying `max_concurrent_compactions`. Worker capacity is then enforced per worker, so two standalone workers can each claim one scheduled job even when the coordinator limit is `1`.

## Trigger scenario
Two valid external compactions are submitted through `Admin::submit_compaction`, the coordinator runs with `max_concurrent_compactions=1`, and two workers poll independently. The result matches the MC trace: backlog submission, bulk promotion to `Scheduled`, then independent worker claims to `Running`.

## Developer intent
`CompactionStatus::counts_against_max_concurrent` marks `Submitted`, `Scheduled`, and `Running` as capacity-consuming, and `CompactorOptions.max_concurrent_compactions` documents a global concurrent compaction limit. The RFC also says submitted compactions should be handled like internal ones. I searched upstream issues and recent/closed PRs; the closest related fix was [slatedb/slatedb#1926](https://github.com/slatedb/slatedb/pull/1926), but it fixed size-tiered scheduler accounting for completed jobs, not over-promotion of externally submitted jobs plus multi-worker claiming.

## Reproduction result
Executed `<run-output>/repro/test_bugMC-3_external_submitted_overflow.sh`.

```text
submitted two valid admin compactions while coordinator max_concurrent_compactions=1
submitted ids: 01M1M75Y7NCA0MF1Q19FQB8MH8 status=Submitted, 01M1M75Y7NH7D00KSWXG16B1WA status=Submitted
after coordinator validation with max_concurrent_compactions=1:
  id=01M1M75Y7NCA0MF1Q19FQB8MH8 status=Scheduled worker=None segment=b"aaa" destination=Some(0) sources=[SstView(Ulid(2162113972805668109866259596731195893))]
  id=01M1M75Y7NH7D00KSWXG16B1WA status=Scheduled worker=None segment=b"bbb" destination=Some(1) sources=[SstView(Ulid(2162113972805246149374193618458248576))]
after two standalone workers poll with per-worker max_concurrent_compactions=1:
  id=01M1M75Y7NCA0MF1Q19FQB8MH8 status=Running worker=01M1M75Y81DQQNQ5T83K3DGG7E segment=b"aaa" destination=Some(0) sources=[SstView(Ulid(2162113972805668109866259596731195893))]
  id=01M1M75Y7NH7D00KSWXG16B1WA status=Running worker=01M1M75Y81RZZXH4P7X270PS93 segment=b"bbb" destination=Some(1) sources=[SstView(Ulid(2162113972805246149374193618458248576))]
observed_running=2
coordinator_max_concurrent_compactions=1
BUG_TRIGGERED: observed 2 Running compactions with coordinator max 1
```

## Recommendation
Apply one global capacity check across `Submitted`, `Scheduled`, and `Running` before promoting submitted compactions, and ensure worker claims cannot collectively exceed the coordinator’s configured capacity.

---

## Entry 4: Non-atomic compaction publication may expose recovery and GC safety gaps

- **Finding ID**: CR-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: <run-output>/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: slatedb/src/compactor_state_protocols.rs:326

## Description
CR-2’s intermediate durable state is reachable: `write_state_safely()` publishes the manifest before `.compactions`, so a crash can leave the manifest post-compaction while the compaction record is still `Compacted`.

I did not confirm an unsafe recovery or GC consequence. Restart intentionally treats that stale `Compacted` entry as `Failed` when sources are absent, while the output remains manifest-active and removed sources remain checkpoint-protected.

## Trigger scenario
Worker writes `Compacted` with output SSTs, coordinator publishes the checkpointed manifest, then crashes before terminalizing `.compactions`. On restart, `commit_compacted_entries()` validates against the current manifest, sees sources absent, and marks the stale entry `Failed`.

## Developer intent
RFC-0025 explicitly defines this recovery behavior and says `Failed` is safe after sources are absent because the manifest was already updated and output SSTs are protected from GC. PR #1701 added this protocol and its recovery test: https://github.com/slatedb/slatedb/pull/1701

Prior-report search covered upstream issues and recently merged/closed PRs. I found adjacent GC issue #1044 and validation PR #1836, but neither reports this post-manifest/stale-`.compactions` mechanism as a defect:
https://github.com/slatedb/slatedb/issues/1044
https://github.com/slatedb/slatedb/pull/1836

## Reproduction result
Repro written and executed:
`<run-output>/repro/test_bugCR-2_non_atomic_publication.sh`

Command:
```bash
timeout 10m <run-output>/repro/test_bugCR-2_non_atomic_publication.sh
```

Captured output excerpt:
```text
EXIT_STATUS=0
CR2_LEVEL0_ATTEMPT public put/flush/background compaction/read path, no crash injection
CR2_LEVEL0_RESULT normal operations completed without a data-read failure or terminal-state disagreement
CR2_LEVEL1_RESULT no existing failpoint exists at the exact post-manifest/pre-compactions crash point; timing alone cannot deterministically kill an internal await boundary in this in-process test
CR2_LEVEL2_ATTEMPT inject reachable durable post-manifest/pre-compactions crash state, restart coordinator, run compacted GC
CR2_LEVEL2_RESULT no wrong outcome: stale Compacted terminalized_as=Failed output_ssts=1 source_ssts_pinned=1 remaining_after_gc=2
test compactor::tests::test_bug_cr2_level2_post_manifest_crash_recovery_and_gc_safety ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 1886 filtered out; finished in 0.02s
CR2_LEVEL2_RESULT completed without reproducing the claimed recovery or GC safety gap
CR2_LEVEL3_RESULT not attempted: Level 2 instantiated the exact reachable post-manifest/pre-compactions crash state and observed correct recovery plus GC behavior; adding a source delay would not expose a different consumer consequence without changing logic
```

## Recommendation
No bug fix recommended for CR-2. Keep the manifest-first/checkpoint protocol and the restart `Compacted -> Failed` handling; a regression test around the exact crash window would be useful if upstream wants this guarantee covered directly.

---

## Entry 5: Heartbeat reclaim can race worker ownership and completion

- **Finding ID**: CR-3
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: <run-output>/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/slatedb/slatedb/issues/1850; fix-status: fixed)
- **Location**: `slatedb/src/compactor.rs:725`

## Description
CR-3 duplicates upstream issue #1850, fixed by merged PR #1856: https://github.com/slatedb/slatedb/pull/1856. The reported mechanism is the same coordinator reclaim of a stale `Running` compaction while the prior worker still has local execution state. The target commit already contains the worker-side guards that stop local execution on ownership loss and prevent duplicate dispatch.

## Trigger scenario
A worker claims a compaction, misses heartbeats, the coordinator reclaims it to `Scheduled(worker=None)`, and the still-running worker later polls, heartbeats, or finishes. The known bad pre-fix behavior was duplicate local execution/panic; target commit `cc69461d902560bb5f4407a506f32cd154ede79d` includes the fix commit ancestry.

## Developer intent
PR #1856 explicitly fixes #1850 by stopping local execution when ownership is lost and avoiding claiming a scheduled job already running locally. RFC-0025 also records zombie-worker completion as resolved by requiring matching `worker_id` for status updates.

## Reproduction result
Repro/check file written and executed:
`<run-output>/repro/test_bugCR-3_known_fixed.sh`

Command:
```bash
timeout 3m <run-output>/repro/test_bugCR-3_known_fixed.sh
```

Relevant output:
```text
CR-3 known-fixed guard check
commit=cc69461d902560bb5f4407a506f32cd154ede79d
ancestor_da14c593_contains_pr1856_fix=yes
level0: run existing regression for same-worker reclaimed job already active locally
test compaction_worker::tests::test_worker_stops_rescheduled_job_already_active_locally_on_poll ... ok
level0: run existing regression for heartbeat ownership loss
test compaction_worker::tests::test_worker_stops_active_job_when_heartbeat_loses_ownership ... ok
level0: run existing regression for heartbeat ticker lost-job cleanup
test compaction_worker::tests::test_worker_heartbeat_ticker_stops_lost_jobs_and_refreshes_remaining_jobs ... ok
CR-3 known-fixed guard check complete
```

## Recommendation
Do not file CR-3 as a new finding. Treat it as the already-reported and fixed upstream bug #1850/#1856.

---

## Entry 6: Stale cross-object merges can overwrite fresher fenced state

- **Finding ID**: CR-4
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: <run-output>/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/slatedb/slatedb/pull/2002; fix-status: fixed)
- **Location**: slatedb/src/compactor_state_protocols.rs:296

## Description
CR-4 duplicates upstream PR #2002, “fix(compactor): prevent terminal compaction resurrection,” merged on August 4, 2026. That PR reports the same `.compactions` conflict-retry stale reload mechanism at the same compactor state sites.

## Trigger scenario
A coordinator trims local terminal compaction state before its `.compactions` write succeeds. A sequenced-write conflict then reloads an older remote active/submitted record for the same compaction id, resurrecting stale work after the manifest already removed the sources.

## Developer intent
Local history and blame show the intended protocol is to merge fresher remote worker transitions during conflict retries and preserve terminal local state as a tombstone until the `.compactions` write succeeds. PR #2002 explicitly fixed this by retaining terminal transitions locally across retries and trimming only the outgoing persisted value.

## Reproduction result
Not executed. The bug-confirmation skill’s Phase 1 pre-filter applies: this is code-review-sourced and already reported in a merged upstream PR, so it is dropped before Phase 2 and no `repro/test_bugCR-4_*` is written.

## Recommendation
No new report for CR-4. Treat this candidate as a duplicate of upstream PR #2002 and consume that fix where needed.

---

## Entry 7: Custom scheduler L0 ordering can make the merge watermark stale

- **Finding ID**: CR-6
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: <run-output>/confirmation/CR-6/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: slatedb/src/compactor_state.rs:1115

Checklist:
1. Did Level 0 trigger it? yes.
2. Level 2/3 injection used? no.
3. Real consumer/caller: `Db::flush_with_options` at `slatedb/src/db.rs:1789`, via L0 dispatch guard in `slatedb/src/memtable_flusher/tracker.rs:271`.
4. Bad state permanence/masking: permanent until a later compaction happens to recompact the retained L0; no automatic merge-only cleanup masks it.

## Description
A custom `CompactionScheduler` can inherit the default `validate()` at `slatedb/src/compactor.rs:149`, which accepts a permuted L0 source list. `finish_compaction` then treats the first source as the newest compacted L0 watermark, and `merge_writer_and_compactor` trims writer L0 only up to that stale marker. This leaves a compacted L0 visible in the writer manifest and consumes real L0 capacity.

## Trigger scenario
The repro builds a real `Db` with `CompactorBuilder::with_scheduler_supplier`, writes and flushes two L0s, then lets the custom scheduler submit those L0 sources oldest-to-newest. After compaction and writer refresh, one already-compacted physical L0 remains in `Db::manifest().l0()`. With `l0_max_ssts = 2`, one further flush succeeds and the next normal public memtable flush times out.

## Developer intent
Built-in size-tiered validation requires sources to be a consecutive manifest-order slice at `slatedb/src/size_tiered_compaction.rs:283-301`, and `finish_compaction` has a TODO at `slatedb/src/compactor_state.rs:1113-1115` saying the newest L0 must be first. GitHub issue/PR searches covered `last_compacted_l0_sst_view_id`, `"first entry in sources"`, `"custom scheduler" compaction`, `watermark L0 compaction scheduler`, and `"non-consecutive compaction sources"`; related PRs/issues existed, but none reported this exact custom-scheduler stale-watermark mechanism.

## Reproduction result
Repro file executed: `<run-output>/repro/test_bugCR-6_custom_scheduler_l0_order.sh`

Command:
```sh
timeout 15m <run-output>/repro/test_bugCR-6_custom_scheduler_l0_order.sh
```

Output:
```text
CR6 scheduler submitted source view IDs oldest->newest: ["01M1M9F04ZTCZ365EQ1BXFQDQ3", "01M1M9F050NHHYRVNXMZP4RXZ0"]
CR6 after compaction+writer refresh: l0_views=["01M1M9F051BJC421700KG0RDWH"] l0_ssts=["01M1M9F050NHHYRVNXMZP4RXZ0"] watermark_view=Some("01M1M9F04ZTCZ365EQ1BXFQDQ3") watermark_sst=Some("01M1M9F04ZTCZ365EQ1BXFQDQ3") compacted_runs=1
CR6 L0 after one further public memtable flush: ["01M1M9F06ERXHZVZFTE2NE1JKT", "01M1M9F051BJC421700KG0RDWH"]
CR6 second post-compaction public flush result: Err(Elapsed(()))
BUG TRIGGERED: public Db::flush_with_options(FlushType::MemTable) timed out because the stale compacted L0 still counts against l0_max_ssts
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.07s
```

## Recommendation
Move the L0 source-order invariant into compactor-level validation for all tiered L0 compactions, or make the trait default validation reject out-of-order/non-consecutive L0 sources. Do not rely on each custom scheduler to duplicate the size-tiered ordering precondition.

---
