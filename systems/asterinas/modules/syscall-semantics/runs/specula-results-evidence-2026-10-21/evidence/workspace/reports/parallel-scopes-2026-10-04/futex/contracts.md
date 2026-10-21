# Private futex requeue, wake and timeout contracts

Use this source preparation to produce the native analysis brief for a complete
bounded protocol-verification run. The shared protocol is a private waiter's
registration, movement between futex keys, wake or timeout, and release of its
queue and waker ownership. It is Category B. A useful protocol model does not
require a new defect candidate.

Status is `SOURCE_PREPARATION_COMPLETE`, with analysis, tests, traces, model
checking and runtime `NOT_RUN`. This report registers no new finding. It is
informed by the [earlier scope assessment](../../specula-scope-assessment-2026-10-02/vm-futex-scopes.md)
and [priority review](../../specula-scope-assessment-2026-10-02/ultraplan-priorities-2026-10-03.md),
so it is not a blind baseline. No Git-history or current issue/PR dedup sweep was
performed here. Native analysis must supply that coverage before novelty claims.

## Inputs and boundary

- Asterinas is `0c60537098f4c2949ad2d382aaf499de72263d76`, tree
  `4693fdec88cd7da14bed4f1541eba593f123059c`, read from the clean standalone
  checkout `/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/source`.
- Linux is v6.16.5, commit `4645fefac0b24d509b962c096b0327e87f34b1d2`, read
  from `/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5`.
  This selected-file reference has no Git history. A later Linux execution must record its
  actual kernel identity instead of treating this reference pin as runtime proof.
- Cover raw `FUTEX_WAIT`, `FUTEX_WAKE` and `FUTEX_REQUEUE`, always with
  `FUTEX_PRIVATE_FLAG`, ordinary aligned 32-bit words in one stable address
  space, nonnegative wake/requeue counts, and relative monotonic WAIT timeouts.
- Exclude PI, CMP_REQUEUE, robust lists, WAITV, WAKE_OP, selective bitsets,
  CLOCK_REALTIME, signals/restarts, fork/exec/exit and clear-child-tid, shared
  VMO identity, mapping replacement, malformed pointer/flag fuzzing and OOM.
  WAIT's use of the internal match-any bitset helper remains in scope.
- This narrows the `process-signal-futex` track to one protocol. Reuse its
  vocabulary `FAILURE-ATOMICITY`, `EXACTLY-ONCE-COMPLETION`,
  `OBJECT-IDENTITY-STABILITY` and `RESOURCE-ACCOUNTING-BALANCE`, with the
  qualifications below. AST-48/49/50 remain outside this run. The track's
  different source pin does not establish behavior at this pin.

## Source map and atomicity

| ID | Exact source entry | Behavior that the receiver must preserve |
|---|---|---|
| A1 | [syscall/futex.rs:79](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/source/kernel/core/src/syscall/futex.rs:79), especially 105–117 and 136–150 | Dispatch, count conversion and ETIME-to-ETIMEDOUT mapping. WAIT uses a relative timeout at lines 55–60. |
| A2 | [futex_wait_bitset:77](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/source/kernel/core/src/process/posix_thread/futex.rs:77), through 139 | Lock the original bucket, load and compare, then enqueue before unlocking. A recoverable page fault drops the lock, resolves the fault, then repeats the locked load. Cleanup searches the original bucket by waker identity. |
| A3 | [futex_requeue:353](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/source/kernel/core/src/process/posix_thread/futex.rs:353), through 427 | Same address delegates to WAKE. Other pairs hold one shared bucket lock or both bucket locks, acquired in ascending bucket-index order, across wake and movement. |
| A4 | [FutexBucket:477](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/source/kernel/core/src/process/posix_thread/futex.rs:477), through 534 | Cleanup uses Arc identity. WAKE removes and counts an item only when its waker accepts the wake. Same-bucket requeue changes keys, while cross-bucket requeue extracts and appends entries. |
| A5 | [FutexKey:574](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/source/kernel/core/src/process/posix_thread/futex.rs:574), through 674 | Private identity is VMAR snapshot plus address. Hash and bucket identity are separate from equality. Bucket count depends on CPU count at lines 390–391. |
| A6 | [pause_timeout:171](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/source/kernel/core/src/process/signal/pause.rs:171), through 221 | Timer expiry uses the same waker as futex wake. The waiter checks the timer after waking and cancels it if not expired. The enclosing futex cleanup can override that result. |
| A7 | [Waiter/Waker:244](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/source/ostd/src/sync/wait.rs:244), through 281 | Drop closes the waker. Wake after close returns false. `do_wait` consumes the wake flag, so a snapshot of `has_woken` alone does not distinguish completion, pending wake and closure. |
| L1 | [Linux do_futex:97](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/syscalls.c:97) and [requeue:584](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/requeue.c:584), through 691 | Ordinary REQUEUE passes `cmpval=NULL` and `requeue_pi=0`. Its count includes both woken and moved waiters. |
| L2 | [Linux requeue_futex:76](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/requeue.c:76) and [futex_unqueue:921](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/core.c:921) | A moved waiter's lock pointer follows its current bucket. Cleanup locks that pointer, rechecks it, and retries if it changed. |
| L3 | [Linux wait setup:591](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/waitwake.c:591) and [wait completion:666](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/waitwake.c:666) | Locked compare/enqueue prevents missing a state-change wake. Wake removal takes precedence over an expired timer. Otherwise timeout removes the current registration before returning ETIMEDOUT. |

