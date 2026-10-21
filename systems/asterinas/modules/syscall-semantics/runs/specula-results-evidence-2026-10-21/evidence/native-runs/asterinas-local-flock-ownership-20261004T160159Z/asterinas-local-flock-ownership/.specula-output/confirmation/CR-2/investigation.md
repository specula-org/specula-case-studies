# CR-2 Investigation — Waiter registration, notification, and retry against a new blocker

Finding: failed flock attempt registers its waker on ONE conflicting item's wait queue; only
that item's removal or replacement notifies the waiter; notification is a retry trigger, not a
grant; retry may then conflict with a different owner. Hypothesis: a release/replacement
overlapping actual registration (C07), migration between two SH blockers (C08), or a wake race
(C09) can leave a live blocked request without a notification or reachable registration/retry
path. Source: code review; the campaign's bounded MC hunts for C07/C08/C09 found NO violations.
Pinned tree: 0c60537098f4c2949ad2d382aaf499de72263d76 (worktree = pin + campaign tracing
instrumentation, hash-identical to the reviewed harness source; tracing inactive unless a
magic prctl registers a task, so default behavior is upstream-equivalent).

## Step 1: Code audit (facts)

### Mechanism as implemented

Registration (`kernel/core/src/fs/file/flock.rs:114-157`, upstream lines):
- Blocking `flock` → `FlockList::set_lock` → `Waiter::new_pair()` → `waiter.pause_until(closure)`
  → closure = `try_set_lock(&req_lock, Some(&waker))`.
- `try_set_lock` takes the `FlockList::inner` Mutex, scans for the FIRST item conflicting with
  the request, enqueues the waker into that item's `Arc<WaitQueue>` (enqueue INSIDE the list
  mutex), returns EAGAIN. The closure maps EAGAIN → None (keep waiting), everything else → Some.

Notification (`flock.rs:69-82` Drop, `flock.rs:164-181` unlock):
- Every mutation that can un-block a waiter holds the same list mutex:
  - `unlock` (LOCK_UN, or `InodeHandle::drop` → `unlock_flock`, `inode_handle.rs:542-548`):
    `list.retain(...)` — for a matching owner: explicit `lock.wake_all()` then removal; for an
    item whose `Weak::upgrade` fails (owner dying): removal without the explicit wake, but the
    item is still DROPPED by retain.
  - `try_set_lock` same-owner conversion: `list[idx] = req_lock.clone()` — the old item is
    dropped by the assignment.
- `Drop for FlockItem` (`flock.rs:79-83`) unconditionally `wake_all()`s the item's wait queue,
  so BOTH removal paths (explicit + retain-drop) and the replacement path wake the queue.
- `FlockItem::clone` shares the `Arc<WaitQueue>`, so the replaced (new) item installed at `idx`
  carries the fresh request's queue; the old item's queue is woken by the old item's Drop.

Retry / wake delivery (`ostd/src/sync/wait.rs:209-282`, `ostd/src/task/scheduler/mod.rs:441-493`):
- `Waker::wake_up`: `has_woken.swap(true, Release)`; if it was false → `unpark_target`.
- `Waiter::do_wait`: `while !has_woken.swap(false, Acquire) { park_current(|| has_woken.load(Acquire)) }`.
- `park_current` re-checks `has_unparked` under the local runqueue lock; the concurrent
  `unpark_target → ClassScheduler::enqueue` is serialized against `dequeue_current` by the same
  runqueue lock plus the task's `cpu` cell (`set_to_none` in `dequeue_current`,
  `sched_class/mod.rs:418-424`; double `set_if_is_none` re-check in `enqueue`,
  `sched_class/mod.rs:236-239`). The comment at `scheduler/mod.rs:460-467` documents this.
- Signals: `pause_until` sets a signalled waker; on pending signal → `waker.close()` → final
  cond re-check → EINTR. After close, later `wake_up`s are no-ops by design (stale queue
  entries are harmless: popped later, `has_woken` already true).

Liveness anchors: a blocked waiter's syscall holds an `Arc<InodeHandle>` (shared-table path
clones it; unshared-table path borrows from a uniquely-owned table, so no concurrent close can
occur), which keeps the inode → `FsLockContext` → `FlockList` alive for the whole wait.

### Reachability

Trivially reachable: any blocking flock conflict exercises registration; release/conversion
exercises notification; multi-thread contention exercises retry migration. The hypothesized
races are ordinary SMP behavior (2 vCPU guest suffices).

### Safeguards encountered (recorded, tested in Phase 2)

1. List-mutex serialization of scan+enqueue vs. remove/replace+notify: if release wins, the
   waiter's post-release scan sees the post-release list (acquire, or register on a live
   blocker); if registration wins, the release's wake_all pops the registered waker.
