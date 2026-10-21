# MC-1 Investigation (Phase 1 — evidence only)

Finding: "A timed-out waiter moved to another bucket leaves its entry behind"
Source: model-checking (real counterexamples: MC_hunt_s3_owner-bfs.out, MC_hunt_s4_live_migration-bfs.out).

## Step 1: Code audit

All line numbers below are for the pristine upstream file at the pinned commit
`0c60537098f4c2949ad2d382aaf499de72263d76` (the worktree adds observation-only
probe instrumentation on top; `git show HEAD:kernel/core/src/process/posix_thread/futex.rs`
was used to verify the cited lines).

### Cited code, verified

- `kernel/core/src/process/posix_thread/futex.rs:79` — `let (_, futex_bucket_ref) = get_futex_bucket(&futex_key);`
  `futex_wait_bitset` saves a reference to the bucket of the **original** key and keeps
  it for the whole call.
- `futex.rs:121-130` — after `waiter.pause_timeout(...)` (line 119) the cleanup is
  `let item = futex_bucket_ref.lock().remove_by_waker(&waiter.waker());`
  i.e. it searches **only the original bucket**. If `item.is_none()` the function
  returns `Ok(())` ("The futex item will be removed asynchronously if and only if it
  has been woken up"), else it propagates `Err(ETIME)`/`Err(EINTR)` from the pause.
- `futex.rs:513-534` — `FutexBucket::requeue_items_to_another_bucket`: `extract_if`
  moves up to `max_nrequeues` items whose key matches the source key out of the source
  bucket, rewrites `item.key = new_key`, and `add_item`s them into the **destination**
  bucket. It does not check whether the waker is closed; a closed (already-completed)
  waiter is moved like a live one and consumes migration quota.
- `futex.rs:485-498` — `remove_and_wake_items` (WAKE): `retain` keeps every item whose
  `wake()` returns false. For a closed waker `wake()` is false, so a dead entry is
  retained forever and never counts toward the wake count.
- `futex.rs:500-511` — `update_item_keys` (same-bucket requeue): rewrites keys of the
  first `max_count` matching items, counting closed entries too.
- `ostd/src/sync/wait.rs:244-250` — `Waker::wake_up()` returns `false` when
  `has_woken` was already true (timer wake or previous wake).
- `ostd/src/sync/wait.rs:262-265` — `Drop for Waiter` calls `waker.close()`, which sets
  `has_woken = true`; afterwards every `wake_up()` on this waker is a no-op returning
  false.

### Call chain / reachability

`futex` syscall → `kernel/core/src/syscall/futex.rs` dispatch → `futex_wait_bitset`
(WAIT) / `futex_requeue` (REQUEUE). All of WAIT, WAKE, REQUEUE with
FUTEX_PRIVATE_FLAG are ordinary public syscall operations in this scope. The trigger
needs two private futex words A and B whose `FutexKey` hashes land in **different**
buckets (`get_bucket_count()` = 256 * num_cpus, power of two; SMP=2 guest → 512
buckets, so distinct addresses overwhelmingly land in different buckets).

### Trigger scenario (constructed; matches CE steps)

1. W1: `FUTEX_WAIT_PRIVATE(A, 0)` untimed. W2: `FUTEX_WAIT_PRIVATE(A, 0, 100ms)`.
   Both register in bucket(A) (queue order W1, W2).
2. `FUTEX_REQUEUE_PRIVATE(A→B, nr_wake=1, nr_requeue=1)` while W2 is still asleep:
   wake phase wakes W1 (quota 1); move phase extracts W2's item from bucket(A),
   rewrites its key to B, appends it to bucket(B). (CE s3: states 25→45; real-kernel
   trace case-11 seq 7-12.)
3. W2's 100 ms timer fires; `pause_timeout` returns `Err(ETIME)`; cleanup locks the
   **original** bucket(A) and `remove_by_waker` misses (the item is in bucket(B)).
   `item.is_none()` → the syscall returns **0 (success) instead of -ETIMEDOUT**.
   (CE s3: states 51-53; real trace case-11 seq 18-21 `cleanup:"miss"`, `result:"OK"`.)
4. `Waiter` drop closes the waker. The item stays in bucket(B) with key B forever:
   WAKE(B) retains it (`wake()` false, count unaffected); a later
   `REQUEUE_PRIVATE(B→A, 0, 1)` moves the **dead** entry (consuming the quota) and
   leaves a live waiter on B behind; `WAKE(A, 1)` then returns 0 and wakes nobody.
   (CE s4 = `LiveMigrationExhaustion`, states 65-93; real trace case-13 seq 32-61.)

The interleaving where the timer fires *before* the requeue is equally defective
(CE s3 uses it): the wake phase skips the already-woken W2 but the move phase still
moves it. Every interleaving of {timer fires} × {requeue wake/move} strands the item;
only "cleanup fully completes before the requeue starts" avoids it, a ~0-width window
when the requeue is issued immediately after enrollment with a 100 ms timeout.

### Safeguards encountered (recorded, not dismissed)

- The cleanup at futex.rs:121-130 is itself the safeguard for the memory-exhaustion
  obligation; it is the code that fails to find the item.
- `remove_and_wake_items` skipping closed entries prevents a dead entry from
  *counting* as a wake, but `retain` keeps it in the queue — no mechanism ever
  removes a closed entry once its owner waiter has returned.
- No other downstream mechanism (no GC of bucket items, no periodic sweep) exists.

## Step 2: Developer knowledge

- Commit `bc5a058fc` (2024-12-16) "Add TODO for a potential vulnerability in futex
  implementation": "The enqueued futex item remain undequeued if the futex wait
  operation is interrupted by a signal or times out ... vulnerable to exploitation by
  user programs that could repeatedly issue futex wait operations to exhaust kernel
  memory." → issue #1587, closed by PR #1642 / commit `888eecb35` (2025-08-26)
  "Patch a futex vulnerability", which added removal **from the saved original
  bucket**.
- Commit `43f50c5e2` (2025-10-06, PR #2515, merged 2025-10-20) "Fix futex return
  values": switched removal to `remove_by_waker` and introduced
  `item.is_none() → Ok(())` with the stated assumption "The futex item will be
  removed asynchronously **if and only if** it has been woken up." Cross-bucket
  REQUEUE breaks that assumption: the item is absent from the original bucket because
  it was *moved*, not because it was woken.
- The comment at futex.rs:117-119 states the cleanup obligation verbatim: "the
  `FutexItem` must be dequeued and dropped. Otherwise, malicious user programs could
  repeatedly issue futex wait operations to exhaust kernel memory."
- Existing tests: `test/linux-org/...` LTP/gVisor suites and the campaign's own
  `specula_futex/scenarios.c` driver. No existing test asserts the requeue+timeout
  interaction's cleanup or return value (case-11/13 drivers record but do not assert).
- Linux reference: a completed waiter dequeues itself following `q->lock_ptr`
  (`kernel/futex/core.c` futex_unqueue), so a completed waiter never stays queued and
  REQUEUE/WAKE quotas are never consumed by dead entries.

## Step 3: Known status / precedent

Tracker + git-history search (GitHub asterinas/asterinas, issues and merged/closed
PRs, 2024-11 → 2026-10):

- Issue #1587 "`futex_wait_bitset()` should remove `futex_item` when `pause_timeout()`
  fails" (closed 2024-11-27): reports the **total absence** of removal on
  timeout/signal. No mention of REQUEUE, cross-bucket movement, or stale-bucket
  cleanup. Fixed by 888eecb35. NOT this mechanism — MC-1 is a residual defect of that
  fix (removal executed against the wrong bucket after a cross-bucket requeue, plus
  the 0-vs-ETIMEDOUT return-value corruption).
- PR #2515 (merged 2025-10-20): return-value fix + shared-mapping FIXME; no requeue
  interaction mentioned.
- No other issue/PR/CVE/advisory (open or closed, incl. recent merges up to 2026-10)
  reports the stale-original-bucket cleanup after cross-bucket REQUEUE, the stranded
  closed entry, or the requeue-quota consumption by dead entries.

Pre-filter: not applicable (MC-sourced with actual counterexamples → proceeds to
Phase 2 regardless). Novelty recorded as NEW, with #1587 as closest prior art.

## Phase 2: Reproduction (result)

Escalation ladder:

- **Level 0 (pure black-box) — SUCCEEDED.** Test
  `repro/test_bugMC-1_requeue_timeout_strand.c` driven by
  `repro/test_bugMC-1_requeue_timeout_strand.sh`: plain FUTEX_WAIT /
  FUTEX_REQUEUE / FUTEX_WAKE_PRIVATE syscalls from pthreads in a real
  Asterinas SMP=2 KVM guest (kernel image reused unchanged from the campaign
  harness, sha256 39ae3549...). The instrumented kernel's reserved probe
  opcode (0x5350) was used only for setup/observation (bucket identity query
  and enrollment counting; the instrumentation spec states it never enqueues,
  wakes, moves or completes a waiter). No failpoints, no state injection, no
  source modification. The same binary ran natively on Linux as the control.
  Timing structure: W2's 300 ms timeout is far in the future when the
  enrollment-gated REQUEUE runs, so the trigger (move-then-timeout) is
  deterministic; three consecutive guest boots all reproduced.

Results (repro/run-output.log, repro/guest-mc1.log):

- Guest (Asterinas, buckets 186/87 and 502/72 on different runs):
  `w2=(0,0)` — timed-out requeued waiter returned SUCCESS instead of
  -ETIMEDOUT; `wake_a=0` and `w4_done_before_wake_b=0` — the dead entry
  consumed REQUEUE(B→A,1,1)'s move quota, WAKE(A,1) woke nobody, live W4
  stayed blocked until WAKE(B,1). `MC1_VERDICT REPRODUCED` (3/3 runs).
- Linux control (same scenario, same binary): `w2=(-1,110)` (ETIMEDOUT),
  `wake_a=1`, W4 woken from A. `MC1_VERDICT NOT_REPRODUCED`.

Kernel-side trace from the reproduction run (decoded from the guest's
SPECULA_RAW dump) matches the counterexample step-for-step: W2 (gen 3001)
`FutexBucketAddItem` bucket=186; timer `TimerCallbackWake`; cleanup
`FutexCleanupLock` bucket=186 (the ORIGINAL bucket) followed by
`FutexRemoveByWaker` item_present=0 (MISS — the item had been moved to
bucket 87); `FutexWaitDecide` code=0 (Ok); `WaiterDrop`. This is CE
MC_hunt_s3_owner states 25-55 (ResourceAccountingBalance: registered=1,
removals=0) and the LiveMigrationExhaustion consequence of
MC_hunt_s4_live_migration, on the exact code path the finding cites.

Notes:
- Asterinas maps a zero REQUEUE nr_wake to one wake
  (`futex_val_to_max_count`, kernel/core/src/syscall/futex.rs:290), so the
  exhaustion stage uses nr_wake=1 with two live waiters (case-13 shape).
- An earlier flawed attempt used the same A/B pair twice; the second pass
  showed the stranded entry from pass 1 consuming the next REQUEUE's move
  quota (W2 not moved, left to time out on A) — further live evidence of the
  retained entry, before the test was fixed to a single attempt.
- Level 1/2/3 were not needed (Level 0 triggered on the first correct run).
