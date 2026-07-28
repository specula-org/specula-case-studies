# Confirmed Bugs — slatedb-dist-compaction

Reproduced: 1 = 1 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Findings: 1 = 0 env-limited + 1 masked
Dispositions: 5 total = 1 reproduced + 0 env-limited + 1 masked + 2 false-positive + 0 needs-more-info + 1 dropped + 0 pending-repair + 0 incomplete + 0 deferred

| Bug | Finding | Status |
|---|---|---|
| 1 | MC-2 | REPRODUCED |
| 2 | CR-1 | MASKED |
| 3 | CR-2 | FALSE POSITIVE |
| 4 | CR-3 | FALSE POSITIVE |
| 5 | CR-4 | DROPPED |

## Bug 1: Submitted backlog can exceed the configured running-compaction bound

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: [compactor.rs](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/MC-2/worktree/slatedb/src/compactor.rs:1308)

1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 1 only: real DB/admin/standalone-compactor/standalone-worker APIs, with timing assistance from a test-only compacted-SST gate and short poll intervals.
2. If no, provide the reachable Level 2/3 precondition. **N/A; Level 1 was sufficient.**
3. Which real consumer/caller observes a wrong outcome? **The compactor task itself** at [compactor.rs](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/MC-2/worktree/slatedb/src/compactor.rs:1240): on the next poll it panics with unsigned-underflow after two workers are already holding one job each. Operators can also observe the bad state through [admin.rs](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/MC-2/worktree/slatedb/src/admin.rs:121).
4. Is the bad state permanent, or later resolved/masked? **Not permanent, but not masked.** The over-limit state is live harm as soon as two workers concurrently hold jobs while `max_concurrent_compactions = 1`, and in this run it immediately escalates into a compactor panic at [compactor.rs:1240](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/MC-2/worktree/slatedb/src/compactor.rs:1240). No downstream safeguard prevents that.

## Description
External/manual compactions bypass the coordinator’s global capacity gate. [Admin::submit_compaction](...) writes `Submitted` jobs directly, [maybe_validate_submitted_compactions](...) promotes every valid `Submitted` job to `Scheduled` without checking `max_concurrent_compactions`, and each worker then enforces only its own local limit.

With two standalone workers and `CompactorOptions.max_concurrent_compactions = 1`, I reproduced two distinct external jobs becoming `Running` at the same time. On the next coordinator poll, [compactor.rs:1240](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/MC-2/worktree/slatedb/src/compactor.rs:1240) underflowed (`1 - 2`) and panicked.

## Trigger scenario
Create a segmented DB with one valid L0-only external compaction in segment `aaa` and one in segment `bbb`. Run a standalone coordinator with `worker: None` and `max_concurrent_compactions = 1`, submit both compactions through `Admin::submit_compaction()`, then start two standalone workers each with `max_concurrent_compactions = 1`.

Reproduction entrypoint: [test_bugMC-2_external_submissions_bound.sh](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/repro/test_bugMC-2_external_submissions_bound.sh). Escalation level: **Level 1**.

## Developer intent
The code and docs treat the coordinator limit as global and the worker limit as per-worker: [config.rs:1110](...) says “maximum number of concurrent compactions to execute at once”, while [config.rs:1190](...) says a worker limit is “How many jobs a single worker may hold simultaneously.” The RFC for compaction-state persistence also says externally submitted work should flow through normal capacity enforcement; the current `Submitted -> Scheduled` path no longer does.

I searched upstream issues/PR history and recent fixes before marking novelty. Issue `#288` is about manual-compaction coordination generally, and merged PR `#1926` on July 14, 2026 fixed a different `Compacted`-accounting bug, not this external-submission overrun.

## Reproduction result
Executed [test_bugMC-2_external_submissions_bound.sh](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/repro/test_bugMC-2_external_submissions_bound.sh).