Requeue's two bucket locks serialize competing requeues and wake operations on
those buckets. A timer and its waiter can still advance outside those locks.
Preserve this distinction, the waiter's saved original bucket and the entry's
current bucket. A model that drops the locks or assumes these buckets always
coincide does not represent this implementation.

## Contract and allowed-result table

| Contract | Allowed result and evidence | Source prediction or question to retain |
|---|---|---|
| Compare before registration | A mismatch returns EAGAIN without leaving a waiter. With a stable word and the required user-space atomic update/wake order, a wait cannot miss the update by testing outside the bucket lock. A2, L3. | Preserve the unlock/fault/relock/reload compensation. Fault resolution is adjacent source evidence, not a request for a VM campaign. |
| Identity and wake quota | With positive quota, WAKE counts accepted wakes of matching private keys, up to the quota. No particular waiter order is promised. A4, A5. | Equal bucket indices do not make different keys equal. A false return from a closed waker neither consumes quota nor removes that item. |
| Requeue ownership | Requeue moves at most its migration quota after the permitted wakes. Later WAKE at the destination can reach moved waiters, and source WAKE cannot reach them unless moved back. A3, A4, L1, L2. | Same- and cross-bucket paths must have equivalent external semantics. Same-address calls are a separate control because A3 delegates to WAKE. |
| Requeue result count | At the selected Linux pin, return the total number woken or requeued. L1. | Asterinas returns only `nwakes` at line 381. Keep this as an unexecuted compatibility question, separate from ownership errors. |
| Zero migration quota | With a positive wake quota, zero migration quota leaves the remaining waiters on the original key. L1 checks the remaining quota before processing a waiter. | A4's same-bucket loop handles its first entry before checking the quota. If that first remaining entry matches, it changes one key. If it does not match, it stops immediately. The cross-bucket loop checks quota first. This is a conditional source prediction, not a runtime result. |
| Zero wake quota | Ordinary REQUEUE with zero wake quota may requeue but does not wake. Zero wake and migration quotas do neither at this Linux pin. L1. | A1 converts the REQUEUE wake quota to at least one. Ordinary Linux WAKE also has a legacy zero-count quirk at [waitwake.c:180](/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/waitwake.c:180), but REQUEUE is a different path. Do not copy WAKE's oracle to REQUEUE. |
| Wake/timeout completion | Match return and cleanup to the observed history. Success and ETIMEDOUT can both be permitted in an overlapping wake/timeout race. Success alone does not establish a targeted wake or that the user predicate became true. A2, A6, L3. | After cross-bucket movement, A2 can fail to find the item in the original bucket and return success even after timer expiry. Treat that success conservatively as a possible spurious wake until stronger evidence exists. |
| Completed waiter ownership | A completed wait must not become a second live wait or supply another accepted wake. A7 closes its waker. A4 retains entries whose waker rejects waking. | Inspect whether a retained closed entry consumes later migration capacity or changes progress of live waiters. Its presence alone is not an ABI violation. |
| Resource accounting | Track registration, removal, timer and waker ownership separately. The cleanup comment at A2:121 states a reclamation intent. | Before alleging a leak, establish the actual owner, allowed deferred cleanup and a bounded observation after quiescence. Do not impose an undocumented requirement that every syscall return immediately empties every bucket. |
| Operation-specific failure effects | Mismatching WAIT leaves no registration. Timeout completes the original logical wait and must not be treated as a transaction rollback of an earlier successful REQUEUE. | `FAILURE-ATOMICITY` applies to the effect of the failing operation, not a blanket rollback rule for the entire history. |

