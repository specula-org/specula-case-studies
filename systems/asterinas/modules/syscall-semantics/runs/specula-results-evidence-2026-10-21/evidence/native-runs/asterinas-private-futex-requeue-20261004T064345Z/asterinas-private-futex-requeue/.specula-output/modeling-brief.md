# Modeling Brief: asterinas-private-futex-requeue

## 1. System Overview

Asterinas implements private Linux-style futex WAIT, WAKE and REQUEUE in Rust.
This is **Category B (Concurrent / Lock-Free / Runtime)**: bucket locks serialize registration and movement while timer callbacks and waiter completion advance independently.
The source is `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. Six fully read core files contain 2,145 lines, including excluded branches and tests.
One stable address space, aligned mapped atomic words, nonnegative signed-32-bit quotas and relative monotonic WAIT timeouts define the environment.
The reference is Linux v6.16.5, `4645fefac0b24d509b962c096b0327e87f34b1d2`. Its five relevant local source files match upstream bytes. Linux execution remains `NOT_RUN`.
Unlike Linux's movable `q->lock_ptr`, Asterinas saves the original bucket for cleanup (`F:79–124`; `L/core.c:921–963`). Keys distinguish identity from hash (`F:556–687`).
Code analysis is complete. Spec generation, instrumentation, TLC, runtime confirmation and classification remain `NOT_RUN`. The receiving controller owns transitions.
This is an informed campaign. Preparation leads were independently reassessed. The full protocol remains a modeling target even if no new defect is confirmed.

Source aliases: `F` = `kernel/core/src/process/posix_thread/futex.rs`; `S` = `kernel/core/src/syscall/futex.rs`; `P` = `kernel/core/src/process/signal/pause.rs`; `W` = `ostd/src/sync/wait.rs`; `T` = `kernel/core/src/time/core/timer.rs`; `TW` = `kernel/core/src/time/wait.rs`. `L/` means the pinned Linux `kernel/futex/` directory. Paths are linked in §7.

## 2. Scenarios

### Scenario 1: Registration and a value-change wake share a serialization boundary

**Mechanism**: A user update can overlap WAIT's load and registration, including an unlocked recoverable-fault retry.
**Evidence**:
- Historical context: [#981](https://github.com/asterinas/asterinas/issues/981) and [#2306](https://github.com/asterinas/asterinas/pull/2306) explain the repaired non-atomic read and fault-in-atomic-mode paths. They are not rediscovery targets.
- Current code holds the bucket across atomic load, comparison and enqueue. Recoverable faults unlock, resolve, then repeat the locked load (`F:79–119`; `process/posix_thread/thread_local.rs:102–135`). Linux similarly reloads under lock (`L/waitwake.c:591–663`).
**Affected code paths**: `sys_futex`, `futex_wait_bitset`, `FutexKey::new`, `remove_and_wake_items`, `Waiter::wait`.
**Suggested modeling approach**:
- Variables: user words, expected values, per-call phase, bucket lock owner, fault/retry state and registered generation.
- Actions: user atomic store before WAKE invocation; acquire, load/compare, enqueue, release; on recoverable fault, unlock/resolve/reacquire/reload.
- Granularity: exclude competing bucket operations, but permit user stores and timer steps while the lock is held. Preserve pending wakes between enqueue and actual parking (`W:192–201,262–275`).
**Priority**: High.
**Rationale**: This is the foundation for interpreting later wakes. Current compensation is preserved. No new lost-registration defect is asserted.

### Scenario 2: Quotas diverge across dispatch and bucket paths

**Mechanism**: Shared count conversion and unequal loop boundaries change wake/move effects independently of the return count.
**Evidence**:
- History: `860bb6c07f0a` introduced shared wake-count conversion into REQUEUE; `85d4cdbbb001` moved the same-bucket migration limit check after entry processing. These explain present leads, not reverted-fix experiments.
- REQUEUE converts wake zero to one (`S:105–109,146–150`), same-bucket migration can change the first remaining matching entry with migration zero (`F:500–511`), and the return excludes moves (`F:366–381`). Cross-bucket migration checks the quota first (`F:520–533`).
- Linux plain REQUEUE honors zero quotas and returns wake-plus-requeue count, including same-address processed entries (`L/syscalls.c:108–109`; `L/requeue.c:391–410,584–610,691`).
**Affected code paths**: `futex_val_to_max_count`, `futex_requeue`, `lock_bucket_pairs`, both migration helpers and the same-address WAKE shortcut.
**Suggested modeling approach**:
- Variables: raw/effective quotas, accepted wakes, physical moves, processed requeues and return value. Keep same address distinct from different keys sharing a bucket.
- Actions: actual conversion and vector iteration, including an unrelated first-entry control for migration zero. Preserve locks throughout wake and movement (`F:398–427`).
- Granularity: split accepted wake and per-entry movement while retaining locks. Timer/close steps may still interleave.
**Priority**: Medium for modeling, High for sequential calibration.
**Rationale**: TV-1–TV-3 are direct source leads suited to syscall controls. Separate their failures so they cannot mask ownership checks.

### Scenario 3: A moved wait completes using its original cleanup bucket

**Mechanism**: The saved cleanup location diverges from the entry's current owner while timeout or destination wake completes the wait.
**Evidence**:
- Historical context: [#1587](https://github.com/asterinas/asterinas/issues/1587), [#2377](https://github.com/asterinas/asterinas/pull/2377) and [#2515](https://github.com/asterinas/asterinas/pull/2515) establish cleanup intent and earlier repairs. The moved-owner consequence is distinct from replaying those fixes.
- Requeue changes key/bucket without updating the waiter's captured bucket (`F:79–124,500–533`). An original-bucket miss returns success even after expiry (`F:124–139`; `P:202–208`). Linux cleanup follows and rechecks the current lock pointer (`L/requeue.c:76–100`; `L/core.c:921–963`).
**Affected code paths**: `futex_wait_bitset`, both requeue paths, `pause_timeout`, timer callback, `remove_by_waker`, `Waiter::drop`.
**Suggested modeling approach**:
- Variables: immutable `originalBucket`, mutable entry key/current owner, timer deadline/state, pause result, cleanup result, syscall result and closure.
- Actions: requeue, expire, deliver/consume wake, inspect/cancel timer, original-bucket lookup, result decision, drop and return. Include same-bucket movement and movement back.
- Granularity: separate clock expiry, callback, consumption, cleanup and closure. Do not silently repair the original-bucket lookup in the implementation model.
**Priority**: High.
**Rationale**: This is a current ownership question with a reclamation obligation (`F:121–124`). Success alone is inconclusive because callers must tolerate spurious success.

### Scenario 4: Completed bookkeeping changes a later live migration

**Mechanism**: A retained closed entry rejects WAKE but remains eligible for migration and can consume a live waiter's migration capacity.
**Evidence**:
- Historical context: [#3283](https://github.com/asterinas/asterinas/issues/3283) concerns other WaitQueue consumers, not proof of this futex defect. [#1261](https://github.com/asterinas/asterinas/issues/1261) and [#1497](https://github.com/asterinas/asterinas/issues/1497) reject stronger lost-wakeup claims after considering compensation.
- Drop closes the waker (`W:244–281`). WAKE retains rejected entries (`F:485–498`), but migration counts matching entries without checking closure (`F:500–533`). Global buckets have no deferred entry reaper (`F:384–475`).
**Affected code paths**: scenario 3 completion followed by fresh WAIT, REQUEUE and WAKE operations.
**Suggested modeling approach**:
- Variables: queue sequences, generation IDs, independent wake flag/closed state, live/retired entries, and per-generation quota consumption.
- Actions: after proved cross-bucket timeout/closure, enroll two fresh destination waiters, REQUEUE back with `(1,1)`, then wake both keys.
- Granularity: preserve `retain`, `swap_remove`, extraction and append effects where relevant. Impose no external FIFO promise. Count logical completion, not one accepted timer-or-futex wake over a lifetime (`W:262–281`).
**Priority**: High.
**Rationale**: This yields a bounded external oracle beyond retained memory. It is MC-1's later consequence, not a second independent defect claim.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| Complete registration-to-close protocol | All four priority questions interact. | Preserve scenarios 1–4 even if sequential leads are known or no new MC bug emerges. |
| Three private keys and two buckets | Identity equality, collisions and distinct buckets select different paths. | Configure `bucketOf` explicitly, including same-key controls and both bucket-order directions. |
| Four logical WAIT generations and two reusable controller actors | F09 needs an initial wake/move pair followed by two fresh waits. | Use unique generation IDs and quotas 0, 1, 2. Allow at least four control-call generations for two requeues and both subsequent wakes. |
| Locks and intermediate phases | Timer/closure is not excluded by a bucket lock. | Acquire by increasing index. Preserve locked compare/enqueue and wake/move intervals. Any extracted entry remains owned by the requeue operation until append. |
| Deadline and callback ownership | Callback delivery can lag expiry, and an already-expired timeout may never arm. | Include absent, already-expired and future timers (`P:171–208`; `TW:72–79,143–166`; `T:64–112,198–281`). |
| Separate compatibility properties | Normalizing discrepancies misrepresents source; stopping at them hides MC-1. | Keep TV-1–TV-3 in dedicated controls and check ownership on the unchanged implementation model with positive quotas. |
| Conditional progress | A watchdog or an unwoken indefinite WAIT proves nothing. | Assume finite interference/fault retries, advancing time, and fair enabled scheduler/timer/lock-holder steps. State each required wake or expiry obligation. |

The coverage floor is F01–F10 in the preparation: mismatch, wake, positive requeue, zero migration, zero wake, same address, moved timeout, wake/expiry race, later live migration, and opposite requeues. Add F00 for ordered user store/WAKE versus registration and a WAKE(0) control. All executions are `NOT_RUN`.
Trace syscall IDs/returns, generation IDs, actual key/bucket identity and CPU count, lock boundaries, comparison/enqueue, accepted/rejected wake and actor, each migration, deadline/callback/cancel, cleanup location/result and closure. Admit only schedules with actual enqueue/movement evidence. Use SMP >= 2. Distinguish thread/lock order from timestamps. Emission must not block or copy user memory under locks.

### 3.2 Do Not Model

| What | Why |
|---|---|
| PI, CMP_REQUEUE, robust lists, WAITV, WAKE_OP, selective bitsets, CLOCK_REALTIME | Explicit exclusions. WAIT's internal match-any helper remains included. |
| Signals/restarts, fork/exec/exit, clear-child-tid, shared VMO keys, remapping | They change the environment/identity contract. Historical/open discussions supply context only. |
| Malformed pointers, OOM or exhaustion experiments | Excluded triggers. Preserve only bounded recoverable-fault retry behavior. |
| Hash arithmetic, allocator internals, weak-memory adversaries, scheduler algorithms | Use stable bucket mapping and existing synchronization API contracts. This is not an architecture-level memory-model proof. |
| Historical bug reintroduction or synthetic lost wakes | Do not remove current locks, atomics, identity equality, closure or timer cancellation to manufacture a finding. |
| Immediate removal of canceled timer heap nodes | TimerCallback holds a weak Timer reference and is pruned later (`T:198–221,234–281`). This differs from a FutexItem owning an `Arc<Waker>`. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Locked registration/retry | `pc`, `word`, `expected`, `locks`, `faultPending` | Preserve ordering and reload after retry (`F:83–117`). | 1 |
| Path-specific quotas/results | `rawQuota`, `effectiveQuota`, `wakeCount`, `moveCount`, `processedCount`, `opReturn` | Preserve zero limits and same-address behavior (`S:105–150`; `F:353–381`). | 2 |
| Original/current ownership | `originalBucket`, `entryKey`, `entryOwner`, `cleanupResult` | Expose stale cleanup and in-flight transfer ownership (`F:124,500–533`). | 3 |
| Timer/waiter lifecycle | `deadline`, `timerState`, `hasWoken`, `closed`, `pauseResult`, `waitResult` | Separate expiry, acceptance, consumption and completion (`P:171–221`; `W:244–281`). | 3 |
| Retired entries and later work | `generation`, `queueSeq`, `completed`, `removed`, `refs` | Measure bookkeeping retention and subsequent quota effects (`F:477–539`). | 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| FAILURE-ATOMICITY | Safety | EAGAIN leaves no registration. A failing WAIT affects its generation only; timeout does not roll back a completed REQUEUE. | 1, 3; `F:106–139` |
| EXACTLY-ONCE-COMPLETION | Safety | One return and at most one registration removal per generation. A closed generation cannot supply an accepted futex wake. Timer and futex wake can both have been accepted before close. | 3, 4; `F:477–498`; `W:262–281` |
| OBJECT-IDENTITY-STABILITY | Safety | Each registered generation has one queue/transfer owner until removal. Only matching private identities are affected. Requeue changes key/current owner, not generation or saved original bucket. | 1–4; `F:477–534,590–674` |
| RESOURCE-ACCOUNTING-BALANCE | Safety at quiescence | Every registration is owned or removed. Once completion and in-flight cleanup/transfer/callback steps drain, no completed generation retains a FutexItem/Waker owner. Exclude weak canceled timer nodes and permit transient callback references. | MC-1; `F:121–124,384–539`; `T:234–281` |
| NoMissedOrderedWake | Safety | Registration control only: one designated waiter, one predicate update followed by adequate WAKE, no predicate restoration, intervening requeue, timeout/removal or competing waiter. Comparison rejects registration or the registered generation receives wake. Success does not prove the predicate. | 1; `F:83–119,485–498` |
| RequeueQuotaAndResult | Safety | Linux plain REQUEUE obeys raw wake/migration quotas and returns the combined processed count. WAKE(0)'s legacy behavior has a separate oracle. | TV-1–TV-3; `L/requeue.c:584–610,691` |
| LiveMigrationExhaustion | Safety | Distinct keys, possibly one bucket: immediately before the locked REQUEUE(1,1) wake phase, two live eligible waits have no pending notification/completion. With no independent expiry/close/notification/admission, the unwoken live wait must reach the destination key. Completed entries cannot consume its capacity. A max-only bound misses MC-1. | 4; `L/requeue.c:584–610` |
| PermittedWaitResult / ConditionalCompletion | Safety / Liveness | ETIMEDOUT cannot precede the deadline. Wake removal may win overlapping expiry. Spurious success is permitted. Under the finite/fair environment, accepted wake or delivered expiry eventually leads to one return. | 1, 3; `P:202–221`; `L/waitwake.c:689–701` |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC-1 | Can cross-bucket movement followed by expiry/cleanup/closure strand a completed registration and make a later positive-quota REQUEUE fail to move the remaining live waiter? Source supports a candidate history; formal/runtime verification is pending. | RESOURCE-ACCOUNTING-BALANCE, LiveMigrationExhaustion | 3, 4 |

The useful outcome is a faithful bounded ownership history with a live-waiter consequence, or a compensating transition that refutes it. This is not a reverted-fix experiment. Empty persistent lookup results show no matching imported records, not novelty.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | REQUEUE wake zero becomes one (`S:106,146–150`). | F05: separately measure `(0,1)` and `(0,0)` effects. Equal returns can hide a wake/move difference. Calibrate WAKE(0) separately. |
| TV-2 | Same-bucket migration zero can move the first remaining entry (`F:500–511`). | F04: two proved source waits, `(1,0)`, same/cross-bucket controls, plus an unrelated first entry. Observe destination/source wakes. |
| TV-3 | Return counts only accepted wakes (`F:381`). Same-address shortcut omits Linux's processed requeue contribution (`F:353–354`). | F03/F06: `(1,1)` with two enrolled waits, distinguish physical moves from same-key processed entries, and record the actual Linux control-kernel identity. |

These are independently reread source leads with runtime `NOT_RUN`. The current REQUEUE manual describes only wakes, contrary to the pinned Linux code. Obtain a Linux control before claiming measured incompatibility.

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | The claim that an original-bucket miss occurs only after wake removal overlooks cross-bucket requeue (`F:124–129`). | Carry into downstream MC-1 audit. Establish owner/reclamation semantics. Success after expiry alone is insufficient. |

## 7. Reference Pointers

- [Detailed audit](analysis-report.md), [source identity](analysis-evidence/source-identity.json), [Linux byte verification](analysis-evidence/linux-reference-integrity.json), [futex audit](analysis-evidence/helper-futex.md), [waiter audit](analysis-evidence/helper-waiter.md).
- Core: [futex](../source/kernel/core/src/process/posix_thread/futex.rs), [dispatch](../source/kernel/core/src/syscall/futex.rs), [pause](../source/kernel/core/src/process/signal/pause.rs), [waiter](../source/ostd/src/sync/wait.rs), [timeout wrapper](../source/kernel/core/src/time/wait.rs), [timer](../source/kernel/core/src/time/core/timer.rs).
- [Preparation contracts](/home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/futex/contracts.md) and [resource policy](/home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json). Later heavy stages require the controller-held lock, TLC <= 4 GiB/2 workers, build <= 2 jobs, container <= 8 GiB/2 CPUs/512 PIDs and guest SMP >= 2/2 GiB. Recheck policy and memory reserves before execution.
- Linux files: `/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/`; [pinned requeue](https://github.com/gregkh/linux/blob/4645fefac0b24d509b962c096b0327e87f34b1d2/kernel/futex/requeue.c), [cleanup](https://github.com/gregkh/linux/blob/4645fefac0b24d509b962c096b0327e87f34b1d2/kernel/futex/core.c), [wait/wake](https://github.com/gregkh/linux/blob/4645fefac0b24d509b962c096b0327e87f34b1d2/kernel/futex/waitwake.c).
- Manuals: [WAIT](https://man7.org/linux/man-pages/man2/FUTEX_WAIT.2const.html), [REQUEUE](https://man7.org/linux/man-pages/man2/FUTEX_REQUEUE.2const.html), [WAKE](https://man7.org/linux/man-pages/man2/FUTEX_WAKE.2const.html), inspected 2026-10-04. Historical repairs remain context, not injected faults.