```text
Finished `test` profile [unoptimized + debuginfo] target(s) in 41.06s
Running unittests src/lib.rs (target/debug/deps/slatedb-957b28268fabb0f0)

running 1 test
prepared database fixture
flushed aaa segment
flushed bbb segment
standalone compactor created .compactions
submitted compactions: [Ulid(242032580579812185880724533), Ulid(242550679522952066050517814)]
scheduled external compactions under global limit=1: [(Ulid(242032580579812185880724533), Scheduled), (Ulid(242550679522952066050517814), Scheduled)]
observed concurrent Running compactions with max_concurrent_compactions=1: [(Ulid(242032580579812185880724533), "000000009PBXQC55HX962DTQEQ"), (Ulid(242550679522952066050517814), "000000009P2WYBZEPZR3FZM6Y7")]

thread 'tokio-rt-worker' (466322) panicked at slatedb/src/compactor.rs:1240:34:
attempt to subtract with overflow
2026-07-21T17:59:54.025241Z ERROR slatedb::dispatcher: background task panicked unexpectedly. [task_name=compactor, error=BackgroundTaskPanic("compactor"), panic=Some("attempt to subtract with overflow")]
2026-07-21T17:59:54.025578Z ERROR slatedb::dispatcher: background task failed [name=compactor, error=BackgroundTaskPanic("compactor"), panic=None]
test compactor::tests::test_external_submissions_can_exceed_global_max_concurrent_bound ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 1891 filtered out; finished in 0.24s
```

The decisive lines are the two distinct jobs simultaneously reported as `Running` under global limit `1`, followed by the coordinator panic at `slatedb/src/compactor.rs:1240`.

## Recommendation
Enforce the coordinator-wide budget before promoting external `Submitted` jobs to `Scheduled`; that can live in [compactor.rs:1308](...) or in a shared “counts against global capacity” helper reused by both scheduler-generated and externally submitted work. Also harden [compactor.rs:1240](...) against underflow so an already-bad state degrades into a handled error instead of panicking.

---

## Bug 2: External `Submitted` compactions may bypass coordinator admission checks

- **Finding ID**: CR-1
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `slatedb/src/compactor_state.rs:882`

## Description
The broad “same-segment duplicate L0” version of this review finding is no longer live: current `validate_compaction()` rejects a `Submitted` L0 compaction when another `Scheduled`/`Running` L0 compaction already exists in the same segment.

The remaining live gap is narrower but real. An external `Submitted` compaction merged through `merge_remote_compactions()` bypasses `add_compaction()`’s global active-destination collision check, and `maybe_validate_submitted_compactions()` can promote it to `Scheduled` if the conflicting compaction is in a different segment. In the executed repro, two disjoint-segment jobs simultaneously reserved destination SR `200`.

## Trigger scenario
A reachable sequence is:

1. Segment `aaa` already has a locally scheduled L0 compaction reserving fresh destination SR `200`.
2. An external caller submits a `Submitted` L0 compaction for segment `bbb` with the same destination SR `200`.
3. `merge_remote_compactions()` accepts that remote `Submitted` entry without routing it through `add_compaction()`.
4. `maybe_validate_submitted_compactions()` promotes it to `Scheduled`, because its same-segment L0 guard only checks segment `bbb`, not the globally reserved destination.
5. If both jobs later reach `Compacted`, the first commit wins and the second is rejected.

Executed repro entrypoint: [test_bugCR-1_cross_segment_destination_collision.sh](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/repro/test_bugCR-1_cross_segment_destination_collision.sh)  
Underlying test: [compactor.rs](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-1/worktree/slatedb/src/compactor.rs:5350)

## Developer intent
The code and upstream history point to “external `Submitted` should behave like internal scheduling,” not to “external requests may skip active-conflict admission”:

- RFC `0013-compaction-state-persistence.md` says external requests are written as `Submitted` and then handled by the regular compactor flow on the next poll tick.
- RFC `0025-distributed-compaction.md` says the coordinator alone should promote `Submitted -> Scheduled` after validation and after updating local state to know about the job.
- PR `#1197` (merged January 20, 2026) documents the expectation that post-startup unknown compactions should only arrive via `submit_compaction()` as `Submitted`: https://github.com/slatedb/slatedb/pull/1197
- PR `#1650` (merged May 13, 2026) includes review discussion that admin compactions write directly to `.compactions` and therefore must be validated in the coordinator path: https://github.com/slatedb/slatedb/pull/1650
- PR `#1836` (merged June 25, 2026) shows the current downstream safety net: `Compacted` entries are revalidated at commit time: https://github.com/slatedb/slatedb/pull/1836

I also checked the GitHub tracker queries for `submit_compaction` and `validate_compaction Submitted` on July 21, 2026, and did not find an upstream report for this exact cross-segment active-destination collision bypass:
- https://github.com/slatedb/slatedb/issues?q=submit_compaction
- https://github.com/slatedb/slatedb/issues?q=validate_compaction+Submitted