The current [REQUEUE manual](https://man7.org/linux/man-pages/man2/FUTEX_REQUEUE.2const.html)
(man-pages 6.19, inspected 2026-10-04) describes only a wake count. That conflicts
with L1, which increments `task_count` for each plain wake or move and returns
it. Use the fixed implementation as the versioned reference and obtain a Linux
control before claiming compatibility failure. The related
[CMP_REQUEUE manual](https://man7.org/linux/man-pages/man2/FUTEX_CMP_REQUEUE.2const.html)
describes the combined count, but CMP_REQUEUE itself is outside this run.

The [WAIT manual](https://man7.org/linux/man-pages/man2/FUTEX_WAIT.2const.html)
allows callers to treat successful returns as spurious. It also describes
atomic compare-and-wait and a relative timeout that does not expire early.
These rules require recording the user predicate and operation history, not
equating a successful return with a uniquely identified WAKE.

## Finite test and trace plan

All cases below are designs with execution `NOT_RUN`. Use raw futex calls,
stable C atomic words, explicit per-call IDs and SMP >= 2. Record the actual
bucket IDs and CPU count in Asterinas. Different virtual addresses do not prove
different buckets. An actor's ready flag before WAIT is not evidence of enqueue.
Admit each measured attempt only when its trace proves the required enrollment
and ordering. Keep unachieved schedules as uncovered attempts.

| Case | Controlled setup | Observation required |
|---|---|---|
| F01 | Mismatching WAIT, followed by WAKE with quota one. | EAGAIN, no registration, zero accepted wakes. |
| F02 | One enrolled waiter, then WAKE with quota one. | Exactly one accepted wake, one removal, one syscall completion. |
| F03 | Two enrolled source waiters, REQUEUE(1,1), then WAKE at each key. Repeat for equal and different buckets. | Separate return count from actual wake and move counts. Identify moved waiters without demanding FIFO selection. |
| F04 | Two source waiters, REQUEUE(1,0), then destination/source WAKE. Repeat for equal and different buckets. Add a same-bucket unrelated-key first-entry control. | Zero migration, or an attributable quota violation. Prove the first remaining bucket entry before interpreting A4's conditional branch. |
| F05 | Enrolled source waiters, REQUEUE(0,1) and a separate REQUEUE(0,0) attempt. | Separate accepted wakes, moved entries and return count. A matching total alone can hide different behavior. |
| F06 | Same-address REQUEUE with positive wake quota and a pending second waiter. | Record the special branch, unchanged key identity and the versioned Linux result. Keep its count difference separate from physical migration. |
| F07 | Requeue, then timeout of a moved waiter with no destination WAKE. Repeat within one bucket and across buckets. | Wait result, current versus original cleanup bucket, removal/closure, and later accepted wake count. A spurious-success return alone is inconclusive. |
| F08 | Race destination WAKE against expiry after a proved requeue. | Both permissible winners, accepted wake evidence, one logical completion and no invented total order across CPUs. |
| F09 | After F07, enroll fresh waiters and perform bounded requeue/wake steps, including moving back. | Whether any old closed entry affects the quota or live-waiter progress. Use a fixed small repetition count, not memory exhaustion. |
| F10 | Opposite-direction REQUEUE operations with positive quotas and source waiters. | Both bucket-order directions, serialized ownership changes, and successful bounded completion. A host watchdog is an environment limit, not deadlock proof. |

Trace the syscall inputs/returns, stable waiter identity with generation,
private-key identity, bucket index, lock acquisition/release, compare result,
enqueue, accepted/rejected wake, old/new key and bucket for migration,
timer expiry/cancellation, cleanup lookup/removal and waker closure. Capture
mutations where they occur under the existing locks. Emission must not add
blocking waits or user-memory copies under those locks. Distinguish per-thread
order and lock-derived order from unsynchronized timestamp order. Waker pointer
reuse and the wake flag alone are inadequate lifetime identifiers.

## Work the receiving agent must close

1. Native analysis must review the full bounded call/error paths, relevant Git
   history and issue discussions, and produce the reviewed modeling brief.
   Resolve which source leads merit separate sequential controls while retaining
   the complete ownership protocol as the modeling goal.
2. Before harness execution, make enrollment and same/cross-bucket coverage
   observable without replacing the production synchronization. Record the
   Linux control kernel and the plan for incomplete schedules and external
   timeouts. Kernel trace coverage and result-count calibration are not yet done.
3. Before accepting properties, resolve resource-reclamation obligations and
   wake/timeout allowed histories separately from internal queue shape. Keep
   spurious wakeups, closed-waker compensation and lock ordering intact.
4. Complete the staged protocol pipeline with its reviews. Preserve any local
   compatibility failure independently so it cannot mask other protocol
   properties. No-new-bug results remain useful bounded verification results.