2. `has_woken` atomic (Acquire/Release) covering the window between cond() return and park.
3. `park_current` re-check + runqueue-lock serialization of enqueue vs. dequeue.
4. `Waiter::drop`/`close` turning late wakes into no-ops (intended).
5. No timers/spurious re-wakes exist for flock: a genuinely lost notification is permanent.
   Therefore a blocked flock that never returns after all blockers are provably gone is an
   unambiguous observable anomaly (used as the Phase-2 success criterion).

### Trigger scenario (constructed)

Level 0 (black-box, real syscalls only): owner holds EX/SH; waiter issues blocking flock;
owner releases (or converts, or closes) with randomized timing overlapping the waiter's
registration; two SH blockers with release order shuffled forces retry migration; two waiters
force wake_all races; NB-op churn storms exercise repeated replacement/removal wakes while a
blocking waiter re-registers. Observable failure: blocking flock never returns although a
fresh OFD can then take `LOCK_EX|LOCK_NB` (proves no lock remains).
Level 1 (timing hooks): the campaign instrumentation's prctl gates freeze a waiter between
the `has_woken` swap and park (`gate_wait`), or freeze a releaser inside `unlock`'s retain scan
(`gate(fd)`), making the C07/C08/C09 windows deterministic. Logic unchanged.

## Step 2: Developer knowledge (evidence, not classification)

- `e5fd8e747` "Fix flock lost-wakeup bugs, replace RwMutex -> Mutex" (2024-10-24, PR #1486,
  fixing issue #1474 "Infinite waiting in flock due to waiting on a None condition"): replaced
  the old `FlockItem::wait_until(|| None)` design (wake condition literally always None →
  permanent re-wait) with enqueue-waker-while-holding-list-lock + `Waiter::wait` + retry loop.
- `7fbe997bb` "Fix range_lock and flock to support signal interrupts and comply with wait API
  design" (2024-11-05): introduced the current `try_set_lock(req, Option<&Waker>)` +
  `waiter.pause_until` shape for both flock and range_lock.
- `968389f55` "Fix lost wakeup in range_lock caused by waiting on an outdated waitqueue"
  (2024-10-17): the sibling subsystem's same-shape precedent (clone waitqueue out of lock,
  wait on outdated queue) — the mechanism the current design removes by enqueueing under the
  list mutex.
- `ostd/src/task/scheduler/mod.rs:597-599` FIXME cites issue #1633 "Problem 2" (scheduler
  decision vs. context switch not atomic) — closed as completed; maintainers state the
  soundness part was fixed via #1930 and Problem 2 "is not a soundness issue". Not a report of
  a flock waiter lost wake.
- No TODO/FIXME/known-limitation comments at the flock/wait sites claiming remaining lost-wake
  risk.

## Step 3: Known-status / precedent

Tracker search (GitHub issues + merged/closed PRs, open and recent):
- #1474 (flock infinite wait, old design) — closed, fixed by PR #1486 = commit e5fd8e747.
- #1261 (potential lost-wake in wait.rs during mutex unlock, stale waker) — closed; generic
  mutex site, not the flock registration/notification path.
- #1497 (possible wrong Mutex implementation; wake_until re-enqueue question) — closed not
  planned; generic mutex site.
- #1303 (RwMutex lost wakeup) — fixed by bebfc360d; different primitive.
- #1587 / futex stale-item lost wakes — different subsystem, fixed 2025.
- #1633/#1471 — scheduler switching soundness; fixed via #1930; not flock waiter notification.
- 2025-2026 commits touching wake paths are futex-related; the only flock commits are SCML
  test additions and unrelated installer work. No open or closed report describes a lost
  notification/retry defect in the CURRENT flock waiter design (try_set_lock + pause_until +
  Drop wake_all). The historical fixes are the OLD designs' reports, explicitly context-only
  per the brief.

Conclusion of Step 3: not already reported → NOT dropped; proceed to Phase 2. Novelty (if a
defect is confirmed): NEW — no existing report of THIS mechanism at THIS site.

## Phase 2 plan

Escalation ladder:
- Level 0: racy black-box patterns (C07 release-during-registration with randomized delays,
  conversion replacement, C08 two-SH migration, C09 two-waiter wake race, release-via-close)
  + churn-storm rounds with a blocking waiter; each round proves quiet via a fresh-OFD
  `LOCK_EX|LOCK_NB` probe and requires every blocking flock to complete within 10s.
- Level 1: deterministic window forcing via the instrumentation's system-provided gates
  (gate_wait/gate(fd)/release_gate + boundary waits), the same hooks the campaign harness
  fixtures use; kernel logic unchanged, timing only.
- Level 2/3: only if 0/1 suggest a specific reachable-but-unlucky interleaving (state
  injection would need a real-API sequence reproducing it; none hypothesized that 0/1 cannot
  force, since the gates can freeze every window of interest).

Environment: reuse the reviewed, hash-verified kernel build (container
`specula-flock-harness-20261005`, kernel ELF d51c220500302e72765e313e754fc780d89cfd6ddbacfea4a40f853c122d1dbb
matching harness evidence build-sha256.txt; /source tree diff-identical to this worktree).
Tracing stays inactive during Level 0 (no prctl registration), so the exercised code path is
behaviorally upstream. Linux control run of the same binary validates the fixture logic.