## Reproduction result
The script executed successfully and printed the conflicting admission plus the downstream mask:

```text
scheduled_after_submit=[(Ulid(12089258196146291747061760), b"aaa", Some(200)), (Ulid(2157518929563097021524384605019344500), b"bbb", Some(200))]
2026-07-21T18:17:09.751812Z  INFO slatedb::compactor_state: finished compaction [spec=[seg=b"aaa"] ["l0"] -> SR(200)]
2026-07-21T18:17:09.752133Z  WARN slatedb::compactor: compaction destination overwrites committed SR not in sources: 200
2026-07-21T18:17:09.752177Z  INFO slatedb::compactor: compacted entry failed validation, marking Failed [id=01KY2YAQVPR596TN2RK6PB13KM]
post_commit external_status=Failed internal_present=false manifest_sr_ids=[200]
test compactor::tests::test_external_submitted_cross_segment_destination_collision_is_scheduled_then_masked ... ok
```

This confirms two conflicting jobs were admitted to `Scheduled`, but only one destination SR `200` was durably published. The loser was masked by `commit_compacted_entries()` + `validate_destination_overwrite()` (`slatedb/src/compactor.rs:930`, `:1163`), which converted it to `Failed`.

## Recommendation
Route externally merged `Submitted` compactions through the same active-conflict gate as internal proposals, or re-run the `add_compaction()` invariants during `maybe_validate_submitted_compactions()` for `Submitted` entries. In practice, the missing checks are:

- global active destination reservation conflicts
- same-segment concurrent drain conflicts

Without that, external/manual compactions can still consume scheduling/execution slots for work that the coordinator already knows should not coexist, even though the later commit path currently masks duplicate durable publication.

---

## Bug 3: Crash windows between manifest and `.compactions` writes may break recovery safety

- **Finding ID**: CR-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `slatedb/src/compactor.rs:907`

## Description
The suspected bug is a crash after manifest publication but before the terminal `.compactions` write, leaving recovery or GC in an unsafe mixed state. The reproduced mixed state is reachable, but it stays recovery-safe: restart preserves the manifest-visible output, rewrites the retained compaction entry to `Failed`, and GC still keeps the live output SST.

## Trigger scenario
A real sequence can reach the state: `Db::put`/`Db::flush` create an L0 SST, a worker persists `Compacted` output, the coordinator applies `finish_compaction()`, writes the checkpoint and manifest, then crashes before `write_compactions_safely()`. After restart, `commit_compacted_entries()` re-reads the stale `Compacted` entry, sees the sources missing from the manifest, and persists `Failed` without changing the manifest.

## Developer intent
`slatedb/src/compactor.rs:914-929` explicitly documents this restart case as safe. PR `#1701` merged on May 27, 2026 added this logic and its recovery test, and the May 23, 2026 review thread describes the `Completed` vs `Failed` rewrite as a simplicity/observability tradeoff, not a correctness problem: https://github.com/slatedb/slatedb/pull/1701

The nearest upstream GC report is issue `#1044`, fixed by PR `#1071` on December 19, 2025, but that defect is about pre-manifest outputs being deleted before publication, not this post-manifest recovery state: https://github.com/slatedb/slatedb/issues/1044 https://github.com/slatedb/slatedb/pull/1071

No upstream issue or PR found as of July 21, 2026 reports this exact post-manifest / retained-`Failed` recovery-safety defect.

## Reproduction result
Test: `/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/repro/test_bugCR-2_manifest_compactions_recovery.sh`

Command: `timeout 30m /home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/repro/test_bugCR-2_manifest_compactions_recovery.sh`

1. Level 0 or Level 1 alone triggered it: no.
2. Level 2 injected state reachability: `Db::put` -> `Db::flush` -> worker persists `Compacted` -> coordinator `finish_compaction()` -> `write_manifest_safely()` -> crash before `write_compactions_safely()` -> restart `commit_compacted_entries()`.
3. Real consumer/caller observing a wrong outcome: none. The restart caller at `slatedb/src/compactor.rs:930` and GC caller at `slatedb/src/garbage_collector/compacted_gc.rs:200` both behaved correctly.
4. Permanent bad state or masked later: no permanent bad state. Restart intentionally rewrites the retained compaction entry to `Failed` while leaving the already-correct manifest and live output SST intact.

