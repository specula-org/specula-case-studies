# Bug Report — Asterinas private futex requeue, wake and timeout

## Summary

- Scenarios tested: 4 (registration, quotas and counts, moved-waiter completion, retained bookkeeping), through 15 hunting configurations and the `MC.cfg` core check.
- Bugs found: 4. MC-1 is an ownership defect with a Linux-visible consequence. MC-2, MC-3 and MC-4 are Linux compatibility defects in ordinary `FUTEX_REQUEUE`.
- Configs run: `MC_hunt_completion`, `MC_hunt_s1_mismatch`, `MC_hunt_s1_registration`, `MC_hunt_s2_quotas`, `MC_hunt_s2_return_count`, `MC_hunt_s2_same_address`, `MC_hunt_s2_unrelated_first`, `MC_hunt_s2_wake_zero_control`, `MC_hunt_s2_zero_move_cross_bucket`, `MC_hunt_s2_zero_move_same_bucket`, `MC_hunt_s2_zero_wake`, `MC_hunt_s3_opposite`, `MC_hunt_s3_owner`, `MC_hunt_s3_same_bucket`, `MC_hunt_s4_live_migration`, plus three residual configurations described under Not Reproduced.

The model is the converged round-2 suite at Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76`. All 18 implementation traces replay on it without change (`spec/output/round2-trace-results.json`). Every TLC run used at most 4 GiB and 2 workers. Logs, JSON counterexamples and the run index are under `spec/output/hunt-round2/` and `spec/output/tlc-runs-round2.json`.

Source paths below are relative to the source checkout and refer to the unmodified commit, not the instrumented working tree. `futex.rs` is `kernel/core/src/process/posix_thread/futex.rs`. `syscall/futex.rs` is `kernel/core/src/syscall/futex.rs`. `wait.rs` is `ostd/src/sync/wait.rs`. Linux references are to the pinned v6.16.5 `kernel/futex/` sources.

## Bug 1: A timed-out waiter moved to another bucket leaves its entry behind

- **ID**: MC-1
- **Scenario**: 3 (moved waiter completes through its original bucket) and 4 (retained entry changes a later migration). Contract cases F07 and F09.
- **Severity**: High
- **Invariant violated**: `ResourceAccountingBalance`, and its Linux-visible consequence `LiveMigrationExhaustion`
- **Config**: `MC_hunt_s3_owner.cfg` and `MC_hunt_s4_live_migration.cfg`
- **Counterexample**: 56 states, `spec/output/hunt-round2/MC_hunt_s3_owner-bfs.out` (JSON beside it). 93 states, `spec/output/hunt-round2/MC_hunt_s4_live_migration-bfs.out`.

### Trace Summary

`MC_hunt_s3_owner` (key A is bucket 1, key B is bucket 2):

1. States 1-8: waiter 1, with no timeout, compares the unchanged word under bucket 1's lock and enqueues on A.
2. States 8-17: waiter 2, with a one-tick timeout, enqueues on A behind waiter 1, reads the clock at 0 and arms a timer for deadline 1.
3. States 17-24: the clock reaches 1. A timer collection pops waiter 2's timer and its callback takes the timer lock.
4. State 25: a controller issues REQUEUE(A to B, wake 1, move 1).
5. States 26-33: the callback's wake is accepted. Waiter 2 consumes it, locks its timer, finds no time remaining (ETIME) and unlocks the timer. It has not yet started cleanup.
6. States 34-46: the REQUEUE locks bucket 1 and then bucket 2. It wakes and removes waiter 1. It then extracts waiter 2's entry, which is still queued, rekeys it to B and appends it to bucket 2.
7. States 47-49: the REQUEUE releases bucket 2 and then bucket 1.
8. States 50-55: waiter 2 locks bucket 1, the bucket it saved at registration. `remove_by_waker` misses, the wait returns 0 instead of ETIMEDOUT, and dropping the waiter closes its waker.
9. State 56: the REQUEUE returns 1. All locks are free and no timer or callback is pending. Waiter 2 has returned, but its entry is still registered in bucket 2 and was never removed.

`MC_hunt_s4_live_migration` continues the same history:

1. States 1-64: the prefix above strands waiter 2's closed entry on B in bucket 2. Both original waits return 0, and the first REQUEUE returns at state 64.
2. States 64-76: fresh waiters 3 and 4 enqueue on B behind the closed entry.
3. State 77: a controller issues REQUEUE(B to A, wake 1, move 1).
4. States 78-86: the wake scan tries the closed entry first. Its `wake_up` returns false, so the entry stays and the wake quota is not spent. The scan then wakes and removes waiter 3.
5. States 87-92: the migration scan extracts the closed entry, which matches B, and moves it to A. When it reaches live waiter 4, the migration quota is already spent, so waiter 4 stays on B.
6. State 93: the requeue finishes with live waiter 4 neither woken nor moved, although its only migration slot went to an entry whose wait had already returned.

### Root Cause

`futex_wait_bitset` computes the bucket reference once from the original key (`futex.rs:79`) and never updates it. A cross-bucket REQUEUE moves the `FutexItem`, which owns the waiter's `Arc<Waker>`, into the destination bucket (`futex.rs:513-534`) without informing the waiter. After `pause_timeout` returns, cleanup searches only the saved bucket (`futex.rs:124`). A moved entry that was not woken in its new bucket is therefore not found.

The code treats a miss as proof that a waker already removed the entry. The comment at `futex.rs:126-127` states that the item "will be removed asynchronously if and only if it has been woken up", and the function returns `Ok(())` at `futex.rs:130`. That assumption does not hold after a cross-bucket move. Dropping the `Waiter` then closes the waker (`wait.rs:244-250`). The stranded entry stays in the global bucket (`futex.rs:384`) for good. WAKE keeps entries whose `wake_up` returns false (`futex.rs:488-495`, `wait.rs:262-265`). Both migration paths count it like a live waiter (`futex.rs:500-511`, `futex.rs:520-529`). `remove_by_waker` is the only per-waiter removal path, and it is called only from this cleanup. The comment at `futex.rs:121-123` states the obligation that is missed here: a timed-out or interrupted wait "must be dequeued and dropped", or user programs can exhaust kernel memory by repeating futex waits.

Linux tracks the current bucket instead. `requeue_futex` updates `q->lock_ptr` when it moves a waiter (`requeue.c:89`). `futex_unqueue` locks that pointer, rechecks it and retries if it changed (`core.c:921-964`). A timed-out waiter therefore removes itself from wherever it is queued and returns -ETIMEDOUT unless a waker already unqueued it (`waitwake.c:690-694`). A completed waiter never remains queued, so it cannot take a later requeue's migration slot.

Implementation traces collected on SMP=2 reach the same stranded state through serialized histories:

- Attempt 11 (`traces/case-11.ndjson`): REQUEUE(1,1) moved timed generation 3001 from bucket 6 to bucket 303. After its 20 ms timeout, cleanup searched bucket 6, missed, and the wait returned 0. A later WAKE(B, 1) accepted no waiter because the closed entry rejects wakes.
- Attempt 10, the same history within one bucket, found the entry and returned ETIMEDOUT.
- Attempt 13 (`traces/case-13.ndjson`) reproduces the F09 consequence. REQUEUE(B to A, 1, 1) woke 4001, moved closed generation 3001 and left live 5001 on B. WAKE(A, 2) then returned 0, and WAKE(B, 2) returned 1.

Attempt 11 moves the entry before the timeout fires, while the model counterexample moves it after the waiter observes expiry and before cleanup. Both orders end in the same stranded state. The close race itself was not captured at runtime.

The consequences are as follows:

- Each occurrence permanently keeps a `FutexItem`, its `Arc<Waker>` and the waker's `Arc<Task>` (`wait.rs:174-177`). An unprivileged process can repeat the pattern without bound. Once the waiting thread exits, the retained `Task` also keeps its kernel stack, which `Task` owns (`ostd/src/task/mod.rs:65`) and which is 128 pages by default (`ostd/src/task/kernel_stack.rs:38`). This growth follows from the code and was not measured.
- A later REQUEUE from the destination key with a finite migration quota can spend that quota on closed entries and leave live waiters on the old key. Linux cannot produce this result, because a waiter that has returned is no longer queued.
- The timed-out wait returns 0 instead of ETIMEDOUT. FUTEX_WAIT callers must already tolerate spurious success, so this alone is not counted as an ABI violation. The residual check below confirms that the model never reports ETIMEDOUT before the deadline.

### Affected Code

- `futex.rs:79`: the cleanup bucket is fixed from the original key.
- `futex.rs:121-130`: cleanup searches only that bucket and reports a miss as success.
- `futex.rs:513-534`: cross-bucket requeue moves the entry without updating any waiter-visible location.
- `futex.rs:485-498` and `futex.rs:500-534`: wake retains closed entries, and both migration paths count them.
- `wait.rs:244-250` and `wait.rs:262-265`: the dropped waiter closes its waker, so later wakes are rejected but the entry stays.

### Recommendation

Make cleanup find the entry's current bucket, as Linux does with `lock_ptr`. One option stores the current bucket index in state shared by the `FutexItem` and the waiter, updates it while holding both bucket locks during cross-bucket requeue, and has cleanup lock, recheck and retry until the index is stable. When cleanup finds the entry after a timeout, it should return ETIMEDOUT, as the same-bucket path already does. Making migration skip closed entries would remove the live-migration symptom but would not reclaim the stranded entries.

---

## Bug 2: Ordinary REQUEUE with a zero wake quota wakes a waiter

- **ID**: MC-2
- **Scenario**: 2 (quota conversion), contract case F05 (TV-1)
- **Severity**: Medium
- **Invariant violated**: `RequeueWakeQuota`
- **Config**: `MC_hunt_s2_zero_wake.cfg`. `MC_hunt_s2_quotas.cfg` fails the same clause of `RequeueQuotaAndResult` on the same-bucket path (19 states, `spec/output/hunt-round2/MC_hunt_s2_quotas-bfs.out`).
- **Counterexample**: 20 states, `spec/output/hunt-round2/MC_hunt_s2_zero_wake-bfs.out`

### Trace Summary

1. States 1-13: two waiters compare the unchanged word and enqueue on A in bucket 1.
2. State 14: a controller issues REQUEUE(A to B, wake 0, move 0). Dispatch records a raw wake quota of 0 and an effective quota of 1.
3. States 15-17: the call locks bucket 1 and then bucket 2.
4. States 18-20: the wake scan accepts the first queued waiter and removes it. One waiter is woken although the caller asked for none.

### Root Cause

`sys_futex` passes REQUEUE's `futex_val` through `futex_val_to_max_count` (`syscall/futex.rs:106`), which raises 0 and negative values to 1 (`syscall/futex.rs:146-151`). The helper's comment cites Linux's FUTEX_WAKE behavior. In Linux only `futex_wake` wakes at least one waiter, because it tests the count after waking (`waitwake.c:192`). Ordinary REQUEUE passes `nr_wake` unchanged (`syscalls.c:108-109`), tests the remaining quota before each waiter (`requeue.c:585`) and wakes only while `++task_count <= nr_wake` (`requeue.c:607`). REQUEUE(0,0) therefore wakes and moves nothing in Linux, and REQUEUE(0,1) moves one waiter without waking any.

Attempt 16 (`traces/case-16.ndjson`) ran REQUEUE(0,0) on two waiters. It woke 2001 and returned 1. Attempt 8 ran REQUEUE(0,1), which woke one waiter and moved the other. The Linux 7.2.8 control returned 0 for REQUEUE(0,0) and left both waiters on the source key. For REQUEUE(0,1) it returned 1, moved one waiter and left the other on the source key (`harness/coverage.md`). The running Linux kernel is 7.2.8, which is separate from the v6.16.5 source reference.

### Affected Code

- `syscall/futex.rs:105-106`: REQUEUE uses the WAKE count conversion.
- `syscall/futex.rs:146-151`: the conversion raises zero to one.
- `futex.rs:368`: the converted quota drives `remove_and_wake_items`.

### Recommendation

Give FUTEX_REQUEUE its own conversion that keeps a zero wake quota, and keep the legacy at-least-one behavior for FUTEX_WAKE only. Negative counts are outside this campaign. Linux rejects them for REQUEUE with EINVAL (`requeue.c:387`), while Asterinas converts them.

---

## Bug 3: A same-bucket REQUEUE with a zero migration quota moves one waiter

- **ID**: MC-3
- **Scenario**: 2 (unequal loop boundaries), contract case F04 (TV-2)
- **Severity**: Medium
- **Invariant violated**: `RequeueMoveQuota`
- **Config**: `MC_hunt_s2_zero_move_same_bucket.cfg`
- **Counterexample**: 22 states, `spec/output/hunt-round2/MC_hunt_s2_zero_move_same_bucket-bfs.out`

### Trace Summary

1. States 1-13: two waiters enqueue on A. Key C maps to the same bucket as A.
2. State 14: a controller issues REQUEUE(A to C, wake 1, move 0).
3. States 15-19: the call locks the shared bucket once, then wakes and removes the first waiter.
4. States 20-22: the wake scan ends. The same-bucket migration loop visits the remaining waiter, which matches A, and rekeys it to C before it compares its count with the zero quota.

### Root Cause

`update_item_keys` rekeys a matching entry and increments its count before testing `count >= max_count` (`futex.rs:500-511`). With a quota of 0, the first remaining entry is moved whenever it matches. The cross-bucket path tests `count < max_nrequeues` before extracting (`futex.rs:522-523`), so the two paths disagree. Linux tests `task_count - nr_wake >= nr_requeue` before handling each waiter (`requeue.c:585`) and moves nothing when the migration quota is 0. A waiter that the caller meant to leave on A is now on C. A later WAKE on A misses it, and it stays blocked unless C is woken.

Attempt 5 (`traces/case-05.ndjson`, A and B both in bucket 6) ran REQUEUE(1,0). It woke 2001 and rekeyed 3001 to B. A later WAKE(B) woke 3001 and WAKE(A) returned 0. Attempt 6, with different buckets, and attempt 7, with an unrelated first entry, moved nothing, as the source predicts. The Linux 7.2.8 control returned 1 for REQUEUE(1,0). It then woke no waiter on the destination key and one on the source key. The defect needs two distinct keys that hash to the same bucket.

### Affected Code

- `futex.rs:500-511`: the quota is tested after the entry is changed.
- `futex.rs:378`: same-bucket requeue calls this helper with the raw migration quota.

### Recommendation

Test the quota before changing an entry, for example by breaking at the top of the loop when `count >= max_count`, which matches the cross-bucket path.

---

## Bug 4: REQUEUE returns only the number of woken waiters

- **ID**: MC-4
- **Scenario**: 2 (return count), contract cases F03 and F06 (TV-3)
- **Severity**: Medium
- **Invariant violated**: `RequeueReturnCount`
- **Config**: `MC_hunt_s2_return_count.cfg` (distinct buckets). `MC_hunt_s2_same_address.cfg` fails the same invariant for identical addresses (24 states, `spec/output/hunt-round2/MC_hunt_s2_same_address-bfs.out`).
- **Counterexample**: 30 states, `spec/output/hunt-round2/MC_hunt_s2_return_count-bfs.out`

### Trace Summary

1. States 1-13: two waiters enqueue on A in bucket 1.
2. States 14-21: REQUEUE(A to B, wake 1, move 1) locks buckets 1 and 2, then wakes and removes one waiter.
3. States 22-26: it extracts the other waiter and appends it to bucket 2 with key B.
4. States 27-30: it releases both buckets and returns 1. Linux returns 2, one woken plus one requeued.

In the same-address counterexample, REQUEUE(A to A, 1, 1) takes the WAKE shortcut, wakes one waiter and returns 1. Linux's ordinary requeue also processes the second matching waiter as a requeue onto the same key and returns 2.

### Root Cause

`futex_requeue` returns `Ok(nwakes)` (`futex.rs:381`). Neither requeue helper reports how many entries it processed (`futex.rs:500-534`). Identical addresses take `futex_wake` directly (`futex.rs:353-355`). Linux increments `task_count` for every woken or requeued waiter (`requeue.c:607-610`) and returns it (`requeue.c:691`), including when both addresses are equal.

Attempts 3 and 4 (REQUEUE(1,1) within one bucket and across buckets) and attempt 9 (identical addresses) each returned 1. The Linux 7.2.8 control returned 2 for both distinct and identical addresses. The preparation contracts record that the FUTEX_REQUEUE manual page (man-pages 6.19, inspected 2026-10-04) describes only woken waiters, which conflicts with both the pinned source and the running kernel. This report follows the implementation, as the campaign contract directs.

### Affected Code

- `futex.rs:353-355`: the same-address shortcut returns the WAKE count.
- `futex.rs:381`: only accepted wakes are returned.
- `futex.rs:500-534`: the requeue helpers do not report their counts.

### Recommendation

Have both requeue helpers return the number of entries they processed, and return wakes plus requeues. For identical addresses, add the number of remaining matching waiters up to the migration quota, without moving them.

---

## Not Reproduced

| Scenario | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 1, F01 mismatching WAIT | `MC_hunt_s1_mismatch.cfg` | BFS complete: 31 distinct, diameter 19. Simulation 30 min: 9,759,957 states in 611,008 traces, mean length 17. | No violation. EAGAIN leaves no registration. |
| 1, F00 store and WAKE against registration, with one recoverable fault | `MC_hunt_s1_registration.cfg` | BFS complete: 289 distinct, diameter 31 | No violation. `NoMissedOrderedWake` holds with the unlock, fault, relock and reload path. |
| 2, F04 unrelated first entry with migration quota 0 | `MC_hunt_s2_unrelated_first.cfg` | BFS complete: 1,390 distinct, diameter 47 | No violation. The loop stops at the unrelated entry. |
| 2, WAKE(0) control | `MC_hunt_s2_wake_zero_control.cfg` | BFS complete: 620 distinct, diameter 36 | No violation. WAKE(0) wakes exactly one, as Linux's `futex_wake` does. |
| 2, F04 cross-bucket migration quota 0 | `MC_hunt_s2_zero_move_cross_bucket.cfg` | BFS complete: 772 distinct, diameter 40 | No violation. Extraction checks the quota first. |
| 2, residual core checks over all quotas 0-2 in one bucket | `MC_residual_s2_quotas.cfg` | BFS complete: 5,544 distinct, diameter 45 | No violation of failure atomicity, exactly-once completion, identity stability or the WAKE quota. |
| 3, F07 move within one bucket, then timeout | `MC_hunt_s3_same_bucket.cfg` | BFS complete: 57,330 distinct, diameter 69 | No violation. Cleanup finds the moved entry, and `ResourceAccountingBalance` holds. |
| 3, residual of the cross-bucket ownership scenario | `MC_residual_s3_owner.cfg` | BFS complete: 89,784 distinct, diameter 74 | No violation of `PermittedWaitResult` or the core checks. Only `ResourceAccountingBalance` fails in this scenario. |
| 4, residual of the live-migration scenario | `MC_residual_s4_live_migration.cfg` | BFS complete: 52,494 distinct, diameter 133 | No violation of `PermittedWaitResult` or the core checks. Only `LiveMigrationExhaustion` fails. |
| 3, F10 opposite-direction REQUEUEs | `MC_hunt_s3_opposite.cfg` | BFS 30 min: 9,396,757 distinct, depth 84, 1,554,234 queued | No violation within the budget. Not exhaustive. |
| Conditional completion and progress | `MC_hunt_completion.cfg` | BFS 30 min: 3,148,864 distinct, depth 5. Simulation 30 min: 6,442,556 states in 56,632 traces, mean length 60. | No safety or liveness violation within the budget. Not exhaustive. |
| Core safety, free workload | `MC.cfg` | BFS 30 min: 32,032,634 distinct, depth 6. Simulation 30 min: 29,203,838 states in 117,692 traces, mean length 87. | No violation within the budget. Not exhaustive. |
| 3, F08 wake/expiry race with both winners | Covered by the ownership and completion configurations | Model only | Not testable at runtime. The 18 captures did not record a close race with both winners. |

The residual configurations are copies of their hunting configurations with only the already-classified oracle removed. They test whether other properties fail in the same bounded scenario.

## Limits of this evidence

- The Category B concurrency quality requirement is not met. The largest measured cross-thread event overlap in the 18 captures is 0.382 percent, against the 20 percent requirement. Replay success and the runtime observations above come from mostly serialized schedules.
- The recoverable-fault actions and `WaiterSpuriousReturn` appear in the model but were never exercised at runtime.
- The `MC.cfg`, `MC_hunt_completion` and `MC_hunt_s3_opposite` searches stopped at their 30-minute budgets. Free-mode admission limits BFS to depth 5 or 6, so simulation supplies their deeper coverage.
- The Linux comparison uses the v6.16.5 source and a 7.2.8 runtime control. No Linux bucket identity or internal movement trace was recorded.
- No bug was confirmed by a dedicated reproduction in this phase. The runtime observations come from the Phase 2.5 harness captures.

No spec or invariant changed during bug hunting.