## Phase 2 execution record (added after reproduction)

### Level 0 — pure black-box (real syscalls, tracing never registered)

Three Asterinas runs (pinned kernel 0c6053709 + reviewed instrumentation, hooks
dormant) plus a Linux 7.2.8 host control. Every run passed all 400 iterations
of the five racy patterns (release-vs-registration, double-conversion
replacement, two-SH-blocker migration, two-waiter wake race, release-via-close)
plus 60 churn-storm rounds (two workers free-running SH/EX/UN conversions while
a third worker holds a blocking EX; each round ends with a quiet probe proving
no lock remains). Zero lost wakes; every blocking flock returned within the
10 s deadline. Linux control validates the fixture logic itself (no
false-positive hangs from synchronization bugs in the test).

### Level 1 — deterministic window forcing (campaign test hooks)

Patterns: l1a notification-before-park (gate_wait freezes the waiter between
the has_woken swap and park; the release is delivered while the waiter is
unparked; waiter must still complete), l1b blocker migration (frozen on first
SH blocker, released, re-registers and parks on the second SH blocker,
released again), l1c two-waiter wake race (both waiters confirmed parked via
SchedulerParkCommit boundaries, one release wakes both; loser re-registers on
the winner, is woken by the winner's unlock), l1d release-wins-the-mutex
(gate(a) freezes the releaser inside unlock's retain scan holding the list
mutex; the waiter parks on the list mutex; gate opens; releaser completes;
waiter's post-release scan acquires). Final test: 3 repetitions per pattern,
all PASS on two boots with different CPU placements
(controller_cpu=1/frozen_cpu=0 and controller_cpu=0/frozen_cpu=1).

### Two fixture hangs during development — diagnosed as artifacts, not kernel defects

Two earlier revisions of the gated patterns hung the VM. GDB backtraces on a
live hung VM (QEMU gdbstub, symbols from the built ELF) showed:
- l1c-old hang: CPU1 = the gate_wait-frozen waiter spinning in
  ostd::flock_trace::await_wait_gate (flock_trace.rs:138) reached from
  Waker::do_wait (wait.rs:319) — exactly the frozen point the hook defines;
  CPU0 = the controller's task trapped on the syscall-exit signal path
  (dequeue_pending_signal → SigDispositions Mutex::unlock → wake_one), later
  absent entirely with CPU0 in the BSP idle loop.
- l1d hang: CPU1 = the releaser frozen in await_gate (flock_trace.rs:141)
  inside FlockList::unlock's retain closure (flock.rs:216) holding the list
  mutex — again the exact designed freeze point; CPU0 = BSP idle loop, the
  controller not runnable anywhere.

Root cause: the instrumentation's gate hooks spin-wait in kernel mode, which
Asterinas cannot preempt. The frozen task occupies its CPU until the gate
opens, and only the controller can open the gate; whenever the frozen task
shared a CPU with the controller (correlated with worker/controller placement
across all observed runs), the controller starved and the VM deadlocked — in
the l1d case before the notification step of the pattern was even reached.
No flock-list operation was implicated; the stall was scheduling-level
starvation created by the test hook itself. The campaign's own reviewed
fixtures (C07-notify, C11/C12) share this latent hazard and happened to run
with CPU-disjoint placements. Fix: the test now selects the gate-frozen role
among workers on a CPU different from the controller's (verified per run via
getcpu), parks non-participants on a separate inode, and the l1c pattern no
longer freezes a second waiter at all (the C09 shape with both waiters
genuinely parked covers that window). After the fix: two clean full-run PASSes.

### Escalation summary

- Level 0: exhausted as designed (2000+ racy windows + 60 storms per run; 3
  kernel runs + 1 Linux control) — no lost wake.
- Level 1: exhausted as designed (four hypothesized windows forced
  deterministically, 3 reps, 2 boots) — no lost wake; every notification
  reached its waiter through the swap/park window, migration re-registration,
  and mutex-blocked scan.
- Level 2 (state injection): not applicable — every hypothesized
  pre-condition is reachable through the real flock syscall API and was
  exercised at Levels 0–1; there is no unreachable-state mechanism to inject.
- Level 3 (source patch): not reached — no residual hypothesis remained to
  force after Level 1.

### Verdict basis

Code-review hypothesis of a lost waiter notification is refuted on three
independent legs: (1) the code audit — registration and every
unblocking mutation are serialized by the FlockList mutex, all removal and
replacement paths wake the item's queue (explicitly or via FlockItem::drop),
and the swap/park race is closed by has_woken (Acquire/Release) plus the
park recheck under the runqueue lock; (2) the campaign's bounded MC hunts
(C07/C08/C09) exhausted their state graphs with no violations and the
campaign's own reviewed gated fixtures completed; (3) dynamic reproduction
attempts at Levels 0 and 1 found no lost wake. Not a defect: FALSE POSITIVE.