```text
== Level 0 - normal coordinator and worker commit path ==
test compactor::tests::test_should_persist_compactions_on_start_and_finish ... ok

== Level 1 - timing/interleaving around manifest writes ==
test compactor::tests::test_should_write_manifest_safely ... ok

== Level 2 - injected crash window after manifest before .compactions ==
test compactor::tests::test_recovery_after_manifest_commit_preserves_output_and_gc_safety ...
2026-07-21T18:28:29.483424Z  INFO slatedb::compactor: compacted entry failed validation, marking Failed [id=0000000KH00000000000000000]
2026-07-21T18:28:29.486532Z DEBUG ...compacted_gc: calculated compacted SST GC cutoff [cutoff_dt=1970-01-01T00:00:20Z, configured_min_age_dt=1970-01-01T00:00:50Z, compaction_low_watermark_dt=1970-01-01T00:00:20Z, most_recent_sst_dt=2026-07-21T18:28:29.474Z]
ok

RESULT: the crash-window state stayed recovery-safe; restart retained the manifest output, marked the retained compaction Failed, and GC kept the live SST.
```

## Recommendation
No recovery-safety fix is warranted for this mechanism. Keep the added regression test, and if the `Completed` vs `Failed` distinction matters operationally, clarify that status in docs or metrics because the recovery behavior is safe but intentionally lossy for observability.

---

## Bug 4: Reclaim and heartbeat races may let stale executions act after ownership moves

- **Finding ID**: CR-3
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `slatedb/src/compaction_worker.rs:827`

## Description

`CR-3` claims that, after reclaim, an old execution can still finish under the same `worker_id`, hit [`handle_finished()`](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-3/worktree/slatedb/src/compaction_worker.rs:827), clear the new attempt from `job_progress`, and let the worker over-claim capacity.

The key missing fact is the real producer of `CompactionJobFinished`: [`TokioCompactionExecutorInner::start_compaction_job()`](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-3/worktree/slatedb/src/compactor_executor.rs:899) only sends completion if the task removes itself from `tasks`, while [`stop_compaction_job()`](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-3/worktree/slatedb/src/compactor_executor.rs:942) removes the task before aborting it. A stopped old attempt therefore does not emit the stale finish the finding needs.

## Trigger scenario

I tested the exact reclaim path with a real worker/executor harness added at [`slatedb/src/compaction_worker.rs:1255`](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-3/worktree/slatedb/src/compaction_worker.rs:1255):

1. Start attempt `A1`.
2. Block `A1` in the real executor during output flush.
3. Reclaim `A` back to `Scheduled`.
4. Let `poll_and_claim()` stop `A1`.
5. Re-claim `A` as `A2`.
6. Try to claim unrelated compaction `B` with `max_concurrent_compactions = 1`.

Expected bug: stale finish from `A1` frees capacity, so `B` gets claimed.  
Observed: no stale finish is emitted, `A2` stays tracked, and `B` remains `Scheduled`.

## Developer intent

The prior public report was issue `#1850` (opened June 26, 2026), fixed by PR `#1856` (merged June 28, 2026): <https://github.com/slatedb/slatedb/issues/1850>, <https://github.com/slatedb/slatedb/pull/1856>. That bug was duplicate local dispatch on reclaim, not stale post-stop completion.

PR `#1884` (merged July 7, 2026) changed progress publication, but not the executor’s post-stop completion suppression: <https://github.com/slatedb/slatedb/pull/1884>.

The code and existing test both show intended suppression of post-stop completion: [`compactor_executor.rs:903-920`](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-3/worktree/slatedb/src/compactor_executor.rs:903) and `should_stop_single_compaction_job_without_stopping_executor`.

## Reproduction result

Reproduction script: [test_bugCR-3_reclaim_stop_no_stale_finish.sh](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/repro/test_bugCR-3_reclaim_stop_no_stale_finish.sh:1)

Level summary:
- Level 0: no standalone public admin/CLI path in this tree to force this coordinator/worker reclaim race without a harness.
- Level 1: executed real worker/executor reclaim-stop-reclaim harness and the existing executor cancellation test.
- Level 2: not executed; it would require injecting `WorkerMessage::CompactionJobFinished` after `stop_compaction_job()`, but the only real producer suppresses that message once the task is removed.
- Level 3: not executed; forcing a post-stop completion would alter core logic.

Real output:
```text
LEVEL 1: real worker/executor reclaim -> stop -> same-worker re-claim harness
warning: method `refresh` is never used
   --> slatedb/src/compactor_state_protocols.rs:235:25
    |
117 | impl CompactorStateWriter {
    | ------------------------- method in this implementation
...
235 |     pub(crate) async fn refresh(&mut self) -> Result<(), SlateDBError> {
    |                         ^^^^^^^
    |
    = note: `#[warn(dead_code)]` (part of `#[warn(unused)]`) on by default

running 1 test
.
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 1984 filtered out; finished in 0.09s

LEVEL 1: executor cancellation suppresses stale completion after stop
warning: method `refresh` is never used
   --> slatedb/src/compactor_state_protocols.rs:235:25
    |
117 | impl CompactorStateWriter {
    | ------------------------- method in this implementation
...
235 |     pub(crate) async fn refresh(&mut self) -> Result<(), SlateDBError> {
    |                         ^^^^^^^
    |
    = note: `#[warn(dead_code)]` (part of `#[warn(unused)]`) on by default

running 1 test
.
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 1984 filtered out; finished in 0.05s

LEVEL 0: no standalone public admin/CLI path in this tree to force this coordinator/worker reclaim race without a harness
LEVEL 2: not executed; would require injecting WorkerMessage::CompactionJobFinished after stop_compaction_job(), but the only real producer suppresses it once the task is removed
LEVEL 3: not executed; forcing a post-stop completion would alter core logic and violate the confirmation rules
FINAL: the real Level 1 runs passed, and no stale finish freed capacity for another claim
```

## Recommendation

No product fix is warranted for this finding as stated. Keep the new regression test and the existing executor cancellation test, because a future refactor that changes [`stop_compaction_job()`](/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-3/worktree/slatedb/src/compactor_executor.rs:942) or completion emission could make this currently-unreachable path real.

---

## Bug 5: Independent refresh and merge of manifest and `.compactions` may admit stale state

- **Finding ID**: CR-4
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/slatedb/slatedb/pull/1840; fix-status: fixed)
- **Location**: slatedb/src/compactor_state.rs:882

## Description
CR-4 matches an upstream bug that SlateDB already reported and fixed on June 25, 2026 in PR `#1840`. The mechanism is the coordinator retry path after a `.compactions` sequenced-write conflict: local state may already have committed or pruned a compaction while persisted `.compactions` still holds an older `Compacted`/`Completed`/`Failed` entry, so `merge_remote_compactions()` sees a vacant remote terminal entry and has to merge it back for later cleanup.

## Trigger scenario
The normal coordinator path reaches this without special hooks: `handle_ticker()` calls `load_compactions()` and `load_manifest()` in sequence, then later `write_compactions_safely()` retries on `.compactions` conflicts. On retry, it reloads remote `.compactions` and re-enters `merge_remote_compactions()`. PR `#1840` describes the same sequence CR-4 raises: local completion/pruning first, conflicted `.compactions` write second, then re-merge of an older persisted `Compacted` or terminal entry.

## Developer intent
The current code and upstream history show this path is known and intentionally repaired, not a new unresolved finding. `slatedb/src/compactor_state.rs:892-903` now documents the stale retry case and says stale `Compacted` entries are resolved by `validate_compaction()` while stale terminal entries are resolved by `retain_active_and_last_finished()`. `slatedb/src/compactor.rs:914-929` also documents the crash-after-manifest-write recovery behavior. The supporting validation change landed one day earlier in PR `#1836`, and PR `#1840` is the exact tracker item for this merge path.

## Reproduction result
Per the bug-confirmation workflow, this stops at the Phase-1 code-review × known pre-filter, so I did not write a new `repro/test_bugCR-4_*` artifact.

Real output from the prior-report search:
```text
$ git log --oneline --decorate -- slatedb/src/compactor_state.rs slatedb/src/compactor_state_protocols.rs slatedb/src/compactor.rs slatedb/src/manifest/store.rs | head -n 10
8e8b36ce fix: merge_remote_compactions should accept stale terminal/compacted entries (#1840)
705806b2 Validate compacted compactions against local segment sr IDs (#1836)
```

The matched upstream report is GitHub PR `#1840`, merged on June 25, 2026: `https://github.com/slatedb/slatedb/pull/1840`.

## Recommendation
Drop CR-4 as a duplicate of upstream PR `#1840`. If you need to evaluate an older revision from before June 25, 2026, use PR `#1840` plus its supporting validation fix in PR `#1836` as the relevant fix set.

---
